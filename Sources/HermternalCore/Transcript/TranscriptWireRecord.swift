import Foundation

/// A message or metadata row stored by the transcript store.
public struct WireMessageRecord: Codable, Hashable, Sendable, Identifiable {
    public let messageID: String
    public var role: String
    public var text: String
    public var reasoning: String?
    public var timestamp: Date?
    public var revision: UInt64
    /// Durable gateway classification. Only `model_switch` has model meaning.
    public var displayKind: String?
    public var displayMetadata: [String: JSONValue]?
    public var toolCallID: String?
    public var toolName: String?
    public var toolInput: String?
    public var toolOutput: String?
    public var toolStatus: String?
    public var turnID: String?

    public var id: String { messageID }

    public init(
        messageID: String,
        role: String = "assistant",
        text: String,
        reasoning: String? = nil,
        timestamp: Date? = nil,
        revision: UInt64 = 0,
        displayKind: String? = nil,
        displayMetadata: [String: JSONValue]? = nil,
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolInput: String? = nil,
        toolOutput: String? = nil,
        toolStatus: String? = nil,
        turnID: String? = nil
    ) {
        precondition(!messageID.isEmpty, "A message ID must not be empty")
        self.messageID = messageID
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.timestamp = timestamp
        self.revision = revision
        self.displayKind = displayKind
        self.displayMetadata = displayMetadata
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolOutput = toolOutput
        self.toolStatus = toolStatus
        self.turnID = turnID
    }

    public init(id: String, role: String = "assistant", text: String, reasoning: String? = nil, timestamp: Date? = nil, revision: UInt64 = 0, displayKind: String? = nil, displayMetadata: [String: JSONValue]? = nil, toolCallID: String? = nil, toolName: String? = nil, toolInput: String? = nil, toolOutput: String? = nil, toolStatus: String? = nil, turnID: String? = nil) {
        self.init(messageID: id, role: role, text: text, reasoning: reasoning, timestamp: timestamp, revision: revision, displayKind: displayKind, displayMetadata: displayMetadata, toolCallID: toolCallID, toolName: toolName, toolInput: toolInput, toolOutput: toolOutput, toolStatus: toolStatus, turnID: turnID)
    }

    public init(messageID: String, text: String, revision: UInt64 = 0) {
        self.init(messageID: messageID, role: "assistant", text: text, revision: revision)
    }

    public init(messageID: String, role: Role, text: String, reasoning: String? = nil, timestamp: Date? = nil, revision: UInt64 = 0) {
        self.init(messageID: messageID, role: role.rawValue, text: text, reasoning: reasoning, timestamp: timestamp, revision: revision)
    }

    /// Builds a record from one authoritative REST row without losing metadata.
    public init?(row: JSONValue) {
        let rawID: String
        if let value = row["id"]?.stringValue ?? row["message_id"]?.stringValue {
            rawID = value
        } else if let value = row["id"]?.int64Value ?? row["message_id"]?.int64Value {
            rawID = String(value)
        } else {
            return nil
        }
        guard !rawID.isEmpty else { return nil }
        let metadata: [String: JSONValue]?
        if case .object(let values) = row["display_metadata"] { metadata = values } else { metadata = nil }
        self.init(
            messageID: rawID,
            role: row["role"]?.stringValue ?? "assistant",
            text: WireMessageRecord.flatten(row["text"] ?? row["content"]),
            reasoning: row["reasoning"]?.stringValue ?? row["reasoning_content"]?.stringValue,
            timestamp: DateParser.date(from: row["timestamp"]),
            revision: UInt64(max(0, row["revision"]?.intValue ?? 0)),
            displayKind: row["display_kind"]?.stringValue,
            displayMetadata: metadata,
            toolCallID: row["tool_call_id"]?.stringValue ?? row["call_id"]?.stringValue,
            toolName: row["tool_name"]?.stringValue ?? row["name"]?.stringValue,
            toolInput: WireMessageRecord.flatten(row["tool_input"] ?? row["input"]),
            toolOutput: WireMessageRecord.flatten(row["tool_output"] ?? row["output"] ?? row["result"]),
            toolStatus: row["tool_status"]?.stringValue ?? row["status"]?.stringValue,
            turnID: row["turn_id"]?.stringValue
        )
    }

    public var isModelSwitch: Bool { displayKind == "model_switch" }

    public var isToolEvent: Bool {
        if toolCallID != nil || toolName != nil { return true }
        guard let displayKind else { return role.lowercased() == "tool" }
        return displayKind == "tool" || displayKind.hasPrefix("tool_") || displayKind.hasPrefix("tool.")
    }

    public var isRenderable: Bool {
        !isModelSwitch && displayKind != "hidden" && (isToolEvent || !text.isEmpty || !(reasoning?.isEmpty ?? true))
    }

    public var isSearchable: Bool {
        isRenderable && !isToolEvent && displayKind != "system_metadata"
    }

    public var modelSwitchName: String? {
        guard isModelSwitch else { return nil }
        return Self.nonEmpty(displayMetadata?["model"]?.stringValue)
            ?? Self.nonEmpty(displayMetadata?["model_id"]?.stringValue)
            ?? Self.nonEmpty(displayMetadata?["name"]?.stringValue)
    }

    public var reasoningEffort: String? {
        Self.nonEmpty(displayMetadata?["reasoning_effort"]?.stringValue)
            ?? Self.nonEmpty(displayMetadata?["reasoningEffort"]?.stringValue)
            ?? Self.nonEmpty(displayMetadata?["effort"]?.stringValue)
    }

    public var toolID: String {
        toolCallID ?? displayMetadata?["tool_call_id"]?.stringValue
            ?? displayMetadata?["call_id"]?.stringValue
            ?? messageID
    }
    public var toolState: TranscriptToolState? {
        guard let status = toolStatus?.lowercased() else {
            return isToolEvent ? .running : nil
        }
        switch status {
        case "start", "started", "progress", "running":
            return .running
        case "complete", "completed", "success", "succeeded":
            return .completed
        case "error", "failed", "failure":
            return .error
        default:
            return nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func flatten(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let string = value.stringValue { return string }
        if let values = value.arrayValue {
            return values.compactMap { part in
                part["text"]?.stringValue ?? part.stringValue
            }.joined(separator: "\n")
        }
        return ""
    }

    public func withText(_ value: String) -> WireMessageRecord {
        var copy = self
        copy.text = value
        return copy
    }
}

/// Orders authoritative wire records by their durable numeric event ID.
///
/// A nonnumeric ID has no comparable durable position. Its source order stays
/// unchanged so provisional and third-party records retain their exact wire
/// semantics. Equal numeric IDs also remain stable.
internal enum TranscriptWireOrder {
    /// Returns `nil` unless every ID has a durable numeric event position.
    static func normalized(_ messageIDs: [String]) -> [String]? {
        guard !messageIDs.isEmpty else { return messageIDs }

        var runStarts = [messageIDs.startIndex]
        guard let first = Int64(messageIDs[0]) else { return nil }
        var previous = first

        for index in messageIDs.indices.dropFirst() {
            guard let current = Int64(messageIDs[index]) else { return nil }
            if current < previous { runStarts.append(index) }
            previous = current
        }
        guard runStarts.count > 1 else { return messageIDs }
        if runStarts.count == 2 {
            return stableMerge(
                messageIDs[..<runStarts[1]],
                messageIDs[runStarts[1]...]
            )
        }

        runStarts.append(messageIDs.endIndex)
        var runs: [[String]] = []
        runs.reserveCapacity(runStarts.count - 1)
        for index in 0..<(runStarts.count - 1) {
            runs.append(Array(messageIDs[runStarts[index]..<runStarts[index + 1]]))
        }
        while runs.count > 1 {
            var merged: [[String]] = []
            merged.reserveCapacity((runs.count + 1) / 2)
            var index = 0
            while index + 1 < runs.count {
                merged.append(stableMerge(runs[index], runs[index + 1]))
                index += 2
            }
            if index < runs.count { merged.append(runs[index]) }
            runs = merged
        }
        return runs[0]
    }

    /// Returns `nil` unless both independently ordered sources have numeric
    /// durable positions. Equal positions prefer `existing`.
    static func merged(existing: [String], incoming: [String]) -> [String]? {
        guard let existing = normalized(existing),
              let incoming = normalized(incoming)
        else { return nil }
        return stableMerge(existing, incoming)
    }

    private static func stableMerge(_ left: [String], _ right: [String]) -> [String] {
        stableMerge(left[...], right[...])
    }

    private static func stableMerge(
        _ left: ArraySlice<String>,
        _ right: ArraySlice<String>
    ) -> [String] {
        var merged: [String] = []
        merged.reserveCapacity(left.count + right.count)
        var leftIndex = left.startIndex
        var rightIndex = right.startIndex
        while leftIndex < left.endIndex && rightIndex < right.endIndex {
            if Int64(left[leftIndex])! <= Int64(right[rightIndex])! {
                merged.append(left[leftIndex])
                left.formIndex(after: &leftIndex)
            } else {
                merged.append(right[rightIndex])
                right.formIndex(after: &rightIndex)
            }
        }
        merged.append(contentsOf: left[leftIndex...])
        merged.append(contentsOf: right[rightIndex...])
        return merged
    }
}

/// The byte range in a message that a row descriptor exposes.
public struct StringSlice: Codable, Hashable, Sendable {
    public let offset: Int
    public let length: Int

    public init(offset: Int = 0, length: Int) {
        precondition(offset >= 0 && length >= 0)
        self.offset = offset
        self.length = length
    }

    public var utf8Offset: Int { offset }
    public var utf8Length: Int { length }
    public var end: Int { offset + length }
}

/// A stable row identity. A large message has one descriptor for each block.
public struct TranscriptRowDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let messageID: String
    public let blockIndex: Int
    public let ordinal: Int
    public let slice: StringSlice
    public let byteCount: Int
    public let isContinuation: Bool

    public var id: String { "\(messageID):\(blockIndex)" }
    public var stableID: String { id }

    public init(
        messageID: String,
        blockIndex: Int,
        ordinal: Int,
        slice: StringSlice,
        byteCount: Int,
        isContinuation: Bool = false
    ) {
        self.messageID = messageID
        self.blockIndex = blockIndex
        self.ordinal = ordinal
        self.slice = slice
        self.byteCount = byteCount
        self.isContinuation = isContinuation
    }
}

/// One row returned by a bounded page read.
public struct TranscriptRow: Codable, Hashable, Sendable, Identifiable {
    public let descriptor: TranscriptRowDescriptor
    public let message: WireMessageRecord
    public let text: String

    public var id: String { descriptor.id }

    public init(descriptor: TranscriptRowDescriptor, message: WireMessageRecord, text: String) {
        self.descriptor = descriptor
        self.message = message
        self.text = text
    }
}
