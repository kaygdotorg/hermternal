import Foundation


/// Drives the gateway-brokered RFC 8252 native-app login and keeps the
/// bearer credential fresh.
///
/// The gateway is the authorization server to us and an OAuth client to the
/// upstream IDP, so we never talk to Authentik/Portal directly: we open the
/// system browser at `/auth/native/authorize`, catch the loopback redirect,
/// and exchange the one-time code at `/auth/native/token`.
public actor AuthClient {
    private let server: URL
    /// Credential store key — the origin, so switching instances doesn't
    /// clobber another instance's tokens.
    private let account: String
    private let urlSession: URLSession
    private let openURL: @Sendable (URL) -> Void
    private let credentialStore: any CredentialStoring
    private var refreshTask: Task<Credentials, Error>?
    private var refreshGeneration = 0
    private var refreshRejected = false

    public init(
        server: URL,
        urlSession: URLSession = .shared,
        openURL: @escaping @Sendable (URL) -> Void = { _ in },
        credentialStore: (any CredentialStoring)? = nil
    ) {
        self.server = server
        self.account = server.absoluteString
        self.urlSession = urlSession
        self.openURL = openURL
        self.credentialStore = credentialStore ?? FacadeCredentialStore()
    }

    public var storedCredentials: Credentials? {
        try? credentialStore.load(account: account)
    }

    public func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshRejected = false
        try? credentialStore.delete(account: account)
    }
    // MARK: - Provider discovery


    /// Fetch provider capabilities without making discovery a prerequisite
    /// for sign-in. Older/self-hosted gateways may not expose this endpoint.
    public func discoverProviders() async -> [AuthProvider]? {
        var request = URLRequest(url: server.appendingPathComponent("api/auth/providers"))
        request.httpMethod = "GET"

        do {
            let (data, response) = try await urlSession.data(for: request)
            return Self.decodeProviderResponse(
                data: data,
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        } catch {
            return nil
        }
    }

    /// Fetch the authenticated account without making identity a prerequisite
    /// for sign-in. Missing/older endpoints, expired sessions, transport
    /// failures, and malformed responses are all represented as `nil`.
    public func fetchAccountIdentity() async -> AccountIdentity? {
        guard let credentials = try? await validCredentials() else { return nil }
        return await fetchAccountIdentity(using: credentials)
    }

    /// Fetch the authenticated account with an already-issued bearer token.
    /// This overload lets composition fetch identity immediately after a
    /// successful sign-in without coupling the optional request to sign-in's
    /// error path.
    public func fetchAccountIdentity(using credentials: Credentials) async -> AccountIdentity? {
        var request = URLRequest(url: server.appendingPathComponent("api/auth/me"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await urlSession.data(for: request)
            return Self.decodeAccountIdentityResponse(
                data: data,
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        } catch {
            return nil
        }
    }

    /// Decodes a successful account response. Non-success responses and
    /// malformed/absent endpoints intentionally produce `nil`.
    public static func decodeAccountIdentityResponse(
        data: Data,
        statusCode: Int
    ) -> AccountIdentity? {
        guard statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(AccountIdentity.self, from: data)
    }

    /// Decodes a successful provider response. Non-success responses and
    /// malformed/absent endpoints intentionally produce `nil`.
    public static func decodeProviderResponse(
        data: Data,
        statusCode: Int
    ) -> [AuthProvider]? {
        guard statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(ProviderResponse.self, from: data).providers
    }

    private struct ProviderResponse: Decodable {
        let providers: [AuthProvider]
    }





    // MARK: - Interactive login

    /// Full native login. Opens the system browser and resolves once the
    /// loopback redirect has been exchanged for bearer tokens.
    public func signIn() async throws -> Credentials {
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

        openURL(authorizeURL)

        let callback = try await loopback.waitForCallback()
        // The gateway echoes our own `state` verbatim; a mismatch means the
        // redirect did not originate from the flow we started.
        guard callback.state == state else { throw AuthError.stateMismatch }

        let credentials = try await exchange(code: callback.code, verifier: pkce.verifier)
        try credentialStore.save(credentials, account: account)
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

    public func validCredentials(forceRefresh: Bool = false) async throws -> Credentials {
        if refreshRejected { throw AuthError.sessionExpired }
        guard let stored = storedCredentials else { throw AuthError.notSignedIn }
        if !forceRefresh, stored.isExpired() == false {
            return stored
        }
        return try await refreshCredentials()
    }

    /// Force one refresh after a server rejects an otherwise unexpired bearer.
    /// Concurrent callers share this task, while a rejected refresh is sticky
    /// until sign-out so lifecycle reconnects fail fast instead of hammering.
    public func refreshCredentials() async throws -> Credentials {
        if refreshRejected { throw AuthError.sessionExpired }
        if let existing = refreshTask {
            do {
                return try await existing.value
            } catch {
                if case AuthError.sessionExpired = error { refreshRejected = true }
                throw error
            }
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task { try await self.performRefresh() }
        refreshTask = task
        do {
            let result = try await task.value
            if refreshGeneration == generation { refreshTask = nil }
            return result
        } catch {
            if refreshGeneration == generation { refreshTask = nil }
            if case AuthError.sessionExpired = error { refreshRejected = true }
            throw error
        }
    }

    private func performRefresh() async throws -> Credentials {
        guard let stored = storedCredentials else { throw AuthError.notSignedIn }
        guard !stored.refreshToken.isEmpty else {
            // Treat a damaged/legacy credential as signed out so the next
            // lifecycle pass presents sign-in instead of retrying forever.
            try? credentialStore.delete(account: account)
            throw AuthError.sessionExpired
        }

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
            try? credentialStore.delete(account: account)
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
        try credentialStore.save(rotated, account: account)
        return rotated
    }


    // MARK: - WebSocket ticket

    /// Mint a single-use 30s ticket for the `/api/ws` upgrade.
    ///
    /// The WS gate rejects `Authorization` headers outright, so every
    /// connect (and reconnect) needs a fresh ticket. A stale bearer can still
    /// be rejected even when its local expiry is in the future; in that case
    /// refresh once and retry the ticket request once.
    public func webSocketTicket() async throws -> WebSocketTicket {
        let credentials = try await validCredentials()
        let first = try await requestWebSocketTicket(using: credentials)
        guard first.status == 401 else {
            return try JSONDecoder().decode(WebSocketTicket.self, from: first.data)
        }

        let refreshed = try await refreshCredentials()
        let retry = try await requestWebSocketTicket(using: refreshed)
        guard retry.status == 200 else {
            throw AuthError.ticketFailed(
                status: retry.status,
                body: String(decoding: retry.data, as: UTF8.self)
            )
        }
        return try JSONDecoder().decode(WebSocketTicket.self, from: retry.data)
    }

    private func requestWebSocketTicket(
        using credentials: Credentials
    ) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: server.appendingPathComponent("api/auth/ws-ticket"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 || status == 401 else {
            throw AuthError.ticketFailed(
                status: status,
                body: String(decoding: data, as: UTF8.self)
            )
        }
        return (data, status)
    }

    private struct FacadeCredentialStore: CredentialStoring {
        func save(_ credentials: Credentials, account: String) throws {
            try CredentialStore.save(credentials, account: account)
        }

        func load(account: String) throws -> Credentials? {
            try CredentialStore.loadThrowing(account: account)
        }

        func delete(account: String) throws {
            try CredentialStore.deleteThrowing(account: account)
        }
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
