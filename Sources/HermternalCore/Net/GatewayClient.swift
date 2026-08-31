import Foundation

/// Event types emitted by the Hermes gateway.
///
/// The gateway can add event types without a client release. Those values stay
/// visible through `unknown` instead of being discarded during classification.
public enum GatewayEventType: Sendable, Equatable {
    case gatewayReady
    case skinChanged
    case sessionInfo
    case sessionUsage
    case thinkingDelta
    case reaction
    case messageStart
    case messageDelta
    case messageInterim
    case messageComplete
    case messageError
    case status
    case statusUpdate
    case notificationShow
    case notificationClear
    case billingStepUpVerification
    case voiceStatus
    case voiceTranscript
    case wakeDetected
    case dashboardNewSessionRequested
    case gatewayStderr
    case browserProgress
    case gatewayStartTimeout
    case gatewayProtocolError
    case reasoningDelta
    case reasoningAvailable
    case moaReference
    case moaAggregating
    case moaProgress
    case moaPhase
    case toolProgress
    case toolGenerating
    case toolStart
    case toolComplete
    case clarifyRequest
    case approvalRequest
    case sudoRequest
    case secretRequest
    case secretExpire
    case sudoExpire
    case backgroundComplete
    case reviewSummary
    case subagentSpawnRequested
    case subagentStart
    case subagentThinking
    case subagentTool
    case subagentProgress
    case subagentComplete
    case error
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "gateway.ready": self = .gatewayReady
        case "skin.changed": self = .skinChanged
        case "session.info": self = .sessionInfo
        case "session.usage": self = .sessionUsage
        case "thinking.delta": self = .thinkingDelta
        case "reaction": self = .reaction
        case "message.start": self = .messageStart
        case "message.delta": self = .messageDelta
        case "message.interim": self = .messageInterim
        case "message.complete": self = .messageComplete
        case "status": self = .status
        case "status.update": self = .statusUpdate
        case "message.error": self = .messageError
        case "notification.show": self = .notificationShow
        case "notification.clear": self = .notificationClear
        case "billing.step_up.verification": self = .billingStepUpVerification
        case "voice.status": self = .voiceStatus
        case "voice.transcript": self = .voiceTranscript
        case "wake.detected": self = .wakeDetected
        case "dashboard.new_session_requested": self = .dashboardNewSessionRequested
        case "gateway.stderr": self = .gatewayStderr
        case "browser.progress": self = .browserProgress
        case "gateway.start_timeout": self = .gatewayStartTimeout
        case "gateway.protocol_error": self = .gatewayProtocolError
        case "reasoning.delta": self = .reasoningDelta
        case "reasoning.available": self = .reasoningAvailable
        case "moa.reference": self = .moaReference
        case "moa.aggregating": self = .moaAggregating
        case "moa.progress": self = .moaProgress
        case "moa.phase": self = .moaPhase
        case "tool.progress": self = .toolProgress
        case "tool.generating": self = .toolGenerating
        case "tool.start": self = .toolStart
        case "tool.complete": self = .toolComplete
        case "clarify.request": self = .clarifyRequest
        case "approval.request": self = .approvalRequest
        case "sudo.request": self = .sudoRequest
        case "secret.request": self = .secretRequest
        case "secret.expire": self = .secretExpire
        case "sudo.expire": self = .sudoExpire
        case "background.complete": self = .backgroundComplete
        case "review.summary": self = .reviewSummary
        case "subagent.spawn_requested": self = .subagentSpawnRequested
        case "subagent.start": self = .subagentStart
        case "subagent.thinking": self = .subagentThinking
        case "subagent.tool": self = .subagentTool
        case "subagent.progress": self = .subagentProgress
        case "subagent.complete": self = .subagentComplete
        case "error": self = .error
        default: self = .unknown(rawValue)
        }
    }
}

/// A gateway-pushed event: `{"method":"event","params":{"type":…,"payload":…}}`.
public struct GatewayEvent: Sendable {
    public let type: String
    public var kind: GatewayEventType { GatewayEventType(rawValue: type) }
    public let sessionID: String?
    public let payload: JSONValue?
    public init(type: String, sessionID: String?, payload: JSONValue?) {
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
    }

    /// Text-bearing events retain their established `text` field. Deferred
    /// failures may instead carry a top-level message or a narrow error shape.
    /// Structured error values are intentionally never rendered.
    public var text: String? {
        payload?["text"]?.stringValue
            ?? payload?["message"]?.stringValue
            ?? payload?["error"]?.stringValue
            ?? payload?["error"]?["message"]?.stringValue
    }
    /// Reserved for a future gateway payload carrying the durable row id.
    /// Current live events are unverified and therefore remain provisional.
    public var serverMessageID: ServerMessageID? {
        guard let raw = (payload?["id"] ?? payload?["row_id"])?.int64Value else { return nil }
        return ServerMessageID(rawValue: raw)
    }
}

public enum GatewayError: LocalizedError, Equatable {
    case notConnected
    case rpc(code: Int, message: String)
    case connectionClosed(String)
    case malformedFrame(String)
    case unroutableFrame(String)
    /// The caller cancelled before this request was put on the wire.
    case cancelledBeforeSend
    /// The caller cancelled after the request was handed to URLSession. The
    /// gateway may still have applied it, so callers must not retry blindly.
    case outcomeUnknownAfterSend

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the Hermes gateway."
        case .rpc(code: let code, message: let message): "Gateway error \(code): \(message)"
        case .connectionClosed(let reason): "Gateway connection closed: \(reason)"
        case .malformedFrame(let detail): "Malformed gateway frame: \(detail)"
        case .unroutableFrame(let detail): "Unroutable gateway frame: \(detail)"
        case .cancelledBeforeSend: "Gateway request cancelled before it was sent."
        case .outcomeUnknownAfterSend:
            "Gateway request cancelled after sending; its outcome is unknown."
        }
    }
}

/// Newline-delimited JSON-RPC 2.0 client for the Hermes TUI gateway at
/// `/api/ws`.
///
/// The socket is the only transport the dashboard exposes remotely — the
/// OpenAI-compatible API server binds loopback only — so this carries both
/// request/response calls and the streaming event feed.
public actor GatewayClient {
    public nonisolated let events: AsyncStream<GatewayEvent>
    private nonisolated let eventContinuation: AsyncStream<GatewayEvent>.Continuation

    private var task: URLSessionWebSocketTask?
    private var nextID = 1
    private struct PendingCall {
        let continuation: CheckedContinuation<JSONValue, Error>
        var didSend: Bool
    }
    private var pending: [Int: PendingCall] = [:]
    /// Responses for cancelled calls that were already handed to URLSession
    /// are expected late responses, not malformed/unroutable frames.
    private var ignoredResponseIDs: Set<Int> = []
    private var receiveLoop: Task<Void, Never>?
    private let frameDecoder = JSONDecoder()

    public init() {
        let (stream, continuation) = AsyncStream<GatewayEvent>.makeStream()
        events = stream
        eventContinuation = continuation
    }
    /// Dial `wss://host/api/ws?ticket=…`.
    ///
    /// The ticket is single-use with a 30s TTL, so callers must mint a fresh
    /// one immediately before every connect and reconnect.
    public func connect(server: URL, ticket: String) throws {
        disconnect()

        guard var components = URLComponents(
            url: server.appendingPathComponent("api/ws"),
            resolvingAgainstBaseURL: false
        ) else { throw AuthError.badServerURL }
        components.scheme = (server.scheme == "http") ? "ws" : "wss"
        components.queryItems = [.init(name: "ticket", value: ticket)]
        guard let url = components.url else { throw AuthError.badServerURL }

        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop = Task { await self.receiveMessages(on: task) }
    }

    public func disconnect() {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        ignoredResponseIDs.removeAll()
        failAllPending(with: GatewayError.connectionClosed("disconnected"))
    }

    // MARK: - Calls

    /// Issue a JSON-RPC call and await its result.
    ///
    /// Cancellation is deliberately not treated as a safe retry signal:
    /// once `send` has been invoked, the gateway may have accepted the
    /// operation even if no response arrives.
    public func call(_ method: String, params: [String: Any] = [:]) async throws -> JSONValue {
        guard let task else { throw GatewayError.notConnected }
        guard !Task.isCancelled else { throw GatewayError.cancelledBeforeSend }

        let id = nextID
        nextID += 1

        var frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { frame["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: frame)

        return try await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else { throw GatewayError.cancelledBeforeSend }
            return try await withCheckedThrowingContinuation { continuation in
                // This closure runs on the actor, so insertion and the
                // didSend transition cannot be interleaved by cancel(id:).
                guard !Task.isCancelled else {
                    continuation.resume(throwing: GatewayError.cancelledBeforeSend)
                    return
                }
                pending[id] = PendingCall(continuation: continuation, didSend: false)
                guard !Task.isCancelled else {
                    cancelPending(id: id)
                    return
                }
                pending[id]?.didSend = true
                // The wire is newline-delimited, so terminate every frame
                // even though WebSocket already provides framing.
                let payload = String(decoding: data, as: UTF8.self) + "\n"
                task.send(.string(payload)) { error in
                    guard let error else { return }
                    Task { await self.fail(id: id, with: error) }
                }
            }
        }, onCancel: {
            Task { await self.cancelPending(id: id) }
        })
    }

    private func cancelPending(id: Int) {
        guard let pendingCall = pending.removeValue(forKey: id) else { return }
        if pendingCall.didSend {
            ignoredResponseIDs.insert(id)
            pendingCall.continuation.resume(throwing: GatewayError.outcomeUnknownAfterSend)
        } else {
            pendingCall.continuation.resume(throwing: GatewayError.cancelledBeforeSend)
        }
    }

    private func fail(id: Int, with error: Error) {
        if let pendingCall = pending.removeValue(forKey: id) {
            let failure: Error = pendingCall.didSend
                ? GatewayError.outcomeUnknownAfterSend
                : error
            pendingCall.continuation.resume(throwing: failure)
        } else {
            ignoredResponseIDs.remove(id)
        }
    }

    /// Resume every suspended caller so a dead socket can't strand them.
    private func failAllPending(with error: Error) {
        let stranded = pending
        pending.removeAll()
        for pendingCall in stranded.values {
            let failure: Error = pendingCall.didSend
                ? GatewayError.outcomeUnknownAfterSend
                : error
            pendingCall.continuation.resume(throwing: failure)
        }
    }

    // MARK: - Receive

    private func receiveMessages(on task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                switch try await task.receive() {
                case .string(let text):
                    ingest(text: text)
                case .data(let data):
                    ingest(text: String(decoding: data, as: UTF8.self))
                @unknown default:
                    break
                }
            } catch {
                failAllPending(with: error)
                emit("transport.closed", text: error.localizedDescription)
                return
            }
        }
    }

    /// A WebSocket message is already a complete transport frame. The gateway
    /// may batch newline-delimited frames in one message, but it omits the
    /// trailing newline when sending one frame.
    private func ingest(text: String) {
        for data in Self.webSocketFrames(from: text) {
            do {
                let frame = try frameDecoder.decode(Frame.self, from: data)
                route(frame)
            } catch {
                let decodeError = GatewayError.malformedFrame("invalid JSON frame")
                Log.error("gateway frame decode failed: \(decodeError)")
                failAllPending(with: decodeError)
                emit("transport.malformed", text: decodeError.localizedDescription)
            }
        }
    }

    /// Splits the complete JSON messages carried by one WebSocket message.
    /// Unlike a byte-stream parser, this must flush a single object without a
    /// trailing newline.
    public static func webSocketFrames(from text: String) -> [Data] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { $0.data(using: .utf8) }
    }

    /// Validates complete WebSocket frames without exposing raw input.
    /// Production receive handling emits a transport event without echoing
    /// untrusted frame bytes into logs or user-facing errors.
    public static func validateWebSocketFrames(from text: String) throws -> [Data] {
        let frames = webSocketFrames(from: text)
        let decoder = JSONDecoder()
        for data in frames {
            let frame: Frame
            do {
                frame = try decoder.decode(Frame.self, from: data)
            } catch {
                throw GatewayError.malformedFrame("invalid JSON frame")
            }
            try validateRoutingShape(of: frame)
        }
        return frames
    }

    private static func validateRoutingShape(of frame: Frame) throws {
        if let id = frame.id, id.intValue == nil {
            throw GatewayError.unroutableFrame(
                "response id has unsupported type; decoded shape: \(shape(of: frame))"
            )
        }
        if frame.id == nil, frame.result != nil || frame.error != nil {
            throw GatewayError.unroutableFrame(
                "response has no id; decoded shape: \(shape(of: frame))"
            )
        }
    }

    private static func shape(of frame: Frame) -> String {
        let idType: String
        if let id = frame.id {
            switch id {
            case .integer: idType = "integer"
            case .number: idType = "number"
            case .string: idType = "string"
            case .null: idType = "null"
            case .bool: idType = "boolean"
            case .array: idType = "array"
            case .object: idType = "object"
            }
        } else {
            idType = "missing"
        }
        return "idType=\(idType), methodPresent=\(frame.method != nil), "
            + "hasResult=\(frame.result != nil), hasParams=\(frame.params != nil), "
            + "hasError=\(frame.error != nil)"
    }
    private func route(_ frame: Frame) {
        if let rawID = frame.id {
            guard let id = rawID.intValue else {
                rejectUnroutable(frame, reason: "response id is not an integer")
                return
            }
            guard let pendingCall = pending.removeValue(forKey: id) else {
                // A cancellation after send has no continuation left to
                // resume. Consume exactly its eventual response so it does
                // not turn a known race into a misleading protocol error.
                if ignoredResponseIDs.remove(id) != nil { return }
                rejectUnroutable(frame, reason: "no pending call matches response id \(id)")
                return
            }
            if let error = frame.error {
                pendingCall.continuation.resume(
                    throwing: GatewayError.rpc(code: error.code, message: error.message)
                )
            } else {
                pendingCall.continuation.resume(returning: frame.result ?? .null)
            }
            return
        }
        if frame.result != nil || frame.error != nil {
            rejectUnroutable(frame, reason: "response has no id")
            return
        }
        guard frame.method == "event",
              let params = frame.params,
              let type = params["type"]?.stringValue
        else { return }
        eventContinuation.yield(
            GatewayEvent(
                type: type,
                sessionID: params["session_id"]?.stringValue,
                payload: params["payload"]
            )
        )
    }

    private func rejectUnroutable(_ frame: Frame, reason: String) {
        let detail = "\(reason); decoded shape: \(Self.shape(of: frame))"
        let error = GatewayError.unroutableFrame(detail)
        Log.error("gateway frame could not be routed: \(detail)")
        failAllPending(with: error)
        emit("transport.malformed", text: error.localizedDescription)
    }

    private func emit(_ type: String, text: String) {
        eventContinuation.yield(
            GatewayEvent(
                type: type,
                sessionID: nil,
                payload: .object(["text": .string(text)])
            )
        )
    }
    private struct Frame: Decodable {
        let id: JSONValue?
        let method: String?
        let result: JSONValue?
        let params: JSONValue?
        let error: RPCError?

        struct RPCError: Decodable {
            let code: Int
            let message: String
        }
    }
}
