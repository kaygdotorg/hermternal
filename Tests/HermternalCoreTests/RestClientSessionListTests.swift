import Foundation
import HermternalCore
import Testing

@Test("REST session list de-duplicates pinned rows across pages")
func restSessionListDeduplicatesPinnedRows() async throws {
    let pages = [
        SessionListPageFixture(rows: [sessionRow(id: "recent-1"), sessionRow(id: "recent-2")]),
        SessionListPageFixture(rows: [sessionRow(id: "pinned"), sessionRow(id: "recent-1")]),
        SessionListPageFixture(rows: [sessionRow(id: "pinned"), sessionRow(id: "recent-2")])
    ]
    let (client, fixture, cleanup) = try makeSessionListClient(pages: pages)
    defer { cleanup() }

    let rows = try await client.allSessions()

    #expect(sessionIDs(rows) == ["recent-1", "recent-2", "pinned"])
    #expect(Set(sessionIDs(rows)).count == rows.count)
    #expect(fixture.offsets == [0, 100, 200])
    #expect(fixture.archivedFilters == ["exclude", "exclude", "exclude"])
}

@Test("REST session list sends the typed archived-only filter on every page")
func restSessionListSendsArchivedOnlyOnEveryPage() async throws {
    let pages = [
        SessionListPageFixture(rows: [sessionRow(id: "recent-1")]),
        SessionListPageFixture(rows: [sessionRow(id: "pinned"), sessionRow(id: "recent-1")]),
        SessionListPageFixture(rows: [sessionRow(id: "pinned"), sessionRow(id: "recent-2")])
    ]
    let (client, fixture, cleanup) = try makeSessionListClient(pages: pages)
    defer { cleanup() }

    let rows = try await client.allSessions(archived: .only)

    #expect(sessionIDs(rows) == ["recent-1", "pinned", "recent-2"])
    #expect(fixture.offsets == [0, 100, 200, 300])
    #expect(fixture.archivedFilters == ["only", "only", "only", "only"])
}

@Test("REST session list stops when a page adds no new id")
func restSessionListStopsOnRepeatedPinnedRows() async throws {
    let pages = [
        SessionListPageFixture(rows: [sessionRow(id: "pinned")]),
        SessionListPageFixture(rows: [sessionRow(id: "pinned")])
    ]
    let (client, fixture, cleanup) = try makeSessionListClient(pages: pages)
    defer { cleanup() }

    let rows = try await client.allSessions()

    #expect(sessionIDs(rows) == ["pinned"])
    #expect(fixture.offsets == [0, 100])
}

@Test("REST session list throws when its page bound is reached")
func restSessionListEnforcesPageBound() async throws {
    let pages = (0..<RestClient.maximumSessionPages).map { index in
        SessionListPageFixture(rows: [sessionRow(id: "session-\(index)")])
    }
    let (client, fixture, cleanup) = try makeSessionListClient(pages: pages)
    defer { cleanup() }

    do {
        _ = try await client.allSessions()
        Issue.record("session page bound did not throw")
    } catch let error as RestError {
        switch error {
        case .sessionPageLimitExceeded:
            break
        case .badStatus, .messagePageLimitExceeded, .messagePageTooLarge, .noMutableFields, .sessionNotFound,
             .purgeEmptyIDs, .purgeBatchTooLarge, .purgeInvalidConfirmation,
             .purgeUnsupportedEndpoint, .purgeHTTPError, .purgeMalformedResponse:
            Issue.record("unexpected REST error: \(error)")
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(fixture.offsets.count == RestClient.maximumSessionPages)
    #expect(fixture.offsets.last == (RestClient.maximumSessionPages - 1) * 100)
}

@Test("REST session list propagates a second-page failure")
func restSessionListFailureDoesNotReturnPartialRows() async throws {
    let pages = [
        SessionListPageFixture(rows: [sessionRow(id: "first")]),
        SessionListPageFixture(rows: [], status: 503)
    ]
    let (client, fixture, cleanup) = try makeSessionListClient(pages: pages)
    defer { cleanup() }

    do {
        _ = try await client.allSessions()
        Issue.record("second-page failure did not throw")
    } catch let error as RestError {
        switch error {
        case .badStatus(let status, _):
            #expect(status == 503)
        case .messagePageLimitExceeded, .messagePageTooLarge, .sessionPageLimitExceeded,
             .noMutableFields, .sessionNotFound, .purgeEmptyIDs,
             .purgeBatchTooLarge, .purgeInvalidConfirmation,
             .purgeUnsupportedEndpoint, .purgeHTTPError, .purgeMalformedResponse:
            Issue.record("unexpected REST error: \(error)")
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(fixture.offsets == [0, 100])
}

private struct SessionListPageFixture: Sendable {
    let rows: [JSONValue]
    let status: Int

    init(rows: [JSONValue], status: Int = 200) {
        self.rows = rows
        self.status = status
    }
}

private final class SessionListFixture: @unchecked Sendable {
    let id: String
    private let pages: [SessionListPageFixture]
    private let lock = NSLock()
    private var requests: [Int] = []
    private var archivedRequests: [String] = []
    private var nextPage = 0

    init(pages: [SessionListPageFixture]) {
        self.id = UUID().uuidString
        self.pages = pages
    }

    var offsets: [Int] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    var archivedFilters: [String] {
        lock.lock(); defer { lock.unlock() }
        return archivedRequests
    }

    func response(for request: URLRequest) -> (Int, Data) {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let offset = Int(
            components.queryItems!.first { $0.name == "offset" }!.value!
        )!
        let archived = components.queryItems!.first { $0.name == "archived" }!.value!
        lock.lock()
        requests.append(offset)
        archivedRequests.append(archived)
        let page = pages[min(nextPage, pages.count - 1)]
        nextPage += 1
        lock.unlock()

        let payload: JSONValue = .object([
            "sessions": .array(page.rows),
            "total": .integer(Int64(page.rows.count)),
            "limit": .integer(100),
            "offset": .integer(Int64(offset))
        ])
        return (page.status, try! JSONEncoder().encode(payload))
    }
}

private final class SessionListRegistry: @unchecked Sendable {
    static let shared = SessionListRegistry()
    private let lock = NSLock()
    private var fixtures: [String: SessionListFixture] = [:]

    func install(_ fixture: SessionListFixture) {
        lock.lock(); defer { lock.unlock() }
        fixtures[fixture.id] = fixture
    }

    func remove(_ fixture: SessionListFixture) {
        lock.lock(); defer { lock.unlock() }
        fixtures.removeValue(forKey: fixture.id)
    }

    /// The server URL is `https://host/<fixture id>/`, so the fixture id is the
    /// first path component. The list path has no trailing id to strip.
    func fixture(for request: URLRequest) -> SessionListFixture? {
        guard let id = request.url?.path.split(separator: "/").first else {
            return nil
        }
        lock.lock(); defer { lock.unlock() }
        return fixtures[String(id)]
    }
}

private final class SessionListURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.contains("/api/sessions") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = SessionListRegistry.shared.fixture(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
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

private func makeSessionListClient(
    pages: [SessionListPageFixture]
) throws -> (RestClient, SessionListFixture, () -> Void) {
    let fixture = SessionListFixture(pages: pages)
    SessionListRegistry.shared.install(fixture)
    let server = URL(string: "https://gateway.example/\(fixture.id)/")!
    let credentials = Credentials(
        accessToken: "test-access-token",
        refreshToken: "test-refresh-token",
        expiresAt: Int(Date().timeIntervalSince1970) + 3600,
        provider: "test",
        userID: "test-user"
    )
    try CredentialStore.save(credentials, account: server.absoluteString)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionListURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let auth = AuthClient(server: server, urlSession: session)
    let client = RestClient(server: server, auth: auth, urlSession: session)
    return (client, fixture, {
        SessionListRegistry.shared.remove(fixture)
        CredentialStore.delete(account: server.absoluteString)
    })
}

private func sessionIDs(_ rows: [JSONValue]) -> [String] {
    rows.compactMap { $0["id"]?.stringValue }
}

private func sessionRow(id: String) -> JSONValue {
    .object([
        "id": .string(id),
        "title": .string("Chat \(id)")
    ])
}
