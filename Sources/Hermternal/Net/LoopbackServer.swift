import Foundation
import Network
import os

/// One-shot loopback HTTP listener that catches the gateway's
/// `?code=&state=` redirect.
///
/// RFC 8252 §7.3 requires a loopback redirect for native apps, and the
/// gateway enforces it (`_validate_loopback_redirect_uri` accepts only
/// `127.0.0.1` / `::1`). The listener serves exactly one request, hands the
/// query back, and shuts down.
actor LoopbackServer {
    struct Callback: Sendable {
        let code: String
        let state: String
    }

    private var listener: NWListener?

    /// Bind an ephemeral port and return it, so the caller can build the
    /// `redirect_uri` the gateway will 302 to.
    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.start(queue: .global(qos: .userInitiated))

        // NWListener resolves its port asynchronously; spin briefly rather
        // than exposing an optional port to callers.
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            usleep(10_000)
        }
        throw AuthError.loopbackUnavailable
    }

    /// Await the single inbound redirect. Times out so a user who abandons
    /// the browser flow doesn't leak a listener forever.
    func waitForCallback(timeout: Duration = .seconds(300)) async throws -> Callback {
        guard let listener else { throw AuthError.loopbackUnavailable }

        return try await withThrowingTaskGroup(of: Callback.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let resumed = OSAllocatedUnfairLock(initialState: false)
                    // NWListener can deliver more than one connection (the
                    // browser may probe); resume the continuation exactly once.
                    func finish(_ result: Result<Callback, Error>) {
                        let alreadyResumed = resumed.withLock { done -> Bool in
                            if done { return true }
                            done = true
                            return false
                        }
                        guard !alreadyResumed else { return }
                        continuation.resume(with: result)
                    }

                    listener.newConnectionHandler = { connection in
                        connection.start(queue: .global(qos: .userInitiated))
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
                            defer { connection.cancel() }
                            guard let data, let request = String(data: data, encoding: .utf8) else {
                                return
                            }
                            let result = Self.parse(requestLine: request)
                            Self.respond(on: connection, success: (try? result.get()) != nil)
                            finish(result)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AuthError.loginTimedOut
            }
            let callback = try await group.next()!
            group.cancelAll()
            return callback
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Extract `code` / `state` from the HTTP request line.
    private static func parse(requestLine raw: String) -> Result<Callback, Error> {
        guard let line = raw.split(separator: "\r\n").first,
              let target = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(target)")
        else {
            return .failure(AuthError.malformedCallback)
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        // The gateway forwards the IDP's error verbatim when upstream login
        // fails, so surface it instead of a generic parse failure.
        if let error = value("error") {
            return .failure(AuthError.providerRejected(error))
        }
        guard let code = value("code"), let state = value("state") else {
            return .failure(AuthError.malformedCallback)
        }
        return .success(Callback(code: code, state: state))
    }

    private static func respond(on connection: NWConnection, success: Bool) {
        let title = success ? "Signed in" : "Sign-in failed"
        let detail = success
            ? "You can close this tab and return to Hermternal."
            : "Hermternal could not complete the sign-in. Try again."
        let html = """
        <!doctype html><meta charset="utf-8">
        <title>\(title)</title>
        <body style="font:15px -apple-system,system-ui,sans-serif;\
        display:grid;place-items:center;height:100vh;margin:0;\
        background:#1c1c1e;color:#f5f5f7">
        <div style="text-align:center"><h1 style="font-weight:600">\(title)</h1>
        <p style="opacity:.7">\(detail)</p></div>
        """
        let body = Data(html.utf8)
        let head = """
        HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        connection.send(
            content: Data(head.utf8) + body,
            completion: .contentProcessed { _ in }
        )
    }
}
