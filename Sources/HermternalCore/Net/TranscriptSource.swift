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

    public func prefetch<Item: Sendable, Result: Sendable>(
        _ items: [Item],
        operation: @escaping @Sendable (Item) async throws -> Result?
    ) async -> [Result] {
        guard !items.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, Result?).self, returning: [Result].self) { group in
            var next = 0
            var results: [(Int, Result)] = []

            func add(_ index: Int) {
                guard !Task.isCancelled else { return }
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    return (index, try? await operation(items[index]))
                }
            }

            while next < items.count && next < limit && !Task.isCancelled {
                add(next)
                next += 1
            }
            while let (index, result) = await group.next() {
                if let result { results.append((index, result)) }
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                guard next < items.count else { continue }
                add(next)
                next += 1
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
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

    public init(
        messages: [ChatMessage],
        isAwaitingReply: Bool,
        terminal: StreamingTerminal? = nil,
        notice: String? = nil
    ) {
        self.messages = messages
        self.isAwaitingReply = isAwaitingReply
        self.terminal = terminal
        self.notice = notice
    }
}

/// Production reducer for the event shapes emitted by GatewayClient.
/// Live rows remain provisional unless the gateway explicitly supplies a
/// durable id in a future event shape.
public struct StreamingEventReducer: Sendable {
    public private(set) var messages: [ChatMessage]
    public private(set) var isAwaitingReply: Bool

    public init(messages: [ChatMessage] = [], isAwaitingReply: Bool = false) {
        self.messages = messages
        self.isAwaitingReply = isAwaitingReply
    }

    public mutating func reset(messages: [ChatMessage] = [], isAwaitingReply: Bool = false) {
        self.messages = messages
        self.isAwaitingReply = isAwaitingReply
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
        switch event.type {
        case "message.start":
            messages.append(ChatMessage(
                id: identity(for: event),
                role: .assistant,
                text: "",
                isStreaming: true
            ))
            isAwaitingReply = true
            return reduction()

        case "message.delta":
            guard let delta = event.text, !delta.isEmpty else { return reduction() }
            if let index = streamingIndex {
                messages[index].text += delta
            } else {
                messages.append(ChatMessage(
                    id: identity(for: event),
                    role: .assistant,
                    text: delta,
                    isStreaming: true
                ))
            }
            isAwaitingReply = true
            return reduction()

        case "message.complete":
            if let index = streamingIndex {
                if let full = event.text, !full.isEmpty { messages[index].text = full }
                messages[index].isStreaming = false
            } else if let full = event.text, !full.isEmpty, isAwaitingReply {
                messages.append(ChatMessage(
                    id: identity(for: event),
                    role: .assistant,
                    text: full
                ))
            }
            finishStreaming()
            return reduction(terminal: .complete)

        case "error":
            finishStreaming()
            return reduction(terminal: .error, notice: event.text ?? "The agent reported an error.")

        default:
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
            notice: notice
        )
    }
}
