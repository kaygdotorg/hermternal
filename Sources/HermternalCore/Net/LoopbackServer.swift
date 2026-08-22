import Darwin
import Foundation

/// One-shot loopback HTTP listener that catches the gateway's
/// `?code=&state=` redirect.
///
/// RFC 8252 §7.3 restricts native-app redirects to the loopback interface,
/// and the gateway enforces it (`_validate_loopback_redirect_uri` accepts
/// only `127.0.0.1` / `::1`).
///
/// This uses a plain POSIX socket rather than `NWListener`: every
/// `NWListener` binding variant fails with `EINVAL` on macOS 26.6, and a
/// raw socket also binds `127.0.0.1` explicitly and reports its port
/// immediately instead of only after an async `.ready` transition.
actor LoopbackServer {
    struct Callback: Sendable {
        let code: String
        let state: String
    }

    private var descriptor: Int32?

    /// Bind an ephemeral loopback port and return it, so the caller can
    /// build the `redirect_uri` the gateway will 302 to.
    func start() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AuthError.loopbackUnavailable }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        // Port 0 asks the kernel for a free port, read back below.
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw AuthError.loopbackUnavailable
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didResolve = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &length)
            }
        }
        guard didResolve == 0 else {
            close(fd)
            throw AuthError.loopbackUnavailable
        }

        descriptor = fd
        return UInt16(bigEndian: bound.sin_port)
    }

    /// Await the single inbound redirect. Times out so a user who abandons
    /// the browser flow doesn't leak a listener forever.
    func waitForCallback(timeout: Duration = .seconds(300)) async throws -> Callback {
        guard let fd = descriptor else { throw AuthError.loopbackUnavailable }

        return try await withThrowingTaskGroup(of: Callback.self) { group in
            group.addTask {
                // `accept` blocks, so keep it off the cooperative pool.
                try await Self.acceptOne(on: fd)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AuthError.loginTimedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func stop() {
        if let fd = descriptor { close(fd) }
        descriptor = nil
    }

    /// Accept exactly one connection, answer it, and return its query.
    private static func acceptOne(on fd: Int32) async throws -> Callback {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let client = accept(fd, nil, nil)
                guard client >= 0 else {
                    // `stop()` closing the descriptor unblocks accept; treat
                    // that as an abandoned flow rather than a hard error.
                    continuation.resume(throwing: AuthError.loopbackUnavailable)
                    return
                }
                defer { close(client) }

                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                let received = read(client, &buffer, buffer.count)
                guard received > 0,
                      let request = String(bytes: buffer[0..<received], encoding: .utf8)
                else {
                    respond(on: client, success: false)
                    continuation.resume(throwing: AuthError.malformedCallback)
                    return
                }

                let result = parse(requestLine: request)
                respond(on: client, success: (try? result.get()) != nil)
                continuation.resume(with: result)
            }
        }
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

    private static func respond(on client: Int32, success: Bool) {
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
        let response = """
        HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var payload = Data(response.utf8)
        payload.append(body)
        payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let wrote = write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard wrote > 0 else { break }
                sent += wrote
            }
        }
    }
}
