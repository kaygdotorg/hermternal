import Foundation

/// A gateway-pushed event: `{"method":"event","params":{"type":…,"payload":…}}`.
public struct GatewayEvent: Sendable {
    public let type: String
    public let sessionID: String?
    public let payload: JSONValue?
    public init(type: String, sessionID: String?, payload: JSONValue?) {
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
    }

    public var text: String? { payload?["text"]?.stringValue }
    /// Reserved for a future gateway payload carrying the durable row id.
    /// Current live events are unverified and therefore remain provisional.
    public var serverMessageID: ServerMessageID? {
        guard let raw = (payload?["id"] ?? payload?["row_id"])?.int64Value else { return nil }
        return ServerMessageID(rawValue: raw)
    }
}

public enum GatewayError: LocalizedError {
    case notConnected
    case rpc(code: Int, message: String)
    case connectionClosed(String)
    case malformedFrame(String)
    case unroutableFrame(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the Hermes gateway."
        case .rpc(let code, let message): "Gateway error \(code): \(message)"
        case .connectionClosed(let reason): "Gateway connection closed: \(reason)"
        case .malformedFrame(let detail): "Malformed gateway frame: \(detail)"
        case .unroutableFrame(let detail): "Unroutable gateway frame: \(detail)"
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
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var receiveLoop: Task<Void, Never>?

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
        failAllPending(with: GatewayError.connectionClosed("disconnected"))
    }

    // MARK: - Calls

    /// Issue a JSON-RPC call and await its result.
    public func call(_ method: String, params: [String: Any] = [:]) async throws -> JSONValue {
        guard let task else { throw GatewayError.notConnected }

        let id = nextID
        nextID += 1

        var frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { frame["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: frame)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            // The wire is newline-delimited, so terminate every frame even
            // though WebSocket already provides framing.
            let payload = String(decoding: data, as: UTF8.self) + "\n"
            task.send(.string(payload)) { error in
                guard let error else { return }
                Task { await self.fail(id: id, with: error) }
            }
        }
    }

    private func fail(id: Int, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// Resume every suspended caller so a dead socket can't strand them.
    private func failAllPending(with error: Error) {
        let stranded = pending
        pending.removeAll()
        for continuation in stranded.values {
            continuation.resume(throwing: error)
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
                let frame = try JSONDecoder().decode(Frame.self, from: data)
                route(frame)
            } catch {
                let detail = String(decoding: data.prefix(512), as: UTF8.self)
                let decodeError = GatewayError.malformedFrame(
                    "\(error.localizedDescription): \(detail)"
                )
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

    /// Validates complete WebSocket frames without hiding malformed input.
    /// Production receive handling emits a transport event with the same
    /// detail so the app can surface it through its toast path.
    public static func validateWebSocketFrames(from text: String) throws -> [Data] {
        let frames = webSocketFrames(from: text)
        for data in frames {
            let frame: Frame
            do {
                frame = try JSONDecoder().decode(Frame.self, from: data)
            } catch {
                let detail = String(decoding: data.prefix(512), as: UTF8.self)
                throw GatewayError.malformedFrame("\(error.localizedDescription): \(detail)")
            }
            try validateRoutingShape(of: frame)
        }
        return frames
    }

    private static func validateRoutingShape(of frame: Frame) throws {
        if let id = frame.id, id.intValue == nil {
            throw GatewayError.unroutableFrame(
                "response id has type \(String(describing: id)); "
                + "decoded shape: \(shape(of: frame))"
            )
        }
        if frame.id == nil, frame.result != nil || frame.error != nil {
            throw GatewayError.unroutableFrame(
                "response has no id; decoded shape: \(shape(of: frame))"
            )
        }
    }

    private static func shape(of frame: Frame) -> String {
        "id=\(String(describing: frame.id)), method=\(frame.method ?? "nil"), "
            + "hasResult=\(frame.result != nil), hasParams=\(frame.params != nil), "
            + "hasError=\(frame.error != nil)"
    }

    private func route(_ frame: Frame) {
        if let rawID = frame.id {
            guard let id = rawID.intValue else {
                rejectUnroutable(frame, reason: "response id is not an integer")
                return
            }
            guard let continuation = pending.removeValue(forKey: id) else {
                rejectUnroutable(frame, reason: "no pending call matches response id \(id)")
                return
            }
            if let error = frame.error {
                continuation.resume(
                    throwing: GatewayError.rpc(code: error.code, message: error.message)
                )
            } else {
                continuation.resume(returning: frame.result ?? .null)
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
