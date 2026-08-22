import CryptoKit
import Foundation

/// A sidebar row, built from `session.list`.
///
/// `id` is the durable database id. It is **not** usable for
/// `prompt.submit` — opening a session means calling `session.resume` and
/// using the ephemeral live id it returns.
struct ChatSession: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var preview: String
    var startedAt: Date?
    var messageCount: Int

    /// Sidebar label, falling back through preview to a stable placeholder
    /// so a freshly created session never renders blank.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if !preview.isEmpty { return String(preview.prefix(60)) }
        return "New Chat"
    }

    init(from value: JSONValue) {
        id = value["id"]?.stringValue ?? ""
        title = value["title"]?.stringValue ?? ""
        preview = value["preview"]?.stringValue ?? ""
        messageCount = value["message_count"]?.intValue ?? 0
        // `started_at` has appeared as both an epoch number and an ISO
        // string across Hermes releases; accept either.
        if let epoch = value["started_at"]?.doubleValue {
            startedAt = Date(timeIntervalSince1970: epoch)
        } else if let iso = value["started_at"]?.stringValue {
            startedAt = ISO8601DateFormatter().date(from: iso)
        } else {
            startedAt = nil
        }
    }
}

enum Role: String, Codable, Sendable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Codable, Sendable {
    let id: UUID
    var role: Role
    var text: String
    /// True while deltas are still landing, so the view can show a cursor
    /// and skip markdown parsing on the hot path.
    var isStreaming: Bool

    init(id: UUID = UUID(), role: Role, text: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }

    /// Deterministic identity for a message projected from server history.
    static func stableID(
        sessionID: String,
        role: Role,
        text: String,
        occurrence: Int
    ) -> UUID {
        let material = [
            sessionID,
            role.rawValue,
            text,
            String(occurrence)
        ].joined(separator: "\u{001F}")
        var bytes = Array(SHA256.hash(data: Data(material.utf8)).prefix(16))
        // RFC 4122 version 5 and variant bits make this a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Project server history rows into messages with deterministic identity.
    /// Each row is parsed exactly once.
    static func project(historyRows rows: [JSONValue], sessionID: String) -> [ChatMessage] {
        struct Components: Hashable {
            let role: Role
            let text: String
        }

        var occurrences: [Components: Int] = [:]
        return rows.compactMap { row in
            guard let (role, text) = historyComponents(from: row) else { return nil }
            let components = Components(role: role, text: text)
            let occurrence = occurrences[components, default: 0]
            occurrences[components] = occurrence + 1
            return ChatMessage(
                id: stableID(
                    sessionID: sessionID,
                    role: role,
                    text: text,
                    occurrence: occurrence
                ),
                role: role,
                text: text
            )
        }
    }

    private static func historyComponents(from value: JSONValue) -> (Role, String)? {
        guard let rawRole = value["role"]?.stringValue else { return nil }
        // Tool rows arrive as {role:"tool", name:…, context:…} and carry no
        // user-visible prose, so Role rejects them and they are skipped.
        guard let role = Role(rawValue: rawRole) else { return nil }
        // Model-facing scaffolding: compaction references and interrupted-turn
        // checkpoints.
        guard value["display_kind"]?.stringValue != "hidden" else { return nil }
        guard let body = Self.flatten(value["text"]) ?? Self.flatten(value["content"]),
              !body.isEmpty
        else { return nil }
        // The older hidden-row convention predates display_kind.
        guard !body.hasPrefix("[System:") else { return nil }
        return (role, body)
    }

    /// History content is a string on text-only turns and an array of typed
    /// parts once images or tool payloads are involved.
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
