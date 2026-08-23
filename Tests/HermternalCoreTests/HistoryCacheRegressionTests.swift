import Foundation
import HermternalCore
import Testing

@Test("punctuated session IDs use distinct cache files")
func punctuatedSessionIDsDoNotCollide() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let dotted = "room.one"
    let slashed = "room/one"

    _ = await cache.store([ChatMessage(role: .assistant, text: "dotted")], for: dotted)
    _ = await cache.store([ChatMessage(role: .assistant, text: "slashed")], for: slashed)

    let reopened = HistoryCache(directory: directory)
    #expect((await reopened.messages(for: dotted))?.map(\.text) == ["dotted"])
    #expect((await reopened.messages(for: slashed))?.map(\.text) == ["slashed"])
    let filenames = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).map(\.lastPathComponent)
    #expect(filenames.contains("room%2Eone.json"))
    #expect(filenames.contains("room%2Fone.json"))
    #expect(filenames.count == 2)
}

@Test("legacy cache files are adopted and removed")
func legacyCacheFileIsMigrated() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = "legacy.session"
    let legacyURL = directory.appending(path: "legacy-session.json")
    let transcript = CachedTranscript(
        version: HistoryCache.version,
        messages: [ChatMessage(role: .assistant, text: "legacy")],
        snapshot: nil
    )
    try JSONCacheCodec().encode(transcript).write(to: legacyURL)

    let cache = HistoryCache(directory: directory)
    #expect((await cache.messages(for: id))?.map(\.text) == ["legacy"])
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    let files = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    #expect(files.count == 1)
    #expect(files[0].lastPathComponent != legacyURL.lastPathComponent)
}

@Test("warm cache reads return memory without another disk read")
func warmCacheReadAvoidsDisk() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileSystem = CountingCacheFileSystem()
    let cache = HistoryCache(directory: directory, fileSystem: fileSystem)
    _ = await cache.store([ChatMessage(role: .assistant, text: "warm")], for: "session")
    let readsAfterStore = fileSystem.dataReadCount

    #expect((await cache.messages(for: "session"))?.map(\.text) == ["warm"])
    #expect(fileSystem.dataReadCount == readsAfterStore)
}

@Test("reconcile statistics use file metadata without decoding transcripts")
func reconcileStatisticsAvoidTranscriptDecoding() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = HistoryCache(directory: directory)
    _ = await writer.store([ChatMessage(role: .assistant, text: "one")], for: "one")
    _ = await writer.store([ChatMessage(role: .assistant, text: "two")], for: "two")
    let codec = DecodeCountingCacheCodec()
    let reader = HistoryCache(directory: directory, codec: codec)
    let statistics = await reader.reconcile(validIDs: ["one", "two"])
    let files = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey]
    )
    let expectedBytes = files.reduce(into: Int64(0)) { total, file in
        total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
    #expect(statistics.entryCount == 2)
    #expect(statistics.bytes == expectedBytes)
    #expect(codec.decodeCount == 0)
    #expect(await reader.messages(for: "one")?.first?.text == "one")
    #expect(codec.decodeCount == 1)
}

@Test("reconcile prunes orphaned and corrupt cache files")
func reconcilePrunesOrphanedAndCorruptFiles() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = HistoryCache(directory: directory)
    _ = await writer.store([ChatMessage(role: .assistant, text: "valid")], for: "valid")
    _ = await writer.store([ChatMessage(role: .assistant, text: "other")], for: "other")
    try Data("{not-json".utf8).write(to: directory.appending(path: "corrupt.json"))
    try Data("orphan".utf8).write(to: directory.appending(path: "orphan.json"))
    try Data(#"{"version":3,"messages":[{}],"snapshot":null}"#.utf8)
        .write(to: directory.appending(path: "nested.json"))

    let reader = HistoryCache(directory: directory)
    let statistics = await reader.reconcile(validIDs: ["valid", "other", "nested"])
    #expect(statistics.entryCount == 3)
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "corrupt.json").path))
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "orphan.json").path))
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "nested.json").path))
    #expect(await reader.messages(for: "nested") == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "nested.json").path))
    #expect(await reader.messages(for: "valid")?.first?.text == "valid")
    #expect(await reader.messages(for: "other")?.first?.text == "other")
}

@Test("prefetch stores from before a clear are rejected")
func delayedPrefetchStoreCannotResurrectClearedCache() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let expectedEpoch = await cache.currentEpoch()
    let gate = PrefetchGate()
    let prefetch = Task {
        await BoundedPrefetchCoordinator(limit: 1).prefetch(["session"]) { id in
            await gate.markStarted()
            await gate.waitForRelease()
            let result = await cache.store(
                [ChatMessage(role: .assistant, text: "stale")],
                for: id,
                expectedEpoch: expectedEpoch
            )
            return result.addedEntry ? result : nil
        }
    }

    await gate.waitForStart()
    #expect(await cache.clear())
    await gate.release()
    let results = await prefetch.value

    #expect(results.isEmpty)
    #expect(!FileManager.default.fileExists(
        atPath: directory.appending(path: "session.json").path
    ))
}

@Test("reconcile scales across 5000 current files")
func reconcile5000FilesUsesOneLookupPerFile() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let codec = JSONCacheCodec()
    let data = try codec.encode(
        CachedTranscript(
            version: HistoryCache.version,
            messages: [ChatMessage(role: .assistant, text: "cached")],
            snapshot: nil
        )
    )
    let count = 5_000
    let validIDs = (0..<count).map { "session-\($0)" }
    for id in validIDs {
        let encodedFilename = id.replacingOccurrences(of: "-", with: "%2D")
        let file = URL(fileURLWithPath: directory.path + "/\(encodedFilename).json")
        try data.write(to: file)
    }

    let fileSystem = CountingCacheFileSystem()
    let cache = HistoryCache(directory: directory, fileSystem: fileSystem)
    let statistics = await cache.reconcile(validIDs: validIDs)

    #expect(statistics.entryCount == count)
    #expect(statistics.bytes == Int64(data.count * count))
    #expect(fileSystem.dataReadCount == count)
}

@Test("cache file recognition and validation stay independent")
func cacheFileRecognitionAndValidationAreIndependent() throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let codec = JSONCacheCodec()
    let validData = try codec.encode(
        CachedTranscript(
            version: HistoryCache.version,
            messages: [ChatMessage(role: .assistant, text: "valid")],
            snapshot: nil
        )
    )
    let malformedData = Data("{not-json".utf8)
    let corruptEnvelope = Data(#"{"version":3,"messages":[{}],"snapshot":null}"#.utf8)
    let validURL = directory.appending(path: "valid.json")
    let malformedURL = directory.appending(path: "malformed.json")
    let corruptURL = directory.appending(path: "corrupt.json")
    let orphanURL = directory.appending(path: "orphan.json")
    let legacyURL = directory.appending(path: "legacy-session.json")
    let collisionURL = directory.appending(path: "collision-id.json")
    try validData.write(to: validURL)
    try malformedData.write(to: malformedURL)
    try corruptEnvelope.write(to: corruptURL)
    try Data("orphan".utf8).write(to: orphanURL)

    #expect(
        HistoryCache.classifyCacheFile(
            at: validURL,
            in: directory,
            validIDs: ["valid", "malformed", "corrupt"]
        ) == .current("valid")
    )
    #expect(HistoryCache.validatesCacheData(validData, codec: codec))
    #expect(
        HistoryCache.classifyCacheFile(
            at: malformedURL,
            in: directory,
            validIDs: ["valid", "malformed", "corrupt"]
        ) == .current("malformed")
    )
    #expect(!HistoryCache.validatesCacheData(malformedData, codec: codec))
    #expect(
        HistoryCache.classifyCacheFile(
            at: corruptURL,
            in: directory,
            validIDs: ["valid", "malformed", "corrupt"]
        ) == .current("corrupt")
    )
    #expect(HistoryCache.validatesCacheData(corruptEnvelope, codec: codec))
    #expect(
        HistoryCache.classifyCacheFile(
            at: orphanURL,
            in: directory,
            validIDs: ["valid", "malformed", "corrupt"]
        ) == .orphan
    )
    #expect(
        HistoryCache.classifyCacheFile(
            at: legacyURL,
            in: directory,
            validIDs: ["legacy.session"]
        ) == .legacy("legacy.session")
    )
    #expect(
        HistoryCache.classifyCacheFile(
            at: collisionURL,
            in: directory,
            validIDs: ["collision.id", "collision-id"]
        ) == .legacyCollision
    )
}
private actor PrefetchGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForStart() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class DecodeCountingCacheCodec: CacheCodec, @unchecked Sendable {
    private let base = JSONCacheCodec()
    private let lock = NSLock()
    private var count = 0

    var decodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func encode(_ transcript: CachedTranscript) throws -> Data {
        try base.encode(transcript)
    }

    func decode(_ data: Data) throws -> CachedTranscript {
        lock.lock()
        count += 1
        lock.unlock()
        return try base.decode(data)
    }

    func validate(_ data: Data) throws -> Bool {
        try base.validate(data)
    }
}

private final class CountingCacheFileSystem: CacheFileSystem, @unchecked Sendable {
    private let base = LocalCacheFileSystem()
    private let lock = NSLock()
    private var reads = 0

    var dataReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }

    func data(at url: URL) throws -> Data {
        lock.lock()
        reads += 1
        lock.unlock()
        return try base.data(at: url)
    }

    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func fileSize(at url: URL) -> Int64? { base.fileSize(at: url) }
}

private func historyCacheTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalHistoryCache-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
