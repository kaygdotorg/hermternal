import Foundation

/// Disk-backed transcript cache keyed by durable session id.
///
/// Switching chats must not wait on the network, so the cache is read
/// synchronously from memory on the main actor and written back
/// asynchronously. Entries survive relaunch, so a warm app is instant from
/// the first click.
actor HistoryCache {
    /// Bump when `CachedTranscript` changes shape, so stale files are
    /// discarded rather than mis-decoded.
    private static let version = 1

    private var memory: [String: [ChatMessage]] = [:]

    private var directory: URL {
        let base = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(
                path: "Library/Caches/com.kayg.hermternal/history",
                directoryHint: .isDirectory
            )
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
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
        guard let data = try? Data(contentsOf: url(for: id)),
              let stored = try? JSONDecoder().decode(CachedTranscript.self, from: data),
              stored.version == Self.version
        else { return nil }
        memory[id] = stored.messages
        return stored.messages
    }

    func store(_ messages: [ChatMessage], for id: String) {
        memory[id] = messages
        let payload = CachedTranscript(version: Self.version, messages: messages)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url(for: id), options: [.atomic])
    }

    func isCached(_ id: String) -> Bool {
        memory[id] != nil || FileManager.default.fileExists(atPath: url(for: id).path)
    }

    /// Drop everything, including the on-disk copies.
    func clear() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private struct CachedTranscript: Codable {
        let version: Int
        let messages: [ChatMessage]
    }
}
