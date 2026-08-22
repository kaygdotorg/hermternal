import Foundation

/// A sidebar row, built from `session.list`.
public struct ChatSession: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var preview: String
    public var startedAt: Date?
    public var messageCount: Int

    public var displayTitle: String {
        if !title.isEmpty { return title }
        if !preview.isEmpty { return String(preview.prefix(60)) }
        return "New Chat"
    }

    public init(from value: JSONValue) {
        id = value["id"]?.stringValue ?? ""
        title = value["title"]?.stringValue ?? ""
        preview = value["preview"]?.stringValue ?? ""
        messageCount = value["message_count"]?.intValue ?? 0
        startedAt = DateParser.date(from: value["started_at"])
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
