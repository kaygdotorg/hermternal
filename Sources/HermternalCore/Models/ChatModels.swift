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
    public let archived: Bool
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
        archived: Bool,
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
        self.archived = archived
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
        archived = value["archived"]?.boolValue ?? false
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
            archived: archived,
            source: source,
            profile: profile,
            messageCount: messageCount,
            displayTitle: displayTitle
        )
    }

    /// Returns a copy with only the server archive state changed.
    public func withArchived(_ archived: Bool) -> ChatSession {
        ChatSession(
            id: id,
            title: title,
            preview: preview,
            startedAt: startedAt,
            lastActive: lastActive,
            pinned: pinned,
            archived: archived,
            source: source,
            profile: profile,
            messageCount: messageCount,
            displayTitle: displayTitle
        )
    }
    /// Returns a copy with the server title changed.
    public func withTitle(_ title: String) -> ChatSession {
        ChatSession(
            id: id,
            title: title,
            preview: preview,
            startedAt: startedAt,
            lastActive: lastActive,
            pinned: pinned,
            archived: archived,
            source: source,
            profile: profile,
            messageCount: messageCount,
            displayTitle: Self.deriveDisplayTitle(title: title, preview: preview)
        )
    }

    /// Picks the row label, preferring the server title over the preview.
    ///
    /// A title-less chat can carry a machine prompt as its preview, and showing
    /// that as a title is misleading. A preview is rejected when it is blank,
    /// spans lines, or opens with a Markdown heading marker. A value that is
    /// only marker characters is rejected too, because it carries no title text.
    static func deriveDisplayTitle(title: String, preview: String) -> String {
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
            && lhs.archived == rhs.archived
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

public enum CodexReasoningAvailability: String, Codable, Equatable, Sendable {
    case absent
    case presentButUnparseable
    case presentButNotDisplayable
    case presentAndDisplayable
}

/// A Codex field is retained as supplied and, when possible, exposed as the
/// dynamic JSON tree. The payload deliberately has no client-defined item
/// structs: the gateway owns that schema.
public struct CodexSerializedPayload: Codable, Equatable, Sendable {
    public let rawValue: String?
    public let parsedValue: JSONValue?

    public init(rawValue: String?, parsedValue: JSONValue?) {
        self.rawValue = rawValue
        self.parsedValue = parsedValue
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        if let rawValue = value.stringValue {
            self.rawValue = rawValue
            self.parsedValue = try? JSONDecoder().decode(JSONValue.self, from: Data(rawValue.utf8))
        } else {
            self.rawValue = nil
            self.parsedValue = value
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let rawValue {
            try container.encode(rawValue)
        } else if let parsedValue {
            try container.encode(parsedValue)
        } else {
            try container.encodeNil()
        }
    }

    public var isParseable: Bool {
        parsedValue != nil
    }
}

public struct ChatMessage: Identifiable, Codable, Sendable {
    public let id: MessageIdentity
    public var role: Role
    public var text: String
    /// Reasoning is transcript data and remains in the cache so warm and REST
    /// projections render the same content.
    public var reasoning: String?
    public var timestamp: Date?
    public var isStreaming: Bool
    /// Ordinary Codex message items may be cached. Codex reasoning items are
    /// excluded when opaque/encrypted, with only their availability marker
    /// retained so the cache can remain honest without storing unreadable data.
    public var codexMessageItems: CodexSerializedPayload?
    public var codexReasoningItems: CodexSerializedPayload?
    private var persistedCodexReasoningAvailability: CodexReasoningAvailability?

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case reasoning
        case timestamp
        case isStreaming
        case codexMessageItems
        case codexReasoningItems
        case codexReasoningAvailability

    }
    public init(
        id: MessageIdentity = .provisional(UUID()),
        role: Role,
        text: String,
        reasoning: String? = nil,
        timestamp: Date? = nil,
        isStreaming: Bool = false,
        codexMessageItems: CodexSerializedPayload? = nil,
        codexReasoningItems: CodexSerializedPayload? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.codexMessageItems = codexMessageItems
        self.codexReasoningItems = codexReasoningItems
        self.persistedCodexReasoningAvailability = nil
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(MessageIdentity.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        codexMessageItems = try container.decodeIfPresent(CodexSerializedPayload.self, forKey: .codexMessageItems)
        codexReasoningItems = try container.decodeIfPresent(CodexSerializedPayload.self, forKey: .codexReasoningItems)
        persistedCodexReasoningAvailability = try container.decodeIfPresent(
            CodexReasoningAvailability.self,
            forKey: .codexReasoningAvailability
        )
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encodeIfPresent(codexMessageItems, forKey: .codexMessageItems)
        if codexReasoningAvailability == .presentAndDisplayable {
            try container.encodeIfPresent(codexReasoningItems, forKey: .codexReasoningItems)
        } else if codexReasoningAvailability != .absent {
            try container.encode(codexReasoningAvailability, forKey: .codexReasoningAvailability)
        }
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
                reasoning: mergedReasoning(from: row),
                timestamp: DateParser.date(from: row["timestamp"]),
                codexMessageItems: codexPayload(from: row["codex_message_items"]),
                codexReasoningItems: codexPayload(from: row["codex_reasoning_items"])
            )
        }
    }
    /// Projects authoritative rows into the platform-neutral turn document.
    public static func projectTurns(
        historyRows rows: [JSONValue],
        sessionModel: String? = nil
    ) -> [TranscriptTurn] {
        TranscriptTurnProjector.project(
            records: rows.compactMap(WireMessageRecord.init(row:)),
            sessionModel: sessionModel
        )
    }

    /// Compatibility name for callers that provide REST rows.
    public static func project(historyRows rows: [JSONValue], sessionID _: String) -> [ChatMessage] {
        projectREST(historyRows: rows)
    }

    public var codexReasoningAvailability: CodexReasoningAvailability {
        guard let payload = codexReasoningItems else {
            return persistedCodexReasoningAvailability ?? .absent
        }
        guard let parsedValue = payload.parsedValue else { return .presentButUnparseable }
        return Self.containsEncryptedReasoning(in: parsedValue)
            ? .presentButNotDisplayable
            : .presentAndDisplayable
    }

    // REST rows also expose session_id, tool_call_id, tool_calls, tool_name,
    // effect_disposition, token_count, finish_reason, reasoning_details,
    // platform_message_id, observed, active, compacted, api_content,
    // display_kind, and display_metadata. We deliberately do not carry those
    // keys into ChatMessage; display_kind remains an admission filter here.
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

    private static func mergedReasoning(from value: JSONValue) -> String? {
        let reasoning = nonEmptyString(value["reasoning"])
        let reasoningContent = nonEmptyString(value["reasoning_content"])
        switch (reasoning, reasoningContent) {
        case (nil, nil):
            return nil
        case (let value?, nil), (nil, let value?):
            return value
        case (let first?, let second?) where first == second:
            return first
        case (let first?, let second?):
            // The two fields matched in both available redacted REST rows.
            // If a future gateway sends different values, retain both rather
            // than choosing one and silently discarding reasoning.
            return first + "\n\n" + second
        }
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard let value = value?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    private static func codexPayload(from value: JSONValue?) -> CodexSerializedPayload? {
        guard let value else { return nil }
        if let rawValue = value.stringValue {
            let parsedValue = try? JSONDecoder().decode(JSONValue.self, from: Data(rawValue.utf8))
            return CodexSerializedPayload(rawValue: rawValue, parsedValue: parsedValue)
        }
        // A capture contained an already-decoded array. Preserve that shape
        // instead of forcing it through a client-defined Codex model.
        return CodexSerializedPayload(rawValue: nil, parsedValue: value)
    }

    private static func containsEncryptedReasoning(in value: JSONValue) -> Bool {
        switch value {
        case .object(let fields):
            if fields["encrypted_content"] != nil { return true }
            return fields.values.contains { child in
                containsEncryptedReasoning(in: child)
            }
        case .array(let values):
            return values.contains { child in
                containsEncryptedReasoning(in: child)
            }
        default:
            return false
        }
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

    // These value-type styles are safe to share across concurrent REST
    // projections and avoid constructing a formatter per field.
    private static let fractionalISO8601 = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    private static let wholeISO8601 = Date.ISO8601FormatStyle()

    private static func date(fromISO8601 string: String) -> Date? {
        if let date = try? fractionalISO8601.parse(string) {
            return date
        }
        return try? wholeISO8601.parse(string)
    }
}
