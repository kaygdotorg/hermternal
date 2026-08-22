import Foundation

/// Disk-backed transcript cache keyed by durable session id.
///
/// Switching chats must not wait on the network, so the cache is read
/// synchronously from memory on the main actor and written back
/// asynchronously. Entries survive relaunch, so a warm app is instant from
/// the first click.
struct CacheStatistics: Sendable {
    let entryCount: Int
    let bytes: Int64
}
struct CacheStoreResult: Sendable {
    let addedEntry: Bool
    let byteDelta: Int64
}


actor HistoryCache {
    /// Bump when `CachedTranscript` changes shape, so stale files are
    /// discarded rather than mis-decoded.
    private static let version = 2

    private let directory: URL
    private var memory: [String: [ChatMessage]] = [:]

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = FileManager.default
                .homeDirectoryForCurrentUser
                .appending(
                    path: "Library/Caches/\(AppIdentity.bundleID)/history",
                    directoryHint: .isDirectory
                )
        }
        try? FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true
        )
    }

    /// Durable ids are timestamp-and-hex slugs, but sanitise anyway so a new
    /// id shape can never escape the cache directory.
    private func url(for id: String) -> URL {
        let slug = id.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        return directory.appending(path: "\(slug).json")
    }

    /// Memory first, then disk. A disk hit is promoted so the next read is
    /// allocation-free.
    func messages(for id: String) -> [ChatMessage]? {
        if let hit = memory[id] { return hit }
        let target = url(for: id)
        guard let data = try? Data(contentsOf: target) else { return nil }
        guard let stored = try? JSONDecoder().decode(CachedTranscript.self, from: data),
              stored.version == Self.version
        else {
            // A subsequent store must count the replacement as a new valid
            // entry, so remove the invalid current-path file now.
            try? FileManager.default.removeItem(at: target)
            return nil
        }
        memory[id] = stored.messages
        return stored.messages
    }

    @discardableResult
    func store(_ messages: [ChatMessage], for id: String) -> CacheStoreResult {
        guard !Task.isCancelled else {
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        let payload = CachedTranscript(version: Self.version, messages: messages)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload), !Task.isCancelled else {
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }

        let target = url(for: id)
        let oldData = try? Data(contentsOf: target)
        let existed = FileManager.default.fileExists(atPath: target.path)
        if oldData == data {
            memory[id] = messages
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        let oldSize = oldData.map { Int64($0.count) }
            ?? Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard (try? data.write(to: target, options: [.atomic])) != nil else {
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        memory[id] = messages
        return CacheStoreResult(
            addedEntry: !existed,
            byteDelta: Int64(data.count) - oldSize
        )
    }

    func isCached(_ id: String) -> Bool {
        messages(for: id) != nil
    }

    /// Prune entries for sessions no longer listed, validate every retained
    /// entry, and promote valid transcripts into memory.
    ///
    /// Validation matters for progress: merely finding a file at the current
    /// path can falsely report 100% when the JSON is corrupt or from an older
    /// schema. Decoding here costs one startup pass, but also makes every
    /// subsequent chat switch a memory hit.
    func reconcile(validIDs: [String]) -> CacheStatistics {
        let valid = Set(validIDs)
        memory = memory.filter { valid.contains($0.key) }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return CacheStatistics(entryCount: 0, bytes: 0)
        }

        let idByPath = Dictionary(
            uniqueKeysWithValues: validIDs.map { (url(for: $0).path, $0) }
        )
        var bytes: Int64 = 0
        var count = 0
        for file in files where file.pathExtension == "json" {
            guard let id = idByPath[file.path] else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            guard let data = try? Data(contentsOf: file),
                  let stored = try? JSONDecoder().decode(CachedTranscript.self, from: data),
                  stored.version == Self.version
            else {
                memory[id] = nil
                try? FileManager.default.removeItem(at: file)
                continue
            }
            memory[id] = stored.messages
            count += 1
            bytes += Int64(data.count)
        }
        return CacheStatistics(entryCount: count, bytes: bytes)
    }

    /// Drop everything, including the on-disk copies. A canceled stale
    /// control task must not clear after a newer enable/rebuild has won.
    @discardableResult
    func clear() -> Bool {
        guard !Task.isCancelled else { return false }
        let target = directory
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            memory.removeAll()
            return true
        } catch {
            return false
        }
    }

    private struct CachedTranscript: Codable {
        let version: Int
        let messages: [ChatMessage]
    }
}
