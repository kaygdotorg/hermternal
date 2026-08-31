import Foundation
import HermternalCore
import Testing

private final class CountingCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Credentials] = [:]
    private var _loads = 0
    private var _saves = 0
    private var _deletes = 0

    var loads: Int { lock.withLock { _loads } }
    var saves: Int { lock.withLock { _saves } }
    var deletes: Int { lock.withLock { _deletes } }

    func save(_ credentials: Credentials, account: String) throws {
        lock.withLock {
            _saves += 1
            values[account] = credentials
        }
    }

    func load(account: String) throws -> Credentials? {
        lock.withLock {
            _loads += 1
            return values[account]
        }
    }

    func delete(account: String) throws {
        lock.withLock {
            _deletes += 1
            values.removeValue(forKey: account)
        }
    }
}

private struct CredentialReadError: LocalizedError, Equatable {
    var errorDescription: String? { "credential backend unavailable" }
}

private final class FailingCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _loads = 0

    var loads: Int { lock.withLock { _loads } }

    func save(_: Credentials, account: String) throws {}

    func load(account: String) throws -> Credentials? {
        lock.withLock { _loads += 1 }
        throw CredentialReadError()
    }

    func delete(account: String) throws {}
}

private final class NoRequestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests = 0

    static var requests: Int { lock.withLock { _requests } }

    static func reset() {
        lock.withLock { _requests = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._requests += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
    }

    override func stopLoading() {}
}

private final class CredentialCacheURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let (status, body): (Int, Data) = if path.hasSuffix("/api/auth/me") {
            (200, Data(#"{"user_id":"user","email":"user@example.com"}"#.utf8))
        } else if path.hasSuffix("/api/auth/ws-ticket") {
            (200, Data(#"{"ticket":"one-use","ttl_seconds":30}"#.utf8))
        } else if path.hasSuffix("/api/sessions") {
            (200, Data(#"{"sessions":[],"total":0,"limit":1,"offset":0}"#.utf8))
        } else if path.hasSuffix("/auth/native/refresh") {
            (200, Data(#"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_at":4102444800,"provider":"self-hosted","user_id":"user"}"#.utf8))
        } else {
            (404, Data())
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

private func cachedCredentials() -> Credentials {
    Credentials(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        expiresAt: 4102444800,
        provider: "self-hosted",
        userID: "user"
    )
}

@Test("identity, ticket, and REST pages share one cold credential load")
func authCredentialCacheCoversNormalLaunchWork() async throws {
    let store = CountingCredentialStore()
    let server = URL(string: "https://gateway.example/cache-normal")!
    try store.save(cachedCredentials(), account: server.absoluteString)
    let configuration = URLSessionConfiguration.ephemeral
    // A fixture session must not wait for a network path. The default wait hung the suite.
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = 5
    configuration.protocolClasses = [CredentialCacheURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let auth = AuthClient(server: server, urlSession: session, credentialStore: store)
    let rest = RestClient(server: server, auth: auth, urlSession: session)

    #expect(await auth.fetchAccountIdentity()?.userID == "user")
    #expect(try await auth.webSocketTicket() == WebSocketTicket(ticket: "one-use", ttlSeconds: 30))
    for _ in 0..<51 {
        _ = try await rest.sessionList(limit: 1)
    }

    #expect(store.loads == 1)
}

@Test("concurrent credential callers share one cold load")
func concurrentCredentialReadsAreSingleLoad() async throws {
    let store = CountingCredentialStore()
    let server = URL(string: "https://gateway.example/cache-concurrent")!
    try store.save(cachedCredentials(), account: server.absoluteString)
    let auth = AuthClient(server: server, credentialStore: store)

    let values = try await withThrowingTaskGroup(of: Credentials.self) { group in
        for _ in 0..<32 {
            group.addTask { try await auth.validCredentials() }
        }
        var values: [Credentials] = []
        for try await value in group { values.append(value) }
        return values
    }

    #expect(values.count == 32)
    #expect(store.loads == 1)
}

@Test("explicit refresh reloads and saves once, then uses the rotated cache")
func refreshDoesOneAuthoritativeCredentialRead() async throws {
    let store = CountingCredentialStore()
    let server = URL(string: "https://gateway.example/cache-refresh")!
    try store.save(cachedCredentials(), account: server.absoluteString)
    let configuration = URLSessionConfiguration.ephemeral
    // A fixture session must not wait for a network path. The default wait hung the suite.
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = 5
    configuration.protocolClasses = [CredentialCacheURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let auth = AuthClient(server: server, urlSession: session, credentialStore: store)

    _ = try await auth.validCredentials()
    let refreshed = try await auth.refreshCredentials()
    #expect(refreshed.accessToken == "fresh-access")
    _ = try await auth.validCredentials()

    #expect(store.loads == 2)
    #expect(store.saves == 2)
}

@Test("a new AuthClient performs its own single cold load")
func eachAuthClientHasIndependentCredentialCache() async throws {
    let store = CountingCredentialStore()
    let server = URL(string: "https://gateway.example/cache-new")!
    try store.save(cachedCredentials(), account: server.absoluteString)
    let first = AuthClient(server: server, credentialStore: store)
    let second = AuthClient(server: server, credentialStore: store)

    _ = try await first.validCredentials()
    _ = try await first.validCredentials()
    _ = try await second.validCredentials()
    _ = try await second.validCredentials()

    #expect(store.loads == 2)
}

@Test("credential load failures do not look signed out or start network work")
func credentialLoadFailureStopsAuthenticatedWork() async throws {
    NoRequestURLProtocol.reset()
    let store = FailingCredentialStore()
    let server = URL(string: "https://gateway.example/cache-failure")!
    let configuration = URLSessionConfiguration.ephemeral
    // A fixture session must not wait for a network path. The default wait hung the suite.
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = 5
    configuration.protocolClasses = [NoRequestURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let auth = AuthClient(server: server, urlSession: session, credentialStore: store)
    let rest = RestClient(server: server, auth: auth, urlSession: session)
    #expect(await auth.fetchAccountIdentity() == nil)
    do {
        _ = try await auth.webSocketTicket()
        Issue.record("ticket unexpectedly succeeded")
    } catch let error as AuthCredentialError {
        #expect(error == .loadFailed("credential backend unavailable"))
    } catch {
        Issue.record("unexpected ticket error: \(error)")
    }
    do {
        _ = try await rest.sessionList()
        Issue.record("REST request unexpectedly succeeded")
    } catch let error as AuthCredentialError {
        #expect(error == .loadFailed("credential backend unavailable"))
    } catch {
        Issue.record("unexpected REST error: \(error)")
    }

    #expect(store.loads == 1)
    #expect(NoRequestURLProtocol.requests == 0)
}
