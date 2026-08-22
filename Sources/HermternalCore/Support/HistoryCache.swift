import Foundation

public struct CacheStatistics: Sendable {
    public let entryCount: Int
    public let bytes: Int64

    public init(entryCount: Int, bytes: Int64) {
        self.entryCount = entryCount
        self.bytes = bytes
    }
}

public struct CacheStoreResult: Sendable {
    public let addedEntry: Bool
    public let byteDelta: Int64

    public init(addedEntry: Bool, byteDelta: Int64) {
        self.addedEntry = addedEntry
        self.byteDelta = byteDelta
    }
}

public protocol CacheFileSystem: Sendable {
    func createDirectory(at url: URL) throws
    func data(at url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func fileSize(at url: URL) -> Int64?
}

public struct LocalCacheFileSystem: CacheFileSystem {
    public init() {}

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func data(at url: URL) throws -> Data { try Data(contentsOf: url) }

    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
    }

    public func fileSize(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}

public protocol CacheCodec: Sendable {
    func encode(_ transcript: CachedTranscript) throws -> Data
    func decode(_ data: Data) throws -> CachedTranscript
}

public struct JSONCacheCodec: CacheCodec {
    public init() {}

    public func encode(_ transcript: CachedTranscript) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(transcript)
    }

    public func decode(_ data: Data) throws -> CachedTranscript {
        try JSONDecoder().decode(CachedTranscript.self, from: data)
    }
}

public struct CachedTranscript: Codable, Sendable {
    public let version: Int
    public let messages: [ChatMessage]
    public let snapshot: AuthoritativeTranscriptSnapshot?

    public init(
        version: Int,
        messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot?
    ) {
        self.version = version
        self.messages = messages
        self.snapshot = snapshot
    }
}

/// Disk-backed transcript cache keyed by durable session id.
public actor HistoryCache {
    /// Version 3 invalidates files containing the retired content-hash IDs.
    public static let version = 3

    private let directory: URL
    private let fileSystem: any CacheFileSystem
    private let codec: any CacheCodec
    private var memory: [String: CachedTranscript] = [:]
    // A write is valid only if no clear happened after the read it derives
    // from. The epoch is actor-local so checking it and touching disk are
    // one atomic operation relative to clear().
    private var epoch: UInt64 = 0

    public init(
        directory: URL? = nil,
        fileSystem: any CacheFileSystem = LocalCacheFileSystem(),
        codec: any CacheCodec = JSONCacheCodec()
    ) {
        self.directory = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/\(AppIdentity.bundleID)/history", directoryHint: .isDirectory)
        self.fileSystem = fileSystem
        self.codec = codec
        try? fileSystem.createDirectory(at: self.directory)
    }

    private func url(for id: String) -> URL {
        let slug = id.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        return directory.appending(path: "\(slug).json")
    }

    public func messages(for id: String) -> [ChatMessage]? {
        transcript(for: id)?.messages
    }

    public func snapshot(for id: String) -> AuthoritativeTranscriptSnapshot? {
        transcript(for: id)?.snapshot
    }

    public func read(for id: String) -> (transcript: CachedTranscript?, epoch: UInt64) {
        let observedEpoch = epoch
        if let hit = memory[id] { return (hit, observedEpoch) }
        let target = url(for: id)
        guard let data = try? fileSystem.data(at: target),
              let stored = try? codec.decode(data),
              stored.version == Self.version
        else {
            try? fileSystem.removeItem(at: target)
            return (nil, observedEpoch)
        }
        memory[id] = stored
        return (stored, observedEpoch)
    }

    public func currentEpoch() -> UInt64 { epoch }

    public func transcript(for id: String) -> CachedTranscript? {
        read(for: id).transcript
    }

    @discardableResult
    public func store(
        _ messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot? = nil,
        for id: String,
        expectedEpoch: UInt64? = nil
    ) -> CacheStoreResult {
        let authorizedEpoch = expectedEpoch ?? epoch
        guard authorizedEpoch == epoch, !Task.isCancelled else {
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        let payload = CachedTranscript(version: Self.version, messages: messages, snapshot: snapshot)
        guard let data = try? codec.encode(payload),
              authorizedEpoch == epoch,
              !Task.isCancelled
        else {
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        let target = url(for: id)
        let oldData = try? fileSystem.data(at: target)
        let existed = fileSystem.fileExists(at: target)
        if oldData == data {
            memory[id] = payload
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        let oldSize = oldData.map { Int64($0.count) } ?? fileSystem.fileSize(at: target) ?? 0
        guard authorizedEpoch == epoch,
              (try? fileSystem.write(data, to: target)) != nil
        else {
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        memory[id] = payload
        return CacheStoreResult(
            addedEntry: !existed,
            byteDelta: Int64(data.count) - oldSize
        )
    }

    public func isCached(_ id: String) -> Bool { transcript(for: id) != nil }

    public func reconcile(validIDs: [String]) -> CacheStatistics {
        let valid = Set(validIDs)
        memory = memory.filter { valid.contains($0.key) }
        guard let files = try? fileSystem.contentsOfDirectory(at: directory) else {
            return CacheStatistics(entryCount: 0, bytes: 0)
        }
        let idByPath = Dictionary(uniqueKeysWithValues: validIDs.map { (url(for: $0).path, $0) })
        var bytes: Int64 = 0
        var count = 0
        for file in files where file.pathExtension == "json" {
            guard let id = idByPath[file.path] else {
                try? fileSystem.removeItem(at: file)
                continue
            }
            guard let data = try? fileSystem.data(at: file),
                  let stored = try? codec.decode(data),
                  stored.version == Self.version
            else {
                memory[id] = nil
                try? fileSystem.removeItem(at: file)
                continue
            }
            memory[id] = stored
            count += 1
            bytes += Int64(data.count)
        }
        return CacheStatistics(entryCount: count, bytes: bytes)
    }

    @discardableResult
    public func clear() -> Bool {
        epoch &+= 1
        guard !Task.isCancelled else { return false }
        do {
            if fileSystem.fileExists(at: directory) { try fileSystem.removeItem(at: directory) }
            memory.removeAll()
            try fileSystem.createDirectory(at: directory)
            return true
        } catch {
            return false
        }
    }


}
