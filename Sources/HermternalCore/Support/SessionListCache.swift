import Foundation

/// Disk snapshot of the sidebar session list.
///
/// The file lives beside HistoryCache under the bundle cache directory.
/// A write occurs only when the encoded bytes change.
public final class SessionListCache: @unchecked Sendable {
    public static let sessionsFileName = "sessions.json"
    public static let selectedSessionFileName = "selected-session-id"
    public static let schemaVersion = 1

    public static func cacheDirectory(cachesDirectory: URL) -> URL {
        cachesDirectory.appending(path: AppIdentity.bundleID, directoryHint: .isDirectory)
    }

    public static func fileURL(cachesDirectory: URL) -> URL {
        cacheDirectory(cachesDirectory: cachesDirectory)
            .appending(path: sessionsFileName)
    }

    public static func selectedSessionFileURL(cachesDirectory: URL) -> URL {
        cacheDirectory(cachesDirectory: cachesDirectory)
            .appending(path: selectedSessionFileName)
    }

    /// Resolves the list directory from a HistoryCache storage directory.
    ///
    /// Production history lives in `Caches/<bundle>/history`. Tests inject a
    /// temporary directory and keep the list file inside that tree.
    public static func directory(forHistoryDirectory historyDirectory: URL) -> URL {
        if historyDirectory.lastPathComponent == "history" {
            return historyDirectory.deletingLastPathComponent()
        }
        return historyDirectory
    }

    private let directory: URL?
    private let fileSystem: any CacheFileSystem
    private var sessionsDigest: UInt64?
    private var selectedDigest: UInt64?

    public init(
        directory: URL?,
        fileSystem: any CacheFileSystem = LocalCacheFileSystem()
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
    }

    public var sessionsFileURL: URL? {
        directory?.appending(path: Self.sessionsFileName)
    }

    public var selectedSessionFileURL: URL? {
        directory?.appending(path: Self.selectedSessionFileName)
    }

    /// Reads the sidebar snapshot. A missing or malformed file yields no rows.
    public func loadSessions() -> [ChatSession] {
        guard let fileURL = sessionsFileURL,
              fileSystem.fileExists(at: fileURL),
              let data = try? fileSystem.data(at: fileURL),
              let decoded = try? JSONDecoder().decode(SessionListFile.self, from: data),
              decoded.schemaVersion == Self.schemaVersion
        else {
            sessionsDigest = nil
            return []
        }
        sessionsDigest = ContentDigest.value(for: data)
        return decoded.sessions.map(\.session)
    }

    /// Writes the sidebar snapshot when the encoded bytes change.
    @discardableResult
    public func saveSessions(_ sessions: [ChatSession]) -> Bool {
        guard let directory, let fileURL = sessionsFileURL else { return false }
        let payload = SessionListFile(
            schemaVersion: Self.schemaVersion,
            sessions: sessions.map(SessionListRecord.init(session:))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return false }
        let digest = ContentDigest.value(for: data)
        guard digest != sessionsDigest else { return false }
        do {
            try fileSystem.createDirectory(at: directory)
            try fileSystem.write(data, to: fileURL)
            sessionsDigest = digest
            return true
        } catch {
            return false
        }
    }

    public func loadSelectedSessionID() -> String? {
        guard let fileURL = selectedSessionFileURL,
              fileSystem.fileExists(at: fileURL),
              let data = try? fileSystem.data(at: fileURL)
        else {
            selectedDigest = nil
            return nil
        }
        selectedDigest = ContentDigest.value(for: data)
        let id = String(decoding: data, as: UTF8.self)
        return id.isEmpty ? nil : id
    }

    /// Writes the selected chat id when the stored bytes change.
    @discardableResult
    public func saveSelectedSessionID(_ id: String?) -> Bool {
        guard let directory, let fileURL = selectedSessionFileURL else { return false }
        let data = Data((id ?? "").utf8)
        let digest = ContentDigest.value(for: data)
        if id == nil || id?.isEmpty == true {
            guard fileSystem.fileExists(at: fileURL) else {
                selectedDigest = nil
                return false
            }
            try? fileSystem.removeItem(at: fileURL)
            selectedDigest = nil
            return true
        }
        guard digest != selectedDigest else { return false }
        do {
            try fileSystem.createDirectory(at: directory)
            try fileSystem.write(data, to: fileURL)
            selectedDigest = digest
            return true
        } catch {
            return false
        }
    }

    public func clear() {
        if let fileURL = sessionsFileURL, fileSystem.fileExists(at: fileURL) {
            try? fileSystem.removeItem(at: fileURL)
        }
        if let fileURL = selectedSessionFileURL, fileSystem.fileExists(at: fileURL) {
            try? fileSystem.removeItem(at: fileURL)
        }
        sessionsDigest = nil
        selectedDigest = nil
    }
}

private struct SessionListFile: Codable, Equatable {
    var schemaVersion: Int
    var sessions: [SessionListRecord]
}

private struct SessionListRecord: Codable, Equatable {
    var id: String
    var title: String
    var preview: String
    var startedAt: Double?
    var lastActive: Double?
    var pinned: Bool
    var archived: Bool
    var source: String
    var profile: String?
    var messageCount: Int

    init(session: ChatSession) {
        id = session.id
        title = session.title
        preview = session.preview
        startedAt = session.startedAt?.timeIntervalSince1970
        lastActive = session.lastActive?.timeIntervalSince1970
        pinned = session.pinned
        archived = session.archived
        source = session.source
        profile = session.profile
        messageCount = session.messageCount
    }

    var session: ChatSession {
        ChatSession(
            id: id,
            title: title,
            preview: preview,
            startedAt: startedAt.map(Date.init(timeIntervalSince1970:)),
            lastActive: lastActive.map(Date.init(timeIntervalSince1970:)),
            pinned: pinned,
            archived: archived,
            source: source,
            profile: profile,
            messageCount: messageCount
        )
    }
}

/// A stable, allocation-light digest for encoded bytes.
private enum ContentDigest {
    static func value(for data: Data) -> UInt64 {
        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return digest
    }
}
