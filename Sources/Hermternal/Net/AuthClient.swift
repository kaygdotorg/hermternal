import AppKit
import Foundation

/// Drives the gateway-brokered RFC 8252 native-app login and keeps the
/// bearer credential fresh.
///
/// The gateway is the authorization server to us and an OAuth client to the
/// upstream IDP, so we never talk to Authentik/Portal directly: we open the
/// system browser at `/auth/native/authorize`, catch the loopback redirect,
/// and exchange the one-time code at `/auth/native/token`.
actor AuthClient {
    private let server: URL
    /// Credential store key — the origin, so switching instances doesn't
    /// clobber another instance's tokens.
    private let account: String
    private let urlSession: URLSession

    init(server: URL, urlSession: URLSession = .shared) {
        self.server = server
        self.account = server.absoluteString
        self.urlSession = urlSession
    }

    var storedCredentials: Credentials? { CredentialStore.load(account: account) }

    func signOut() { CredentialStore.delete(account: account) }

    // MARK: - Interactive login

    /// Full native login. Opens the system browser and resolves once the
    /// loopback redirect has been exchanged for bearer tokens.
    func signIn() async throws -> Credentials {
        let pkce = PKCE()
        let state = PKCE.randomState()
        let loopback = LoopbackServer()

        let port = try await loopback.start()
        defer { Task { await loopback.stop() } }

        let redirectURI = "http://127.0.0.1:\(port)/callback"
        guard var components = URLComponents(
            url: server.appendingPathComponent("auth/native/authorize"),
            resolvingAgainstBaseURL: false
        ) else { throw AuthError.badServerURL }
        components.queryItems = [
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "state", value: state),
        ]
        guard let authorizeURL = components.url else { throw AuthError.badServerURL }

        NSWorkspace.shared.open(authorizeURL)

        let callback = try await loopback.waitForCallback()
        // The gateway echoes our own `state` verbatim; a mismatch means the
        // redirect did not originate from the flow we started.
        guard callback.state == state else { throw AuthError.stateMismatch }

        let credentials = try await exchange(code: callback.code, verifier: pkce.verifier)
        try CredentialStore.save(credentials, account: account)
        return credentials
    }

    private func exchange(code: String, verifier: String) async throws -> Credentials {
        struct Body: Encodable {
            let code: String
            let code_verifier: String
        }
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_at: Int
            let provider: String?
            let user_id: String?
        }

        let (data, response) = try await post(
            path: "auth/native/token",
            body: Body(code: code, code_verifier: verifier)
        )
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.tokenExchangeFailed(
                status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                body: String(decoding: data, as: UTF8.self)
            )
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return Credentials(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? "",
            expiresAt: decoded.expires_at,
            provider: decoded.provider ?? "",
            userID: decoded.user_id ?? ""
        )
    }

    // MARK: - Refresh

    /// Return a live access token, rotating it first when it is at or past
    /// expiry. Throws `.sessionExpired` when the refresh token is dead, so
    /// the UI can fall back to a fresh interactive login.
    func validCredentials() async throws -> Credentials {
        guard let stored = storedCredentials else { throw AuthError.notSignedIn }
        guard stored.isExpired() else { return stored }
        guard !stored.refreshToken.isEmpty else { throw AuthError.sessionExpired }

        struct Body: Encodable {
            let refresh_token: String
            let provider: String
        }
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_at: Int
            let provider: String?
            let user_id: String?
        }

        let (data, response) = try await post(
            path: "auth/native/refresh",
            body: Body(refresh_token: stored.refreshToken, provider: stored.provider)
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 {
            CredentialStore.delete(account: account)
            throw AuthError.sessionExpired
        }
        guard status == 200 else {
            throw AuthError.tokenExchangeFailed(
                status: status,
                body: String(decoding: data, as: UTF8.self)
            )
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let rotated = Credentials(
            accessToken: decoded.access_token,
            // The gateway rotates refresh tokens; fall back to the previous
            // one when a provider returns only an access token.
            refreshToken: decoded.refresh_token ?? stored.refreshToken,
            expiresAt: decoded.expires_at,
            provider: decoded.provider ?? stored.provider,
            userID: decoded.user_id ?? stored.userID
        )
        try CredentialStore.save(rotated, account: account)
        return rotated
    }

    // MARK: - WebSocket ticket

    /// Mint a single-use 30s ticket for the `/api/ws` upgrade.
    ///
    /// The WS gate rejects `Authorization` headers outright, so every
    /// connect (and reconnect) needs a fresh ticket.
    func webSocketTicket() async throws -> String {
        struct Response: Decodable { let ticket: String }

        let credentials = try await validCredentials()
        var request = URLRequest(url: server.appendingPathComponent("api/auth/ws-ticket"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw AuthError.ticketFailed(
                status: status,
                body: String(decoding: data, as: UTF8.self)
            )
        }
        return try JSONDecoder().decode(Response.self, from: data).ticket
    }

    // MARK: - Plumbing

    private func post<B: Encodable>(path: String, body: B) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await urlSession.data(for: request)
    }
}
