import Foundation
import HermternalCore
import Testing

@Test("account identity decodes the complete snake case response")
func accountIdentityDecodesFullResponse() throws {
    let data = Data(
        #"{"user_id":"sub-123","email":"ada@example.com","display_name":"Ada Lovelace","org_id":"org-7","provider":"self-hosted","expires_at":1735689600}"#.utf8
    )

    let identity = try #require(
        AuthClient.decodeAccountIdentityResponse(data: data, statusCode: 200)
    )
    #expect(identity == AccountIdentity(
        userID: "sub-123",
        email: "ada@example.com",
        displayName: "Ada Lovelace",
        orgID: "org-7",
        provider: "self-hosted",
        expiresAt: 1735689600
    ))
}

@Test("sparse account identity keeps every field optional")
func accountIdentityDecodesSparseResponse() throws {
    let data = Data(#"{"display_name":"","email":""}"#.utf8)
    let identity = try #require(
        AuthClient.decodeAccountIdentityResponse(data: data, statusCode: 200)
    )
    #expect(identity.displayName == "")
    #expect(identity.email == "")
    #expect(identity.userID == nil)
    #expect(identity.orgID == nil)
    #expect(identity.provider == nil)
    #expect(identity.expiresAt == nil)
}

@Test("malformed and unsuccessful account responses are absent")
func accountIdentityFailuresAreNonFatal() {
    #expect(AuthClient.decodeAccountIdentityResponse(data: Data("not-json".utf8), statusCode: 200) == nil)
    #expect(AuthClient.decodeAccountIdentityResponse(data: Data(#"{}"#.utf8), statusCode: 401) == nil)
    #expect(AuthClient.decodeAccountIdentityResponse(data: Data(#"{}"#.utf8), statusCode: 404) == nil)
}

@Test("optional identity fetch turns a network failure into absence")
func accountIdentityNetworkFailureIsNonFatal() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FailingAccountIdentityURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = AuthClient(
        server: URL(string: "https://gateway.example")!,
        urlSession: session
    )
    let credentials = Credentials(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        expiresAt: Int(Date().timeIntervalSince1970) + 3600,
        provider: "self-hosted",
        userID: "sub-123"
    )

    #expect(await client.fetchAccountIdentity(using: credentials) == nil)
}

@Test("identity fetch sends the bearer token to the account endpoint")
func accountIdentityFetchUsesBearerToken() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BearerAccountIdentityURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = AuthClient(server: URL(string: "https://gateway.example")!, urlSession: session)
    let credentials = Credentials(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        expiresAt: Int(Date().timeIntervalSince1970) + 3600,
        provider: "self-hosted",
        userID: "sub-123"
    )

    let identity = try #require(await client.fetchAccountIdentity(using: credentials))
    #expect(identity.userID == "sub-123")
}

@Test("the gateway is the primary label and the human name the secondary")
func gatewayLeadsAndAccountNameFollows() {
    let gateway = URL(string: "https://gateway.example/instance")!
    let provider = AuthProvider(name: "self-hosted", displayName: "Self-Hosted OIDC", supportsPassword: false)

    #expect(AccountIdentityResolver.resolve(
        identity: AccountIdentity(userID: "sub-123", email: "ada@example.com", displayName: "Ada", orgID: "org-7"),
        provider: provider,
        gateway: gateway
    ) == AccountIdentityPresentation(title: "gateway.example", detail: "Ada", accountID: "sub-123"))
    #expect(AccountIdentityResolver.resolve(
        identity: AccountIdentity(userID: "sub-123", email: "ada@example.com", orgID: "org-7"),
        provider: provider,
        gateway: gateway
    ) == AccountIdentityPresentation(title: "gateway.example", detail: "ada@example.com", accountID: "sub-123"))
    #expect(AccountIdentityResolver.resolve(
        identity: AccountIdentity(),
        provider: provider,
        gateway: gateway
    ) == AccountIdentityPresentation(title: "gateway.example"))
    #expect(AccountIdentityResolver.resolve(
        identity: nil,
        provider: nil,
        gateway: gateway
    ) == AccountIdentityPresentation(title: "gateway.example"))
}

@Test("an opaque account identifier never occupies a visible line")
func accountIdentifierStaysOutOfSight() {
    let provider = AuthProvider(name: "self-hosted", displayName: "Self-Hosted OIDC", supportsPassword: false)
    // The self-hosted gateway returns a subject only. This case put an
    // identifier in the sidebar before.
    let anonymous = AccountIdentityResolver.resolve(
        identity: AccountIdentity(userID: "sub-123456789012345", orgID: "org-7"),
        provider: provider,
        gateway: URL(string: "https://gateway.example/instance")!
    )
    #expect(anonymous == AccountIdentityPresentation(
        title: "gateway.example",
        detail: "org-7",
        accountID: "sub-123456789012345"
    ))

    // Blank fields are absent, not an empty label. The subject must stay out
    // of both visible lines.
    let blank = AccountIdentityResolver.resolve(
        identity: AccountIdentity(userID: "account-identifier-123", email: "", displayName: " "),
        provider: provider,
        gateway: URL(string: "https://gateway.example")!
    )
    #expect(blank.title == "gateway.example")
    #expect(blank.detail == nil)
    // Retained for the tooltip and the accessibility label only.
    #expect(blank.accountID == "account-identifier-123")
}

@Test("a gateway label carries an explicit port and nothing else")
func gatewayLabelKeepsHostAndPort() {
    #expect(AccountIdentityResolver.gatewayLabel(
        for: URL(string: "https://hermes-dashboard.kayg.org/api")!
    ) == "hermes-dashboard.kayg.org")
    #expect(AccountIdentityResolver.gatewayLabel(
        for: URL(string: "https://gateway.example:8443/api/")!
    ) == "gateway.example:8443")
    #expect(AccountIdentityResolver.gatewayLabel(
        for: URL(string: "http://localhost:8787")!
    ) == "localhost:8787")
    // Foundation removes the brackets from an IPv6 literal. Without the
    // brackets, a reader cannot tell the address from the port.
    #expect(AccountIdentityResolver.gatewayLabel(
        for: URL(string: "http://[::1]:8787/api")!
    ) == "[::1]:8787")
}

@Test("no scheme, path, credential, query, or trailing slash reaches the pill")
func gatewayLabelWithholdsSecrets() throws {
    let loaded = URL(string: "https://ada:s3cr3t@gateway.example/api/v1/?token=abcdef#frag")!
    let label = try #require(AccountIdentityResolver.gatewayLabel(for: loaded))

    #expect(label == "gateway.example")
    for secret in ["https", "://", "ada", "s3cr3t", "@", "/", "api", "token", "abcdef", "frag"] {
        #expect(!label.contains(secret), "\(label) leaked \(secret)")
    }
}

@Test("a configuration naming no host falls back without showing the URL")
func hostlessConfigurationFallsBackToNames() {
    // A relative URL has no authority component. Its path can contain a
    // token, so the label must not use the path.
    let hostless = URL(string: "gateway.example/config?token=abcdef")!
    #expect(AccountIdentityResolver.gatewayLabel(for: hostless) == nil)

    let provider = AuthProvider(name: "self-hosted", displayName: "Self-Hosted OIDC", supportsPassword: false)
    #expect(AccountIdentityResolver.resolve(
        identity: AccountIdentity(userID: "sub-123", displayName: "Ada"),
        provider: provider,
        gateway: hostless
    ) == AccountIdentityPresentation(title: "Ada", accountID: "sub-123"))
    #expect(AccountIdentityResolver.resolve(
        identity: AccountIdentity(userID: "sub-123"),
        provider: provider,
        gateway: hostless
    ) == AccountIdentityPresentation(title: "Self-Hosted OIDC", accountID: "sub-123"))
    #expect(AccountIdentityResolver.resolve(
        identity: nil,
        provider: nil,
        gateway: hostless
    ) == AccountIdentityPresentation(title: AccountIdentityResolver.unnamedGateway))
}

@Test("web socket tickets preserve optional TTL")
func webSocketTicketDecoding() throws {
    let withTTL = try JSONDecoder().decode(
        WebSocketTicket.self,
        from: Data(#"{"ticket":"one-use","ttl_seconds":30}"#.utf8)
    )

    #expect(withTTL == WebSocketTicket(ticket: "one-use", ttlSeconds: 30))

    let withoutTTL = try JSONDecoder().decode(
        WebSocketTicket.self,
        from: Data(#"{"ticket":"one-use"}"#.utf8)
    )
    #expect(withoutTTL == WebSocketTicket(ticket: "one-use"))
}

private final class BearerAccountIdentityURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.url?.path == "/api/auth/me",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token"
        else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"user_id":"sub-123"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FailingAccountIdentityURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
