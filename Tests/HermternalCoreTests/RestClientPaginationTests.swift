import Foundation
import HermternalCore
import Testing

@Test("REST paging preserves chronological order and terminates on a short page")
func restPagingPreservesOrder() async throws {
    let rows = (0..<556).map { pagingRow(id: Int64($0)) }
    let first = PagingPage(rows: Array(rows.prefix(500)), returned: 500)
    let second = PagingPage(rows: Array(rows.dropFirst(500)), returned: 56)
    let (client, fixture, cleanup) = try makePagingClient(pages: [first, second])
    defer { cleanup() }

    let fetched = try await client.sessionMessages(durableID: fixture.id)
    #expect(pagingIDs(fetched) == pagingIDs(rows))
    #expect(fixture.offsets == [0, 500])
}

@Test("REST paging fetches the measured 896-row session in order")
func restPagingFetchesEightHundredNinetySixRows() async throws {
    let rows = (0..<896).map { pagingRow(id: Int64($0)) }
    let pages = [
        PagingPage(rows: Array(rows.prefix(500)), returned: 500),
        PagingPage(rows: Array(rows.dropFirst(500)), returned: 396)
    ]
    let (client, fixture, cleanup) = try makePagingClient(pages: pages)
    defer { cleanup() }

    #expect(pagingIDs(try await client.sessionMessages(durableID: fixture.id)) == pagingIDs(rows))
    #expect(fixture.offsets == [0, 500])
}

@Test("REST paging handles empty and exactly full pages")
func restPagingHandlesEmptyAndFullPages() async throws {
    let empty = PagingPage(rows: [], returned: 0)
    let (emptyClient, emptyFixture, emptyCleanup) = try makePagingClient(pages: [empty])
    defer { emptyCleanup() }
    #expect(try await emptyClient.sessionMessages(durableID: emptyFixture.id).isEmpty)
    #expect(emptyFixture.offsets == [0])

    let rows = (0..<500).map { pagingRow(id: Int64($0)) }
    let full = PagingPage(rows: rows, returned: 500)
    let end = PagingPage(rows: [], returned: 0)
    let (fullClient, fullFixture, fullCleanup) = try makePagingClient(pages: [full, end])
    defer { fullCleanup() }
    #expect(pagingIDs(try await fullClient.sessionMessages(durableID: fullFixture.id)) == pagingIDs(rows))
    #expect(fullFixture.offsets == [0, 500])
}

@Test("REST paging retains no partial result when a later page fails")
func restPagingFailureDoesNotReturnPartialRows() async throws {
    let rows = (0..<500).map { pagingRow(id: Int64($0)) }
    let fixturePages = [
        PagingPage(rows: rows, returned: 500),
        PagingPage(rows: [], returned: 0, status: 503)
    ]
    let (client, fixture, cleanup) = try makePagingClient(pages: fixturePages)
    defer { cleanup() }

    await #expect(throws: RestError.self) {
        try await client.sessionMessages(durableID: fixture.id)
    }
    #expect(fixture.offsets == [0, 500])
}
@Test("REST paging cancellation between pages publishes no result")
func restPagingCancellationBetweenPages() async throws {
    let pages = [
        PagingPage(rows: (0..<500).map { pagingRow(id: Int64($0)) }, returned: 500),
        PagingPage(rows: [], returned: 0)
    ]
    let (client, fixture, cleanup) = try makePagingClient(pages: pages, blockedPage: 1)
    defer { cleanup() }

    let task = Task {
        try? await client.sessionMessages(durableID: fixture.id)
    }
    while fixture.offsets != [0, 500] {
        await Task.yield()
    }
    task.cancel()
    fixture.releaseBlockedPage()
    #expect(await task.value == nil)
}

@Test("REST paging enforces its page bound")
func restPagingEnforcesPageBound() async throws {
    let pages = Array(
        repeating: PagingPage(rows: [pagingRow(id: 1)], returned: 500),
        count: RestClient.maximumMessagePages
    )
    let (client, fixture, cleanup) = try makePagingClient(pages: pages)
    defer { cleanup() }

    do {
        _ = try await client.sessionMessages(durableID: fixture.id)
        Issue.record("page bound did not throw")
    } catch let error as RestError {
        switch error {
        case .messagePageLimitExceeded:
            break
        case .badStatus, .noMutableFields, .sessionNotFound:
            Issue.record("unexpected REST error: \(error)")
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(fixture.offsets.count == RestClient.maximumMessagePages)
    #expect(fixture.offsets.last == (RestClient.maximumMessagePages - 1) * 500)
}

private struct PagingPage: Sendable {
    let rows: [JSONValue]
    let returned: Int
    let status: Int

    init(rows: [JSONValue], returned: Int, status: Int = 200) {
        self.rows = rows
        self.returned = returned
        self.status = status
    }
}

private final class PagingFixture: @unchecked Sendable {
    let id: String
    private let pages: [PagingPage]
    private let blockedPage: Int?
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var requests: [Int] = []
    private var nextPage = 0

    init(pages: [PagingPage], blockedPage: Int? = nil) {
        self.id = UUID().uuidString
        self.pages = pages
        self.blockedPage = blockedPage
    }

    var offsets: [Int] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    func response(for request: URLRequest) -> (Int, Data) {
        let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "offset" }!.value!
        let parsedOffset = Int(offset)!
        lock.lock()
        requests.append(parsedOffset)
        let pageIndex = nextPage
        let page = pages[min(nextPage, pages.count - 1)]
        nextPage += 1
        lock.unlock()
        if pageIndex == blockedPage { releaseGate.wait() }

        let payload: JSONValue = .object([
            "messages": .array(page.rows),
            "pagination": .object([
                "limit": .integer(500),
                "offset": .integer(Int64(parsedOffset)),
                "order": .string("oldest"),
                "returned": .integer(Int64(page.returned))
            ])
        ])
        return (page.status, try! JSONEncoder().encode(payload))
    }

    func releaseBlockedPage() {
        releaseGate.signal()
    }
}

private final class PagingRegistry: @unchecked Sendable {
    static let shared = PagingRegistry()
    private let lock = NSLock()
    private var fixtures: [String: PagingFixture] = [:]

    func install(_ fixture: PagingFixture) {
        lock.lock(); defer { lock.unlock() }
        fixtures[fixture.id] = fixture
    }

    func remove(_ fixture: PagingFixture) {
        lock.lock(); defer { lock.unlock() }
        fixtures.removeValue(forKey: fixture.id)
    }

    func fixture(for request: URLRequest) -> PagingFixture? {
        guard let id = request.url?.path.split(separator: "/").dropLast().last else { return nil }
        lock.lock(); defer { lock.unlock() }
        return fixtures[String(id)]
    }
}

private final class PagingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.contains("/messages") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = PagingRegistry.shared.fixture(for: request) else {
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

    override func stopLoading() {
        PagingRegistry.shared.fixture(for: request)?.releaseBlockedPage()
    }
}

private func makePagingClient(
    pages: [PagingPage],
    blockedPage: Int? = nil
) throws -> (RestClient, PagingFixture, () -> Void) {
    let fixture = PagingFixture(pages: pages, blockedPage: blockedPage)
    PagingRegistry.shared.install(fixture)
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
    configuration.protocolClasses = [PagingURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let auth = AuthClient(server: server, urlSession: session)
    let client = RestClient(server: server, auth: auth, urlSession: session)
    return (client, fixture, {
        PagingRegistry.shared.remove(fixture)
        CredentialStore.delete(account: server.absoluteString)
    })
}

private func pagingIDs(_ rows: [JSONValue]) -> [Int64?] {
    rows.map { $0["id"]?.int64Value }
}

private func pagingRow(id: Int64) -> JSONValue {
    .object([
        "id": .integer(id),
        "role": .string("assistant"),
        "content": .string("row \(id)")
    ])
}
