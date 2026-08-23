import Foundation

/// A sidebar row, built from the dashboard REST session list.
///
/// Every field is immutable, and `displayTitle` is derived once when the row is
/// decoded. A sidebar redraw therefore does no string work: it reads a stored
/// value instead of trimming and scanning the preview on every body evaluation.
public struct ChatSession: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let preview: String
    public let startedAt: Date?
    public let lastActive: Date?
    public let pinned: Bool
    public let source: String
    public let profile: String?
    public let messageCount: Int

    /// The row label. Cheap to read, because it is computed at decode time.
    public let displayTitle: String

    private init(
        id: String,
        title: String,
        preview: String,
        startedAt: Date?,
        lastActive: Date?,
        pinned: Bool,
        source: String,
        profile: String?,
        messageCount: Int,
        displayTitle: String
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.startedAt = startedAt
        self.lastActive = lastActive
        self.pinned = pinned
        self.source = source
        self.profile = profile
        self.messageCount = messageCount
        self.displayTitle = displayTitle
    }

    public init(from value: JSONValue) {
        id = value["id"]?.stringValue ?? ""
        let title = value["title"]?.stringValue ?? ""
        let preview = value["preview"]?.stringValue ?? ""
        self.title = title
        self.preview = preview
        messageCount = value["message_count"]?.intValue ?? 0
        startedAt = DateParser.date(from: value["started_at"])
        lastActive = DateParser.date(from: value["last_active"])
        pinned = value["pinned"]?.boolValue ?? false
        source = value["source"]?.stringValue ?? ""
        profile = value["profile"]?.stringValue
        displayTitle = Self.deriveDisplayTitle(title: title, preview: preview)
    }

    /// Returns a copy with only the server pin state changed.
    public func withPinned(_ pinned: Bool) -> ChatSession {
        ChatSession(
            id: id,
            title: title,
            preview: preview,
            startedAt: startedAt,
            lastActive: lastActive,
            pinned: pinned,
            source: source,
            profile: profile,
            messageCount: messageCount,
            displayTitle: displayTitle
        )
    }

    /// Picks the row label, preferring the server title over the preview.
    ///
    /// A title-less chat can carry a machine prompt as its preview, and showing
    /// that as a title is misleading. A preview is rejected when it is blank,
    /// spans lines, or opens with a Markdown heading marker. A value that is
    /// only marker characters is rejected too, because it carries no title text.
    private static func deriveDisplayTitle(title: String, preview: String) -> String {
        // `contains(where:)` short-circuits and allocates nothing, unlike
        // trimming a copy only to test whether it is empty.
        if title.contains(where: { !$0.isWhitespace }) { return title }
        guard let start = preview.firstIndex(where: { !$0.isWhitespace }),
              !preview.contains(where: { $0 == "\n" || $0 == "\r" })
        else { return "New Chat" }
        let body = preview[start...]
        if body.hasPrefix("###") {
            let afterMarker = body.drop(while: { $0 == "#" })
            guard let next = afterMarker.first, !next.isWhitespace else { return "New Chat" }
        }
        return String(body.prefix(60))
    }

    /// `displayTitle` is excluded because it is a pure function of `title` and
    /// `preview`, which are both compared already. Including it would add a
    /// String compare and a String hash with no discriminating power, on a path
    /// that `List` diffing walks for every visible row on every update.
    public static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
        lhs.id == rhs.id
            && lhs.pinned == rhs.pinned
            && lhs.messageCount == rhs.messageCount
            && lhs.lastActive == rhs.lastActive
            && lhs.startedAt == rhs.startedAt
            && lhs.title == rhs.title
            && lhs.preview == rhs.preview
            && lhs.source == rhs.source
            && lhs.profile == rhs.profile
    }

    /// Hashes the durable id only. It is unique per session, so a wider hash
    /// costs work without reducing collisions.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public enum Role: String, Codable, Sendable {
    case user
    case assistant
    case system
}

/// The durable server row identity, used for indexing and links.
public struct ServerMessageID: Hashable, Codable, Sendable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }
}

/// A durable server identity or a live row that has not been persisted yet.
public enum MessageIdentity: Hashable, Sendable {
    case server(ServerMessageID)
    case provisional(UUID)
}

extension MessageIdentity: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "server":
            self = .server(ServerMessageID(rawValue: try container.decode(Int64.self, forKey: .rawValue)))
        case "provisional":
            self = .provisional(try container.decode(UUID.self, forKey: .rawValue))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown message identity kind"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .server(let id):
            try container.encode("server", forKey: .kind)
            try container.encode(id.rawValue, forKey: .rawValue)
        case .provisional(let id):
            try container.encode("provisional", forKey: .kind)
            try container.encode(id, forKey: .rawValue)
        }
    }
}

public struct AuthoritativeTranscriptSnapshot: Codable, Sendable {
    public let sessionID: String
    public let serverTotal: Int?
    public let fetchedRows: Int
    public let projectedMessages: Int
    public let truncated: Bool
    public let fetchedAt: Date

    public init(
        sessionID: String,
        serverTotal: Int?,
        fetchedRows: Int,
        projectedMessages: Int,
        truncated: Bool,
        fetchedAt: Date
    ) {
        self.sessionID = sessionID
        self.serverTotal = serverTotal
        self.fetchedRows = fetchedRows
        self.projectedMessages = projectedMessages
        self.truncated = truncated
        self.fetchedAt = fetchedAt
    }
}

public struct ChatMessage: Identifiable, Codable, Sendable {
    public let id: MessageIdentity
    public var role: Role
    public var text: String
    public var timestamp: Date?
    public var isStreaming: Bool

    public init(
        id: MessageIdentity = .provisional(UUID()),
        role: Role,
        text: String,
        timestamp: Date? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }

    /// Project rows from the authoritative REST transcript. Every persisted
    /// row must carry a durable server id.
    public static func projectREST(historyRows rows: [JSONValue]) -> [ChatMessage] {
        rows.compactMap { row in
            guard let (role, text) = historyComponents(from: row),
                  let rawID = row["id"]?.int64Value
            else { return nil }
            let identity = MessageIdentity.server(ServerMessageID(rawValue: rawID))
            return ChatMessage(
                id: identity,
                role: role,
                text: text,
                timestamp: DateParser.date(from: row["timestamp"])
            )
        }
    }

    /// Compatibility name for callers that provide REST rows.
    public static func project(historyRows rows: [JSONValue], sessionID _: String) -> [ChatMessage] {
        projectREST(historyRows: rows)
    }

    private static func historyComponents(from value: JSONValue) -> (Role, String)? {
        guard let rawRole = value["role"]?.stringValue,
              let role = Role(rawValue: rawRole)
        else { return nil }
        guard value["display_kind"]?.stringValue != "hidden" else { return nil }
        guard let body = flatten(value["text"]) ?? flatten(value["content"]), !body.isEmpty else {
            return nil
        }
        guard !body.hasPrefix("[System:") else { return nil }
        return (role, body)
    }

    private static func flatten(_ content: JSONValue?) -> String? {
        guard let content else { return nil }
        if let text = content.stringValue { return text }
        guard let parts = content.arrayValue else { return nil }
        let texts = parts.compactMap { part -> String? in
            part["text"]?.stringValue ?? part.stringValue
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}

public enum DateParser {
    /// Values whose absolute magnitude is at least 10,000,000,000 are
    /// interpreted as Unix milliseconds; smaller values are Unix seconds.
    /// This keeps ordinary contemporary epoch seconds readable while
    /// accepting the millisecond values returned by REST.
    public static func date(from value: JSONValue?) -> Date? {
        guard let value else { return nil }
        if let string = value.stringValue {
            return date(fromISO8601: string)
        }
        guard let epoch = value.doubleValue, epoch.isFinite else { return nil }

        let millisecondsThreshold = 10_000_000_000.0
        let seconds = abs(epoch) >= millisecondsThreshold ? epoch / 1_000 : epoch
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func date(fromISO8601 string: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
