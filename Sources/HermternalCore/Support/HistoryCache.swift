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

/// Core transcript persistence seam. Plain HistoryCache is the no-search
/// implementation; SearchIndexReconciliation decorates the same boundary.
public protocol TranscriptPersisting: Sendable {
    func read(for id: String) async -> (transcript: CachedTranscript?, epoch: UInt64)
    func currentEpoch() async -> UInt64
    func store(
        _ messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot?,
        title: String,
        for id: String,
        expectedEpoch: UInt64?
    ) async throws -> CacheStoreResult
    func remove(sessionID: String) async throws -> Bool
    func clear() async throws -> Bool
    func reconcile(validIDs: [String]) async throws -> CacheStatistics
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

public actor HistoryCache: TranscriptPersisting {
    /// Version 3 invalidates files containing the retired content-hash IDs.
    public static let version = 3

    private let directory: URL?
    private let fileSystem: any CacheFileSystem
    private let codec: any CacheCodec
    private var memory: [String: CachedTranscript] = [:]
    // A write is valid only if no clear happened after the read it derives
    // from. The epoch is actor-local so checking it and touching disk are
    // one atomic operation relative to clear().
    private var epoch: UInt64 = 0

    /// Returns the app-owned history location under the platform's caches
    /// directory. On macOS this preserves the existing bundle-specific path.
    public static func historyDirectory(cachesDirectory: URL) -> URL {
        cachesDirectory
            .appending(path: "\(AppIdentity.bundleID)/history", directoryHint: .isDirectory)
    }

    /// Resolves the platform's caches directory without falling back to a
    /// home-directory path.
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        guard let cachesDirectory = fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first
        else {
            return nil
        }
        return historyDirectory(cachesDirectory: cachesDirectory)
    }

    public init(
        directory: URL? = nil,
        fileSystem: any CacheFileSystem = LocalCacheFileSystem(),
        codec: any CacheCodec = JSONCacheCodec()
    ) {
        self.directory = directory ?? Self.defaultDirectory()
        self.fileSystem = fileSystem
        self.codec = codec
        if let directory = self.directory {
            try? fileSystem.createDirectory(at: directory)
        }
    }

    private func url(for id: String) -> URL? {
        guard let directory else { return nil }
        return URL(fileURLWithPath: directory.path + "/" + encodedFilename(for: id) + ".json")
    }

    /// The legacy filename, retained only to migrate caches written before
    /// punctuation was made injective.
    private func legacyURL(for id: String) -> URL? {
        guard let directory else { return nil }
        let slug = id.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        return URL(fileURLWithPath: directory.path + "/" + slug + ".json")
    }

    /// Keep ordinary IDs readable while escaping every other UTF-8 byte.
    /// Escaping bytes, rather than scalars, makes the mapping injective for
    /// both punctuation and non-ASCII IDs.
    private func encodedFilename(for id: String) -> String {
        id.utf8.reduce(into: "") { result, byte in
            if (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122) {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
    }

    private func storedTranscript(at url: URL) -> CachedTranscript? {
        guard let data = try? fileSystem.data(at: url),
              let stored = try? codec.decode(data),
              stored.version == Self.version
        else {
            return nil
        }
        return stored
    }

    @discardableResult
    private func adoptLegacyTranscript(
        _ stored: CachedTranscript,
        for id: String,
        from legacy: URL,
        to target: URL
    ) -> Bool {
        guard let migrated = try? codec.encode(stored),
              (try? fileSystem.write(migrated, to: target)) != nil
        else {
            memory[id] = stored
            return false
        }
        try? fileSystem.removeItem(at: legacy)
        memory[id] = stored
        return true
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
        guard let target = url(for: id) else {
            return (nil, observedEpoch)
        }
        if let stored = storedTranscript(at: target) {
            memory[id] = stored
            return (stored, observedEpoch)
        }
        try? fileSystem.removeItem(at: target)

        guard let legacy = legacyURL(for: id), legacy.path != target.path else {
            return (nil, observedEpoch)
        }
        guard let stored = storedTranscript(at: legacy) else {
            try? fileSystem.removeItem(at: legacy)
            return (nil, observedEpoch)
        }
        _ = adoptLegacyTranscript(stored, for: id, from: legacy, to: target)
        return (stored, observedEpoch)
    }

    public func currentEpoch() -> UInt64 { epoch }
    /// TranscriptPersisting overload; plain cache ignores the title because
    /// it stores message history only.
    public func store(
        _ messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot?,
        title _: String,
        for id: String,
        expectedEpoch: UInt64?
    ) -> CacheStoreResult {
        store(messages, snapshot: snapshot, for: id, expectedEpoch: expectedEpoch)
    }

    @discardableResult
    public func remove(sessionID: String) -> Bool {
        memory[sessionID] = nil
        let targets = [url(for: sessionID), legacyURL(for: sessionID)]
            .compactMap { $0 }
            .reduce(into: [String: URL]()) { result, target in
                result[target.path] = target
            }
            .values
        var success = true
        for target in targets where fileSystem.fileExists(at: target) {
            do {
                try fileSystem.removeItem(at: target)
            } catch {
                success = false
            }
        }
        return success
    }

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
        if memory[id] == nil {
            _ = read(for: id)
        }
        let payload = CachedTranscript(version: Self.version, messages: messages, snapshot: snapshot)
        guard let data = try? codec.encode(payload),
              authorizedEpoch == epoch,
              !Task.isCancelled
        else {
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        guard let target = url(for: id) else {
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
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
        guard let directory,
              let files = try? fileSystem.contentsOfDirectory(at: directory)
        else {
            return CacheStatistics(entryCount: 0, bytes: 0)
        }
        let idByPath: [String: String] = Dictionary(
            uniqueKeysWithValues: validIDs.compactMap { id -> (String, String)? in
                guard let url = url(for: id) else { return nil }
                return (url.path, id)
            }
        )
        let legacyIDsByPath = Dictionary(
            grouping: validIDs.compactMap { id -> (String, String)? in
                guard let legacy = legacyURL(for: id) else { return nil }
                return (legacy.path, id)
            },
            by: { $0.0 }
        )
        let filePaths = Set(files.map(\.path))
        var bytes: Int64 = 0
        var count = 0
        for file in files where file.pathExtension == "json" {
            let id: String
            let isLegacy: Bool
            if let currentID = idByPath[file.path] {
                id = currentID
                isLegacy = false
            } else if let candidates = legacyIDsByPath[file.path], candidates.count == 1 {
                id = candidates[0].1
                isLegacy = true
                guard let target = url(for: id) else { continue }
                if filePaths.contains(target.path) {
                    try? fileSystem.removeItem(at: file)
                    continue
                }
            } else if legacyIDsByPath[file.path] != nil {
                // A legacy collision cannot be assigned safely. Keep it for
                // a direct read rather than deleting a user's only copy.
                continue
            } else {
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
            if isLegacy, let target = url(for: id) {
                _ = adoptLegacyTranscript(stored, for: id, from: file, to: target)
                bytes += fileSystem.fileSize(at: target) ?? Int64(data.count)
            } else {
                memory[id] = stored
                bytes += Int64(data.count)
            }
            count += 1
        }
        return CacheStatistics(entryCount: count, bytes: bytes)
    }

    @discardableResult
    public func clear() -> Bool {
        epoch &+= 1
        guard !Task.isCancelled, let directory else { return false }
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
