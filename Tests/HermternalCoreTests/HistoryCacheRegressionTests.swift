import Foundation
@testable import HermternalCore
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
    let sessionFiles = filenames.filter { !$0.hasPrefix("tail-") }
    #expect(sessionFiles.count == 2)
    #expect(filenames.contains("tail-room%2Eone.json"))
    #expect(filenames.contains("tail-room%2Fone.json"))
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

@Test("warming disk reads do not retain cold transcripts")
func warmingReadDoesNotPopulateMemory() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = HistoryCache(directory: directory)
    _ = await writer.store([ChatMessage(role: .assistant, text: "cold")], for: "session")

    let fileSystem = CountingCacheFileSystem()
    let reader = HistoryCache(directory: directory, fileSystem: fileSystem)
    let warming = await reader.readForWarming(for: "session")
    #expect(warming.transcript?.messages.first?.text == "cold")
    #expect(fileSystem.dataReadCount == 1)

    // A normal read must decode again because the warming read is non-retaining.
    let normal = await reader.read(for: "session")
    #expect(normal.transcript?.messages.first?.text == "cold")
    #expect(fileSystem.dataReadCount == 2)
}

@Test("cancelled cache reads skip decoding and preserve bounded accounting")
func cancelledReadSkipsDecodeAndRetainsAccounting() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = HistoryCache(directory: directory)
    _ = await writer.store(
        [ChatMessage(role: .assistant, text: "cancel me")],
        for: "session"
    )

    let codec = DecodeCountingCacheCodec()
    let reader = HistoryCache(directory: directory, codec: codec)
    let release = ReadReleaseGate()
    let cancelled = Task {
        await release.waitForRelease()
        return await reader.read(for: "session")
    }
    await release.waitUntilWaiting()
    cancelled.cancel()
    await release.release()
    let cancelledResult = await cancelled.value

    #expect(cancelledResult.transcript == nil)
    #expect(codec.decodeCount == 0)
    #expect((await reader.memoryStatistics()).bytes == 0)

    let normal = await reader.read(for: "session")
    #expect(normal.transcript?.messages.first?.text == "cancel me")
    #expect(codec.decodeCount == 1)
}

@Test("same-session reads join one in-flight decode")
func sameSessionReadsJoinInFlightDecode() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = HistoryCache(directory: directory)
    _ = await writer.store(
        [ChatMessage(role: .assistant, text: "join me")],
        for: "session"
    )

    let gate = DecodeReleaseGate()
    let codec = GatedDecodeCountingCacheCodec(gate: gate)
    let reader = HistoryCache(
        directory: directory,
        codec: codec,
        memoryBudgetBytes: 1
    )
    let first = Task { await reader.read(for: "session") }
    gate.waitUntilDecodeStarts()

    let joined = (0..<8).map { _ in
        Task { await reader.read(for: "session") }
    }
    for _ in 0..<8 { await Task.yield() }
    gate.releaseDecode()

    let firstResult = await first.value
    var joinedResults = [(transcript: CachedTranscript?, epoch: UInt64)]()
    for task in joined {
        joinedResults.append(await task.value)
    }
    #expect(firstResult.transcript?.messages.first?.text == "join me")
    #expect(joinedResults.allSatisfy { $0.transcript?.messages.first?.text == "join me" })
    #expect(codec.decodeCount == 1)
}

@Test("warming stores write disk without retaining decoded payloads")
func warmingStoreDoesNotPopulateMemory() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileSystem = CountingCacheFileSystem()
    let cache = HistoryCache(directory: directory, fileSystem: fileSystem)
    _ = await cache.storeForWarming(
        [ChatMessage(role: .assistant, text: "warm")],
        snapshot: nil,
        title: "",
        for: "session",
        expectedEpoch: nil
    )

    #expect(await cache.memoryEntryCount() == 0)
    #expect((await cache.read(for: "session")).transcript?.messages.first?.text == "warm")
    #expect(await cache.memoryEntryCount() == 1)
}

@Test("ordinary cache memory is byte bounded and evicts decoded payloads")
func ordinaryCacheMemoryIsByteBounded() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let budget = 4_096
    let cache = HistoryCache(directory: directory, memoryBudgetBytes: budget)

    for index in 0..<200 {
        _ = await cache.store(
            [ChatMessage(role: .assistant, text: String(repeating: "x", count: 512))],
            for: "session-\(index)"
        )
        let metrics = await cache.memoryStatistics()
        #expect(metrics.bytes <= Int64(budget))
    }

    let bounded = await cache.memoryStatistics()
    #expect(bounded.entryCount < 200)
    #expect(bounded.bytes <= Int64(budget))
    #expect(await cache.memoryEntryCount() == bounded.entryCount)

    _ = await cache.clear()
    #expect((await cache.memoryStatistics()).bytes == 0)
}

@Test("decoded-cache eviction releases the payload before a later disk read")
func decodedCacheEvictionReleasesPayload() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileSystem = CountingCacheFileSystem()
    let cache = HistoryCache(
        directory: directory,
        fileSystem: fileSystem,
        memoryBudgetBytes: 1_500
    )
    let messages = [ChatMessage(role: .assistant, text: String(repeating: "y", count: 1_000))]
    _ = await cache.store(messages, for: "first")
    _ = await cache.store(messages, for: "second")

    let afterWrites = await cache.memoryStatistics()
    #expect(afterWrites.bytes <= 1_500)
    #expect(afterWrites.entryCount <= 1)

    let readsBefore = fileSystem.dataReadCount
    _ = await cache.read(for: "first")
    #expect(fileSystem.dataReadCount > readsBefore)
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
        guard !file.lastPathComponent.hasPrefix("tail-") else { return }
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
    let prefetch: Task<Void, Never> = Task {
        await BoundedPrefetchCoordinator(limit: 1).prefetch(
            ["session"],
            operation: { id in
                await gate.markStarted()
                await gate.waitForRelease()
                let result = await cache.store(
                    [ChatMessage(role: .assistant, text: "stale")],
                    for: id,
                    expectedEpoch: expectedEpoch
                )
                return result.addedEntry ? result : nil
            },
            onResult: { _ in }
        )
    }

    await gate.waitForStart()
    #expect(await cache.clear())
    await gate.release()
    await prefetch.value

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

@Test("visible tail reads v3 cache without starting paged migration")
func visibleTailDoesNotStartPagedMigration() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let messages = (0..<40).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "row \(index)"
        )
    }
    _ = await cache.store(messages, for: "session")

    let tail = await cache.visibleTail(for: "session")
    #expect(tail.map(\.text) == messages.suffix(12).map(\.text))
    #expect(await cache.existingPagedStore(for: "session") == nil)
}

@Test("resident visible tail reads the sidecar without hopping to the cache actor")
func residentVisibleTailReadsSidecarWithoutActorHop() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = HistoryCache(directory: directory)
    let messages = (0..<20).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "sidecar \(index)"
        )
    }
    _ = await writer.store(messages, for: "session")
    let memoryTail = writer.residentVisibleTail(for: "session")
    #expect(memoryTail.map(\.text) == Array(messages.suffix(12).map(\.text)))
    #expect(await writer.existingPagedStore(for: "session") == nil)

    let reader = HistoryCache(directory: directory)
    let diskTail = reader.residentVisibleTail(for: "session")
    #expect(diskTail.map(\.text) == Array(messages.suffix(12).map(\.text)))
    #expect(await reader.existingPagedStore(for: "session") == nil)
}

@Test("concurrent pagedStore callers share one v3 migration")
func concurrentPagedStoreCallersShareOneMigration() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let messages = (0..<40).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "row \(index)"
        )
    }
    _ = await cache.store(messages, for: "session")

    async let first = cache.pagedStore(for: "session")
    async let second = cache.pagedStore(for: "session")
    let left = try await first
    let right = try await second
    #expect(left === right)
    #expect(try await left.summary().messageCount == 40)
    #expect(await cache.existingPagedStore(for: "session") === left)
}

@Test("prefetch fills sidecar memory so a later tail read hits no disk")
func prefetchResidentVisibleTailsAvoidsSidecarDiskOnLaterRead() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = HistoryCache(directory: directory)
    let ids = (0..<8).map { index in "session-\(index)" }
    for id in ids {
        _ = await writer.store(
            [ChatMessage(role: .assistant, text: "sidecar \(id)")],
            for: id
        )
    }
    let fileSystem = CountingCacheFileSystem()
    let reader = HistoryCache(directory: directory, fileSystem: fileSystem)
    reader.prefetchResidentVisibleTails(ids)
    let readsAfterPrefetch = fileSystem.dataReadCount
    #expect(readsAfterPrefetch > 0)
    for id in ids {
        #expect(reader.residentVisibleTail(for: id).map(\.text) == ["sidecar \(id)"])
    }
    #expect(fileSystem.dataReadCount == readsAfterPrefetch)
}

@Test("reconcile does not perform disk I/O on the MainActor")
@MainActor
func reconcileDoesNotPerformDiskIOOnTheMainActor() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileSystem = ThreadRecordingCacheFileSystem()
    let cache = HistoryCache(directory: directory, fileSystem: fileSystem)
    _ = await cache.store(
        [ChatMessage(role: .assistant, text: "reconcile")],
        for: "session"
    )
    fileSystem.resetMainThreadHits()
    _ = await cache.reconcile(validIDs: ["session"])
    #expect(fileSystem.mainThreadHits == 0)
}

@Test("resident visible tail stays inside the keypress budget during reconcile")
func residentVisibleTailStaysBoundedDuringReconcile() async throws {
    let directory = try historyCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = HistoryCache(directory: directory)
    let ids = (0..<24).map { index in "session-\(index)" }
    let messages = (0..<12).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "sidecar row \(index)"
        )
    }
    for id in ids {
        _ = await writer.store(messages, for: id)
    }
    let reader = HistoryCache(directory: directory)
    let reconcile = Task { await reader.reconcile(validIDs: ids) }
    var samples: [Double] = []
    samples.reserveCapacity(ids.count)
    for id in ids {
        let start = ContinuousClock.now
        let tail = reader.residentVisibleTail(for: id)
        let elapsed = start.duration(to: .now)
        #expect(tail.count == 12)
        samples.append(
            Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        )
    }
    _ = await reconcile.value
    let sorted = samples.sorted()
    let rank = Int((95.0 / 100.0 * Double(sorted.count)).rounded(.up))
    let p95 = sorted[min(sorted.count, max(1, rank)) - 1]
    #expect(p95 <= Double(TranscriptPublicationPolicy.keypressPaintBudgetMilliseconds))
    print(
        "PERF|sidecar during reconcile|p95Ms=\(String(format: "%.3f", p95)) samples=\(samples.count)"
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

private actor ReadReleaseGate {
    private var released = false
    private var waiting = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waitingObservers: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        waiting = true
        let observers = waitingObservers
        waitingObservers.removeAll()
        observers.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilWaiting() async {
        guard !waiting else { return }
        await withCheckedContinuation { continuation in
            waitingObservers.append(continuation)
        }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class DecodeReleaseGate: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func waitUntilDecodeStarts() {
        started.wait()
    }

    func markDecodeStarted() {
        started.signal()
        release.wait()
    }

    func releaseDecode() {
        release.signal()
    }
}

private final class GatedDecodeCountingCacheCodec: CacheCodec, @unchecked Sendable {
    private let base = JSONCacheCodec()
    private let gate: DecodeReleaseGate
    private let lock = NSLock()
    private var count = 0

    init(gate: DecodeReleaseGate) {
        self.gate = gate
    }

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
        gate.markDecodeStarted()
        return try base.decode(data)
    }

    func validate(_ data: Data) throws -> Bool {
        try base.validate(data)
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

private final class ThreadRecordingCacheFileSystem: CacheFileSystem, @unchecked Sendable {
    private let base = LocalCacheFileSystem()
    private let lock = NSLock()
    private var hits = 0

    var mainThreadHits: Int {
        lock.lock()
        defer { lock.unlock() }
        return hits
    }

    func resetMainThreadHits() {
        lock.lock()
        hits = 0
        lock.unlock()
    }

    private func recordIfMain() {
        guard Thread.isMainThread else { return }
        lock.lock()
        hits += 1
        lock.unlock()
    }

    func createDirectory(at url: URL) throws {
        recordIfMain()
        try base.createDirectory(at: url)
    }

    func data(at url: URL) throws -> Data {
        recordIfMain()
        return try base.data(at: url)
    }

    func write(_ data: Data, to url: URL) throws {
        recordIfMain()
        try base.write(data, to: url)
    }

    func removeItem(at url: URL) throws {
        recordIfMain()
        try base.removeItem(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        recordIfMain()
        return base.fileExists(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        recordIfMain()
        return try base.contentsOfDirectory(at: url)
    }

    func fileSize(at url: URL) -> Int64? {
        recordIfMain()
        return base.fileSize(at: url)
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
