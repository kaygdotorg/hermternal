import Foundation
import HermternalCore
import Testing

private final class RefreshStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Credentials] = [:]

    func save(_ credentials: Credentials, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = credentials
    }

    func load(account: String) throws -> Credentials? {
        lock.lock(); defer { lock.unlock() }
        return values[account]
    }

    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: account)
    }
}

private final class RefreshFixture: @unchecked Sendable {
    let mode: Mode
    let id = UUID().uuidString
    private let lock = NSLock()
    private var _messageRequests = 0
    private var _refreshRequests = 0
    private var _ticketRequests = 0
    private var _messageBearers: [String] = []
    private var _ticketBearers: [String] = []

    enum Mode: Sendable {
        case restRefreshes
        case invalidRefresh
        case ticketRefreshes
        case concurrentRefreshes
    }

    init(mode: Mode) { self.mode = mode }

    var messageRequests: Int { lock.withLock { _messageRequests } }
    var refreshRequests: Int { lock.withLock { _refreshRequests } }
    var ticketRequests: Int { lock.withLock { _ticketRequests } }
    var messageBearers: [String] { lock.withLock { _messageBearers } }
    var ticketBearers: [String] { lock.withLock { _ticketBearers } }

    func response(for request: URLRequest) -> (Int, Data) {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/messages") {
            lock.lock()
            _messageRequests += 1
            _messageBearers.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            let count = _messageRequests
            lock.unlock()
            switch mode {
            case .restRefreshes, .invalidRefresh:
                if count == 1 { return (401, Data()) }
                return (200, Data(#"{"messages":[{"id":1,"role":"assistant","content":"ok"}],"pagination":{"returned":1}}"#.utf8))
            case .concurrentRefreshes:
                if count <= 4 {
                    Thread.sleep(forTimeInterval: 0.5)
                    return (401, Data())
                }
                return (200, Data(#"{"messages":[{"id":1,"role":"assistant","content":"ok"}],"pagination":{"returned":1}}"#.utf8))
            case .ticketRefreshes:
                return (404, Data())
            }
        }
        if path.hasSuffix("/refresh") {
            lock.lock(); _refreshRequests += 1; lock.unlock()
            switch mode {
            case .restRefreshes, .ticketRefreshes, .concurrentRefreshes:
                if mode == .concurrentRefreshes {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                return (200, Data(#"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_at":4102444800,"provider":"self-hosted","user_id":"user"}"#.utf8))
            case .invalidRefresh:
                Thread.sleep(forTimeInterval: 0.05)
                return (401, Data())
            }
        }
        if path.hasSuffix("/ws-ticket") {
            lock.lock()
            _ticketRequests += 1
            _ticketBearers.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            let count = _ticketRequests
            lock.unlock()
            if mode == .ticketRefreshes, count == 1 { return (401, Data()) }
            if mode == .ticketRefreshes { return (200, Data(#"{"ticket":"one-use","ttl_seconds":30}"#.utf8)) }
            return (404, Data())
        }
        return (404, Data())
    }
}

private final class RefreshRegistry: @unchecked Sendable {
    static let shared = RefreshRegistry()
    private let lock = NSLock()
    private var fixtures: [String: RefreshFixture] = [:]

    func install(_ fixture: RefreshFixture) {
        lock.lock(); defer { lock.unlock() }
        fixtures[fixture.id] = fixture
    }

    func remove(_ fixture: RefreshFixture) {
        lock.lock(); defer { lock.unlock() }
        fixtures.removeValue(forKey: fixture.id)
    }

    func fixture(for request: URLRequest) -> RefreshFixture? {
        guard let id = request.url?.path.split(separator: "/").first.map(String.init) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return fixtures[id]
    }
}

private final class RefreshURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = RefreshRegistry.shared.fixture(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data) = fixture.response(for: request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

private func makeRefreshClient(
    fixture: RefreshFixture
) throws -> (AuthClient, RestClient, RefreshStore, URL) {
    let server = URL(string: "https://gateway.example/\(fixture.id)/")!
    let store = RefreshStore()
    try store.save(
        Credentials(
            accessToken: "stale-access",
            refreshToken: "stored-refresh",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            provider: "self-hosted",
            userID: "user"
        ),
        account: server.absoluteString
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RefreshURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let auth = AuthClient(server: server, urlSession: session, credentialStore: store)
    let rest = RestClient(server: server, auth: auth, urlSession: session)
    RefreshRegistry.shared.install(fixture)
    return (auth, rest, store, server)
}

private func cleanup(_ fixture: RefreshFixture) {
    RefreshRegistry.shared.remove(fixture)
}

@Test("a rejected REST bearer refreshes once and retries the original call")
func rest401RefreshesAndRetries() async throws {
    let fixture = RefreshFixture(mode: .restRefreshes)
    let (auth, rest, _, _) = try makeRefreshClient(fixture: fixture)
    defer { cleanup(fixture) }
    let rows = try await rest.sessionMessages(durableID: "session")
    #expect(rows.count == 1)
    #expect(fixture.messageRequests == 2)
    #expect(fixture.refreshRequests == 1)
    #expect(fixture.messageBearers.count == 2)
    #expect(fixture.messageBearers.first != fixture.messageBearers.last)
    _ = auth
}

@Test("concurrent unauthorized callers share one refresh")
func concurrentRefreshesAreSingleFlight() async throws {
    let fixture = RefreshFixture(mode: .concurrentRefreshes)
    let (_, rest, _, _) = try makeRefreshClient(fixture: fixture)
    defer { cleanup(fixture) }
    let values = try await withThrowingTaskGroup(of: [JSONValue].self) { group in
        for _ in 0..<4 {
            group.addTask { try await rest.sessionMessages(durableID: "session") }
        }
        var values: [[JSONValue]] = []
        for try await value in group {
            values.append(value)
        }
        return values
    }
    #expect(values.count == 4)
    #expect(fixture.messageRequests == 8)
    #expect(fixture.refreshRequests == 1)
}

@Test("an invalid refresh becomes one sign-in error without a retry loop")
func invalidRefreshSurfacesOnce() async throws {
    let fixture = RefreshFixture(mode: .invalidRefresh)
    let (auth, rest, store, server) = try makeRefreshClient(fixture: fixture)
    defer { cleanup(fixture) }
    do {
        _ = try await rest.sessionMessages(durableID: "session")
        Issue.record("invalid refresh unexpectedly succeeded")
    } catch let error as AuthError {
        guard case .sessionExpired = error else { Issue.record("wrong auth error"); return }
    }
    do {
        _ = try await rest.sessionMessages(durableID: "session")
        Issue.record("sticky rejection unexpectedly succeeded")
    } catch let error as AuthError {
        guard case .sessionExpired = error else { Issue.record("wrong sticky error"); return }
    }
    #expect(fixture.messageRequests == 1)
    #expect(fixture.refreshRequests == 1)
    #expect(try store.load(account: server.absoluteString) == nil)
    _ = auth
}

@Test("waiting callers share one rejected refresh and become sticky")
func concurrentRejectedRefreshesAreSticky() async throws {
    let fixture = RefreshFixture(mode: .invalidRefresh)
    let (auth, _, _, _) = try makeRefreshClient(fixture: fixture)
    defer { cleanup(fixture) }
    let failures = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<4 {
            group.addTask {
                do {
                    _ = try await auth.refreshCredentials()
                    return false
                } catch let error as AuthError {
                    if case .sessionExpired = error { return true }
                    return false
                } catch {
                    return false
                }
            }
        }
        var failures: [Bool] = []
        for await failure in group {
            failures.append(failure)
        }
        return failures
    }
    #expect(failures.count == 4)
    #expect(failures.allSatisfy { $0 })
    #expect(fixture.refreshRequests == 1)
}

@Test("the ticket path refreshes a stale bearer before minting")
func ticketRefreshesBeforeMinting() async throws {
    let fixture = RefreshFixture(mode: .ticketRefreshes)
    let (auth, _, _, _) = try makeRefreshClient(fixture: fixture)
    defer { cleanup(fixture) }
    let ticket = try await auth.webSocketTicket()
    #expect(ticket == WebSocketTicket(ticket: "one-use", ttlSeconds: 30))
    #expect(fixture.ticketRequests == 2)
    #expect(fixture.refreshRequests == 1)
    #expect(fixture.ticketBearers.count == 2)
    #expect(fixture.ticketBearers.first != fixture.ticketBearers.last)
}

@Test("credential store round-trip retains refresh material exactly")
func refreshMaterialRoundTripsExactly() throws {
    let keychain = TestKeychain()
    let store = KeychainCredentialStore(client: keychain)
    let credentials = Credentials(
        accessToken: "access-material",
        refreshToken: "refresh-material-with-punctuation:/+==",
        expiresAt: 4102444800,
        provider: "self-hosted",
        userID: "user"
    )
    try store.save(credentials, account: "gateway")
    let persisted = try #require(keychain.values["gateway"]?.data)
    #expect(try JSONDecoder().decode(Credentials.self, from: persisted).refreshToken == credentials.refreshToken)
    #expect(try store.load(account: "gateway") == credentials)
}

private final class TestKeychain: KeychainClient, @unchecked Sendable {
    var values: [String: KeychainSecret] = [:]

    func read(account: String) throws -> KeychainSecret? { values[account] }
    func write(_ secret: KeychainSecret) throws { values[secret.account] = secret }
    func delete(account: String) throws { values.removeValue(forKey: account) }
}
