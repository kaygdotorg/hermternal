import Foundation
@testable import HermternalCore
import Testing

@Test("A session list round trip preserves sidebar fields")
func sessionListCacheRoundTripPreservesFields() throws {
    let directory = try sessionListCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = SessionListCache(directory: directory)
    let session = ChatSession(
        id: "chat-1",
        title: "Planning",
        preview: "Next steps",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastActive: Date(timeIntervalSince1970: 1_700_000_100),
        pinned: true,
        archived: false,
        source: "chat",
        profile: "work",
        messageCount: 4
    )

    #expect(cache.saveSessions([session]))
    let reloaded = SessionListCache(directory: directory).loadSessions()

    #expect(reloaded == [session])
}

@Test("An identical session list save performs no write")
func sessionListCacheIdenticalSaveSkipsWrite() throws {
    let directory = try sessionListCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileSystem = WriteCountingCacheFileSystem()
    let cache = SessionListCache(directory: directory, fileSystem: fileSystem)
    let session = ChatSession(id: "chat-1", title: "Planning", messageCount: 2)

    #expect(cache.saveSessions([session]))
    let writesAfterFirstSave = fileSystem.writeCount
    #expect(!cache.saveSessions([session]))
    #expect(fileSystem.writeCount == writesAfterFirstSave)
}

@Test("A selected session id writes only when the value changes")
func sessionListCacheSelectedIDWriteIsContentGuarded() throws {
    let directory = try sessionListCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileSystem = WriteCountingCacheFileSystem()
    let cache = SessionListCache(directory: directory, fileSystem: fileSystem)

    #expect(cache.saveSelectedSessionID("chat-1"))
    let writesAfterFirstSave = fileSystem.writeCount
    #expect(!cache.saveSelectedSessionID("chat-1"))
    #expect(fileSystem.writeCount == writesAfterFirstSave)
    #expect(cache.loadSelectedSessionID() == "chat-1")
}

@Test("Clearing the session list removes both snapshot files")
func sessionListCacheClearRemovesFiles() throws {
    let directory = try sessionListCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = SessionListCache(directory: directory)
    #expect(cache.saveSessions([ChatSession(id: "chat-1")]))
    #expect(cache.saveSelectedSessionID("chat-1"))

    cache.clear()

    #expect(cache.loadSessions().isEmpty)
    #expect(cache.loadSelectedSessionID() == nil)
    #expect(!FileManager.default.fileExists(atPath: cache.sessionsFileURL!.path))
    #expect(!FileManager.default.fileExists(atPath: cache.selectedSessionFileURL!.path))
}

@Test("Session list files sit beside the history directory")
func sessionListCachePathSitsBesideHistory() {
    let caches = URL(fileURLWithPath: "/fixture/caches", isDirectory: true)
    let history = HistoryCache.historyDirectory(cachesDirectory: caches)

    #expect(
        SessionListCache.directory(forHistoryDirectory: history)
            == SessionListCache.cacheDirectory(cachesDirectory: caches)
    )
    #expect(
        SessionListCache.fileURL(cachesDirectory: caches).path
            == "/fixture/caches/\(AppIdentity.bundleID)/sessions.json"
    )
}

@Test("A malformed session list file leaves the original bytes")
func sessionListCacheMalformedFileIsIgnored() throws {
    let directory = try sessionListCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: SessionListCache.sessionsFileName)
    let original = Data(#"{"schemaVersion":"bad"}"#.utf8)
    try original.write(to: fileURL)
    let cache = SessionListCache(directory: directory)

    #expect(cache.loadSessions().isEmpty)
    #expect(try Data(contentsOf: fileURL) == original)
}

private func sessionListCacheTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalSessionListCache-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private final class WriteCountingCacheFileSystem: CacheFileSystem, @unchecked Sendable {
    private let base = LocalCacheFileSystem()
    private let lock = NSLock()
    private var writes = 0

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }

    func data(at url: URL) throws -> Data { try base.data(at: url) }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        writes += 1
        lock.unlock()
        try base.write(data, to: url)
    }

    func removeItem(at url: URL) throws { try base.removeItem(at: url) }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }

    func fileSize(at url: URL) -> Int64? { base.fileSize(at: url) }
}
