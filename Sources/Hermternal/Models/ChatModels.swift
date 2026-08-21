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

enum Role: String, Sendable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Sendable {
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

    /// Build from a `session.resume` / `session.history` history row.
    init?(historyRow value: JSONValue) {
        guard let rawRole = value["role"]?.stringValue else { return nil }
        // Tool rows carry no user-visible prose; skip them in v1.
        guard let role = Role(rawValue: rawRole) else { return nil }
        let content = Self.flatten(value["content"]) ?? ""
        guard !content.isEmpty else { return nil }
        self.init(role: role, text: content)
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
