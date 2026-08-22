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
    #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 2)
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
