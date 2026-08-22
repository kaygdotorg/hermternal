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

@Test("identity display resolution uses each source in priority order")
func accountIdentityFallbackChain() {
    let gateway = URL(string: "https://gateway.example/instance")!
    let provider = AuthProvider(name: "self-hosted", displayName: "Self-Hosted OIDC", supportsPassword: false)

    #expect(AccountIdentityResolver.resolve(
        identity: AccountIdentity(userID: "sub-123", email: "ada@example.com", displayName: "Ada", orgID: "org-7"),
        provider: provider,
        gateway: gateway
    ) == AccountIdentityPresentation(title: "Ada", detail: "ada@example.com", accountID: "sub-123"))
    #expect(AccountIdentityResolver.resolve(
        identity: AccountIdentity(userID: "sub-123", email: "ada@example.com", orgID: "org-7"),
        provider: provider,
        gateway: gateway
    ) == AccountIdentityPresentation(title: "ada@example.com", detail: "org-7", accountID: "sub-123"))
    #expect(AccountIdentityResolver.resolve(
        identity: AccountIdentity(userID: "sub-123456789012345", orgID: "org-7"),
        provider: provider,
        gateway: gateway
    ) == AccountIdentityPresentation(title: "sub-1234567890…", detail: "org-7", accountID: "sub-123456789012345"))
    #expect(AccountIdentityResolver.resolve(
        identity: AccountIdentity(),
        provider: provider,
        gateway: gateway
    ) == AccountIdentityPresentation(title: "Self-Hosted OIDC"))
    #expect(AccountIdentityResolver.resolve(
        identity: nil,
        provider: nil,
        gateway: gateway
    ) == AccountIdentityPresentation(title: "gateway.example", detail: "https://gateway.example/instance"))
}

@Test("blank human fields select the account ID, never an empty label")
func blankHumanFieldsUseAccountID() {
    let identity = AccountIdentity(userID: "account-identifier-123", email: "", displayName: " ")
    let presentation = AccountIdentityResolver.resolve(
        identity: identity,
        provider: AuthProvider(name: "self-hosted", displayName: "Self-Hosted OIDC", supportsPassword: false),
        gateway: URL(string: "https://gateway.example")!
    )
    // 14 characters plus U+2026, matching the Hermes web widget exactly.
    #expect(presentation.title == "account-identi…")
    #expect(presentation.accountID == "account-identifier-123")
}

@Test("account ID truncation matches the web widget boundary")
func accountIDTruncationBoundary() {
    #expect(AccountIdentityResolver.truncateAccountID("12345678901234") == "12345678901234")
    #expect(AccountIdentityResolver.truncateAccountID("123456789012345") == "12345678901234…")
}

@Test("a configured URL is the final fallback when no host is known")
func configuredURLFallback() {
    let gateway = URL(string: "gateway.example/config")!
    #expect(AccountIdentityResolver.resolve(identity: nil, provider: nil, gateway: gateway).title == "gateway.example/config")
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
