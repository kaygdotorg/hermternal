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

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the Hermes gateway."
        case .rpc(let code, let message): "Gateway error \(code): \(message)"
        case .connectionClosed(let reason): "Gateway connection closed: \(reason)"
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
    private var ndjsonParser = NDJSONFrameParser()

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

    /// A single WebSocket message may carry several newline-delimited frames.
    private func ingest(text: String) {
        for data in ndjsonParser.append(text) {
            guard let frame = try? JSONDecoder().decode(Frame.self, from: data) else {
                emit("transport.malformed", text: String(decoding: data.prefix(512), as: UTF8.self))
                continue
            }
            route(frame)
        }
    }

    private func route(_ frame: Frame) {
        if let id = frame.id, let continuation = pending.removeValue(forKey: id) {
            if let error = frame.error {
                continuation.resume(
                    throwing: GatewayError.rpc(code: error.code, message: error.message)
                )
            } else {
                continuation.resume(returning: frame.result ?? .null)
            }
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
        let id: Int?
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
