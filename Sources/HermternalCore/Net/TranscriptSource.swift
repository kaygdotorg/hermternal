import Foundation

private final class TranscriptTotalCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var valueStorage: Int?

    func set(_ value: Int?) {
        guard let value else { return }
        lock.lock()
        valueStorage = value
        lock.unlock()
    }

    var value: Int? {
        lock.lock()
        defer { lock.unlock() }
        return valueStorage
    }
}

public struct AuthoritativeTranscript: Sendable {
    /// Compatibility projection. Incremental callers should use
    /// `streamAuthoritative` so this corpus is never accumulated.
    public let rows: [JSONValue]
    public let serverTotal: Int?

    public init(rows: [JSONValue], serverTotal: Int?) {
        self.rows = rows
        self.serverTotal = serverTotal
    }
    public func turnDocuments(sessionModel: String? = nil) -> [TranscriptTurn] {
        TranscriptTurnProjector.project(
            records: rows.compactMap(WireMessageRecord.init(row:)),
            sessionModel: sessionModel
        )
    }
}

/// Incremental authoritative history metadata. Records are delivered in
/// database order through the source callback.
public struct AuthoritativeTranscriptMetadata: Sendable, Equatable {
    public let messageCount: Int
    public let serverTotal: Int?

    public init(messageCount: Int, serverTotal: Int?) {
        self.messageCount = messageCount
        self.serverTotal = serverTotal
    }
}

public struct ResumedTranscript: Sendable {
    public let liveSessionID: String?
    /// Resume rows are a live projection only. They are intentionally never
    /// projected into the durable cache.
    public let rows: [JSONValue]
    /// Server-side count, when supplied by the resume response.
    public let messageCount: Int?

    public init(
        liveSessionID: String?,
        rows: [JSONValue],
        messageCount: Int? = nil
    ) {
        self.liveSessionID = liveSessionID
        self.rows = rows
        self.messageCount = messageCount
    }
    public func turnDocuments(sessionModel: String? = nil) -> [TranscriptTurn] {
        TranscriptTurnProjector.project(
            records: rows.compactMap(WireMessageRecord.init(row:)),
            sessionModel: sessionModel
        )
    }
}

/// The seam between opening a chat and its two server transports.
public protocol TranscriptSource: Sendable {
    func fetchAuthoritative(sessionID: String) async throws -> AuthoritativeTranscript
    func resume(sessionID: String) async throws -> ResumedTranscript
    func streamAuthoritative(
        sessionID: String,
        onPage: @escaping TranscriptMessagePageConsumer
    ) async throws -> AuthoritativeTranscriptMetadata
}

public extension TranscriptSource {
    /// Compatibility default for test and third-party sources. Gateway
    /// production sources override this with REST page delivery.
    func streamAuthoritative(
        sessionID: String,
        onPage: @escaping TranscriptMessagePageConsumer
    ) async throws -> AuthoritativeTranscriptMetadata {
        let result = try await fetchAuthoritative(sessionID: sessionID)
        try await onPage(TranscriptMessagePage(
            messages: result.rows,
            returned: result.rows.count,
            offset: 0,
            serverTotal: result.serverTotal,
            byteCount: 0
        ))
        return AuthoritativeTranscriptMetadata(
            messageCount: result.rows.count,
            serverTotal: result.serverTotal
        )
    }
}

public struct GatewayTranscriptSource: TranscriptSource, Sendable {
    public let gateway: GatewayClient
    public let rest: RestClient
    public let serverTotals: [String: Int]

    public init(gateway: GatewayClient, rest: RestClient, serverTotals: [String: Int] = [:]) {
        self.gateway = gateway
        self.rest = rest
        self.serverTotals = serverTotals
    }

    public func fetchAuthoritative(sessionID: String) async throws -> AuthoritativeTranscript {
        let rows = try await rest.sessionMessages(durableID: sessionID)
        return AuthoritativeTranscript(rows: rows, serverTotal: serverTotals[sessionID])
    }
    public func streamAuthoritative(
        sessionID: String,
        onPage: @escaping TranscriptMessagePageConsumer
    ) async throws -> AuthoritativeTranscriptMetadata {
        let totalCapture = TranscriptTotalCapture()
        let summary = try await rest.streamSessionMessages(
            durableID: sessionID,
            onPage: { page in
                totalCapture.set(page.serverTotal)
                try await onPage(page)
            }
        )
        return AuthoritativeTranscriptMetadata(
            messageCount: summary.messageCount,
            serverTotal: totalCapture.value ?? serverTotals[sessionID]
        )
    }

    public func resume(sessionID: String) async throws -> ResumedTranscript {
        let result = try await gateway.call("session.resume", params: ["session_id": sessionID])
        return ResumedTranscript(
            liveSessionID: result["session_id"]?.stringValue,
            rows: result["messages"]?.arrayValue ?? [],
            messageCount: result["message_count"]?.intValue
        )
    }
}

/// Runs independent transcript loads with a fixed number of concurrent lanes.
public struct BoundedPrefetchCoordinator: Sendable {
    public let limit: Int

    public init(limit: Int = 4) {
        self.limit = max(1, limit)
    }

    /// Delivers each successful load as soon as its lane completes.
    ///
    /// The callback is awaited before another lane is started, so the
    /// coordinator never accumulates completed payloads between deliveries.
    /// This keeps peak transcript residency bounded by `limit` rather than by
    /// the number of requested items.
    public func prefetch<Item: Sendable, Result: Sendable>(
        _ items: [Item],
        operation: @escaping @Sendable (Item) async throws -> Result?,
        onResult: @escaping @Sendable (Result) async -> Void
    ) async {
        guard !items.isEmpty else { return }
        await withTaskGroup(of: Result?.self) { group in
            var next = 0

            func add(_ index: Int) {
                guard !Task.isCancelled else { return }
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return try? await operation(items[index])
                }
            }

            while next < items.count && next < limit && !Task.isCancelled {
                add(next)
                next += 1
            }
            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if let result {
                    await onResult(result)
                }
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                guard next < items.count else { continue }
                add(next)
                next += 1
            }
        }
    }
}

/// Incremental parser for newline-delimited JSON frames.
public struct NDJSONFrameParser: Sendable {
    private var buffer = ""

    public init() {}

    public mutating func append(_ text: String) -> [Data] {
        buffer += text
        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = line.data(using: .utf8)
            else { continue }
            frames.append(data)
        }
        return frames
    }

    public mutating func finish() -> [Data] {
        defer { buffer.removeAll(keepingCapacity: true) }
        let line = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let data = line.data(using: .utf8) else { return [] }
        return [data]
    }
}

/// Deterministic text accumulation for streaming message events.
public struct StreamingTextAccumulator: Sendable {
    public private(set) var text = ""
    public private(set) var isStreaming = false

    public init() {}

    public mutating func start() {
        text = ""
        isStreaming = true
    }

    public mutating func append(_ delta: String) {
        if !isStreaming { isStreaming = true }
        text += delta
    }

    @discardableResult
    public mutating func complete(_ authoritativeText: String? = nil) -> String {
        if let authoritativeText { text = authoritativeText }
        isStreaming = false
        return text
    }
}

public enum StreamingTerminal: Sendable, Equatable {
    case complete
    case interrupt
    case error
}

public struct StreamingReduction: Sendable {
    public let messages: [ChatMessage]
    public let isAwaitingReply: Bool
    public let terminal: StreamingTerminal?
    public let notice: String?
    /// Event type names that this client does not know yet.
    public let unknownEventTypes: [String]
    /// The same reduction projected through the platform-neutral turn seam.
    public let turns: [TranscriptTurn]

    public init(
        messages: [ChatMessage],
        isAwaitingReply: Bool,
        terminal: StreamingTerminal? = nil,
        notice: String? = nil,
        unknownEventTypes: [String] = [],
        turns: [TranscriptTurn] = []
    ) {
        self.messages = messages
        self.isAwaitingReply = isAwaitingReply
        self.terminal = terminal
        self.notice = notice
        self.unknownEventTypes = unknownEventTypes
        self.turns = turns
    }
}

/// Production reducer for the event shapes emitted by GatewayClient.
///
/// The reducer consumes events in gateway arrival order. It does not assume
public struct StreamingEventReducer: Sendable {
    public private(set) var messages: [ChatMessage]
    public private(set) var isAwaitingReply: Bool
    /// Unknown events remain observable for forward compatibility and support
    /// diagnostics instead of disappearing in the default branch.
    public private(set) var unknownEventTypes: [String]
    private var toolRecords: [WireMessageRecord]
    private var modelMarkers: [WireMessageRecord]
    private var reasoningEffort: String?

    public init(
        messages: [ChatMessage] = [],
        isAwaitingReply: Bool = false,
        unknownEventTypes: [String] = []
    ) {
        self.messages = messages
        self.isAwaitingReply = isAwaitingReply
        self.unknownEventTypes = unknownEventTypes
        self.toolRecords = []
        self.modelMarkers = []
        self.reasoningEffort = nil
    }

    public var turns: [TranscriptTurn] {
        let values = modelMarkers + messages.map { Self.wireRecord(from: $0, reasoningEffort: reasoningEffort) } + toolRecords
        return TranscriptTurnProjector.project(records: values)
    }

    public mutating func reset(
        messages: [ChatMessage] = [],
        isAwaitingReply: Bool = false
    ) {
        self.messages = messages
        self.isAwaitingReply = isAwaitingReply
        self.toolRecords.removeAll(keepingCapacity: true)
        self.modelMarkers.removeAll(keepingCapacity: true)
        self.reasoningEffort = nil
        unknownEventTypes.removeAll(keepingCapacity: true)
    }

    public mutating func appendUser(_ text: String) {
        messages.append(ChatMessage(role: .user, text: text))
        isAwaitingReply = true
    }

    public mutating func cancel() -> StreamingReduction {
        finishStreaming()
        return reduction()
    }

    public mutating func interrupt() -> StreamingReduction {
        finishStreaming()
        return reduction(terminal: .interrupt)
    }

    public mutating func reduce(_ event: GatewayEvent) -> StreamingReduction {
        if event.payload?["display_kind"]?.stringValue == "model_switch" {
            modelMarkers.append(WireMessageRecord(
                messageID: markerID(for: event),
                role: "system",
                text: "",
                displayKind: "model_switch",
                displayMetadata: Self.objectFields(event.payload?["display_metadata"])
            ))
            return reduction()
        }
        if event.type.hasPrefix("tool.") && event.kind == .unknown(event.type) {
            toolRecords.append(toolRecord(for: event))
            return reduction()
        }
        switch event.kind {
        case .messageStart:
            messages.append(ChatMessage(
                id: identity(for: event),
                role: .assistant,
                text: "",
                turnID: turnID(for: event),
                isStreaming: true
            ))
            isAwaitingReply = true
            return reduction()

        case .messageDelta:
            guard let delta = event.text, !delta.isEmpty else { return reduction() }
            appendAnswer(delta, identity: identity(for: event), turnID: turnID(for: event))
            return reduction()

        // The wire names differ, but upstream routes provider reasoning,
        // Anthropic thinking blocks, and Codex reasoning deltas to one
        // logical reasoning channel. Arrival order remains authoritative.
        case .thinkingDelta, .reasoningDelta, .reasoningAvailable:
            if let effort = Self.effort(from: event.payload) { reasoningEffort = effort }
            guard let delta = event.text, !delta.isEmpty else { return reduction() }
            appendReasoning(delta, identity: identity(for: event), turnID: turnID(for: event))
            return reduction()

        case .messageInterim:
            guard let interim = event.text, !interim.isEmpty else { return reduction() }
            if event.payload?["already_streamed"]?.boolValue == true {
                if let index = streamingIndex {
                    messages[index].text = interim
                    if messages[index].turnID == nil { messages[index].turnID = turnID(for: event) }
                } else {
                    appendAnswer(interim, identity: identity(for: event), turnID: turnID(for: event))
                }
            } else {
                appendAnswer(interim, identity: identity(for: event), turnID: turnID(for: event))
            }
            return reduction()

        case .messageComplete:
            complete(event)
            return reduction(terminal: .complete)

        case .toolStart, .toolProgress, .toolGenerating, .toolComplete:
            toolRecords.append(toolRecord(for: event))
            return reduction()

        case .error, .messageError:
            finishStreaming()
            return reduction(terminal: .error, notice: event.text ?? "The agent reported an error.")

        case .unknown(let type):
            unknownEventTypes.append(type)
            return reduction()

        default:
            // Known lifecycle, notification, approval, and status events remain
            // observable through the reducer without becoming message rows.
            return reduction()
        }
    }

    private var streamingIndex: Int? {
        messages.lastIndex { $0.isStreaming }
    }

    private func identity(for event: GatewayEvent) -> MessageIdentity {
        if let serverID = event.serverMessageID { return .server(serverID) }
        return .provisional(UUID())
    }

    private mutating func appendAnswer(_ delta: String, identity: MessageIdentity, turnID: String?) {
        if let index = streamingIndex {
            messages[index].text += delta
            if messages[index].turnID == nil { messages[index].turnID = turnID }
        } else {
            messages.append(ChatMessage(
                id: identity,
                role: .assistant,
                text: delta,
                turnID: turnID,
                isStreaming: true
            ))
        }
        isAwaitingReply = true
    }
    private func turnID(for event: GatewayEvent) -> String? {
        event.payload?["turn_id"]?.stringValue
    }

    private func markerID(for event: GatewayEvent) -> String {
        event.serverMessageID.map { String($0.rawValue) }
            ?? event.payload?["marker_id"]?.stringValue
            ?? "model-switch-\(modelMarkers.count)"
    }

    private func toolRecord(for event: GatewayEvent) -> WireMessageRecord {
        let payload = event.payload
        let status: String
        switch event.kind {
        case .toolStart: status = "running"
        case .toolComplete: status = payload?["error"] != nil ? "error" : "completed"
        default: status = "running"
        }
        return WireMessageRecord(
            messageID: payload?["id"]?.stringValue
                ?? payload?["tool_call_id"]?.stringValue
                ?? payload?["call_id"]?.stringValue
                ?? "tool-event-\(toolRecords.count)",
            role: "tool",
            text: event.text ?? "",
            displayKind: "tool_event",
            displayMetadata: Self.objectFields(payload),
            toolCallID: payload?["tool_call_id"]?.stringValue ?? payload?["call_id"]?.stringValue,
            toolName: payload?["tool_name"]?.stringValue ?? payload?["name"]?.stringValue,
            toolInput: payload?["input"]?.stringValue,
            toolOutput: payload?["output"]?.stringValue ?? payload?["result"]?.stringValue,
            toolStatus: status,
            turnID: payload?["turn_id"]?.stringValue
        )
    }

    private static func wireRecord(
        from message: ChatMessage,
        reasoningEffort: String? = nil
    ) -> WireMessageRecord {
        let id: String
        switch message.id {
        case .server(let value): id = String(value.rawValue)
        case .provisional(let value): id = value.uuidString
        }
        let metadata: [String: JSONValue]? = reasoningEffort.map {
            ["reasoning_effort": .string($0)]
        }
        return WireMessageRecord(
            messageID: id,
            role: message.role.rawValue,
            text: message.text,
            reasoning: message.reasoning,
            timestamp: message.timestamp,
            displayMetadata: metadata,
            turnID: message.turnID
        )
    }
    private static func objectFields(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let fields) = value else { return nil }
        return fields
    }
    private static func effort(from value: JSONValue?) -> String? {
        let fields = objectFields(value)
        for key in ["reasoning_effort", "reasoningEffort", "effort"] {
            if let value = fields?[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }


    private mutating func appendReasoning(_ delta: String, identity: MessageIdentity, turnID: String?) {
        if let index = streamingIndex {
            messages[index].reasoning = (messages[index].reasoning ?? "") + delta
            if messages[index].turnID == nil { messages[index].turnID = turnID }
        } else {
            messages.append(ChatMessage(
                id: identity,
                role: .assistant,
                text: "",
                reasoning: delta,
                turnID: turnID,
                isStreaming: true
            ))
        }
        isAwaitingReply = true
    }

    private mutating func complete(_ event: GatewayEvent) {
        if let index = streamingIndex {
            if messages[index].turnID == nil { messages[index].turnID = turnID(for: event) }
            if let full = event.text, !full.isEmpty {
                messages[index].text = full
            }
            // A present final value is authoritative, including an empty
            // string. An absent value preserves streamed reasoning.
            if let finalReasoning = event.payload?["reasoning"]?.stringValue {
                messages[index].reasoning = finalReasoning
            }
            messages[index].isStreaming = false
        } else if let full = event.text, !full.isEmpty, isAwaitingReply {
            messages.append(ChatMessage(
                id: identity(for: event),
                role: .assistant,
                text: full,
                reasoning: event.payload?["reasoning"]?.stringValue,
                turnID: turnID(for: event)
            ))
        }
        finishStreaming()
    }

    private mutating func finishStreaming() {
        if let index = streamingIndex { messages[index].isStreaming = false }
        isAwaitingReply = false
    }

    private func reduction(
        terminal: StreamingTerminal? = nil,
        notice: String? = nil
    ) -> StreamingReduction {
        StreamingReduction(
            messages: messages,
            isAwaitingReply: isAwaitingReply,
            terminal: terminal,
            notice: notice,
            unknownEventTypes: unknownEventTypes,
            turns: turns
        )
    }
}
