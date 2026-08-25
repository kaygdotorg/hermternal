import Foundation

public struct AuthoritativeTranscript: Sendable {
    public let rows: [JSONValue]
    public let serverTotal: Int?

    public init(rows: [JSONValue], serverTotal: Int?) {
        self.rows = rows
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
}

/// The seam between opening a chat and its two server transports.
public protocol TranscriptSource: Sendable {
    func fetchAuthoritative(sessionID: String) async throws -> AuthoritativeTranscript
    func resume(sessionID: String) async throws -> ResumedTranscript
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

    public init(
        messages: [ChatMessage],
        isAwaitingReply: Bool,
        terminal: StreamingTerminal? = nil,
        notice: String? = nil,
        unknownEventTypes: [String] = []
    ) {
        self.messages = messages
        self.isAwaitingReply = isAwaitingReply
        self.terminal = terminal
        self.notice = notice
        self.unknownEventTypes = unknownEventTypes
    }
}

/// Production reducer for the event shapes emitted by GatewayClient.
///
/// The reducer consumes events in gateway arrival order. It does not assume
/// that reasoning ends before answer text starts, or that either stream is
/// contiguous.
/// Live rows remain provisional unless the gateway explicitly supplies a
/// durable id in a future event shape.
public struct StreamingEventReducer: Sendable {
    public private(set) var messages: [ChatMessage]
    public private(set) var isAwaitingReply: Bool
    /// Unknown events remain observable for forward compatibility and support
    /// diagnostics instead of disappearing in the default branch.
    public private(set) var unknownEventTypes: [String]

    public init(
        messages: [ChatMessage] = [],
        isAwaitingReply: Bool = false,
        unknownEventTypes: [String] = []
    ) {
        self.messages = messages
        self.isAwaitingReply = isAwaitingReply
        self.unknownEventTypes = unknownEventTypes
    }

    public mutating func reset(
        messages: [ChatMessage] = [],
        isAwaitingReply: Bool = false
    ) {
        self.messages = messages
        self.isAwaitingReply = isAwaitingReply
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
        switch event.kind {
        case .messageStart:
            messages.append(ChatMessage(
                id: identity(for: event),
                role: .assistant,
                text: "",
                isStreaming: true
            ))
            isAwaitingReply = true
            return reduction()

        case .messageDelta:
            guard let delta = event.text, !delta.isEmpty else { return reduction() }
            appendAnswer(delta, identity: identity(for: event))
            return reduction()

        // The wire names differ, but upstream routes provider reasoning,
        // Anthropic thinking blocks, and Codex reasoning deltas to one
        // logical reasoning channel. Arrival order remains authoritative.
        case .thinkingDelta, .reasoningDelta, .reasoningAvailable:
            guard let delta = event.text, !delta.isEmpty else { return reduction() }
            appendReasoning(delta, identity: identity(for: event))
            return reduction()

        case .messageInterim:
            guard let interim = event.text, !interim.isEmpty else { return reduction() }
            if event.payload?["already_streamed"]?.boolValue == true {
                if let index = streamingIndex { messages[index].text = interim }
                else { appendAnswer(interim, identity: identity(for: event)) }
            } else {
                appendAnswer(interim, identity: identity(for: event))
            }
            return reduction()

        case .messageComplete:
            complete(event)
            return reduction(terminal: .complete)

        case .error, .messageError:
            finishStreaming()
            return reduction(terminal: .error, notice: event.text ?? "The agent reported an error.")

        case .unknown(let type):
            unknownEventTypes.append(type)
            return reduction()

        default:
            // Known lifecycle, tool, MoA, subagent, notification, approval,
            // voice, and status events remain classified even when this
            // transcript reducer has no message projection for them yet.
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

    private mutating func appendAnswer(_ delta: String, identity: MessageIdentity) {
        if let index = streamingIndex {
            messages[index].text += delta
        } else {
            messages.append(ChatMessage(
                id: identity,
                role: .assistant,
                text: delta,
                isStreaming: true
            ))
        }
        isAwaitingReply = true
    }

    private mutating func appendReasoning(_ delta: String, identity: MessageIdentity) {
        if let index = streamingIndex {
            messages[index].reasoning = (messages[index].reasoning ?? "") + delta
        } else {
            messages.append(ChatMessage(
                id: identity,
                role: .assistant,
                text: "",
                reasoning: delta,
                isStreaming: true
            ))
        }
        isAwaitingReply = true
    }

    private mutating func complete(_ event: GatewayEvent) {
        if let index = streamingIndex {
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
                reasoning: event.payload?["reasoning"]?.stringValue
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
            unknownEventTypes: unknownEventTypes
        )
    }
}
