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

@Test("REST paging delivers bounded pages to an awaited consumer")
func restPagingStreamsPagesWithBackpressure() async throws {
    let rows = (0..<556).map { pagingRow(id: Int64($0)) }
    let pages = [
        PagingPage(rows: Array(rows.prefix(500)), returned: 500),
        PagingPage(rows: Array(rows.dropFirst(500)), returned: 56)
    ]
    let (client, fixture, cleanup) = try makePagingClient(pages: pages)
    defer { cleanup() }
    let collector = StreamPageCollector()
    let summary = try await client.streamSessionMessages(durableID: fixture.id) { page in
        await collector.append(page)
    }
    #expect(await collector.ids == pagingIDs(rows))
    #expect(await collector.maximumPageRows <= 500)
    #expect(summary.messageCount == 556)
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
    let deadline = ContinuousClock.now + .seconds(15)
    while !fixture.isBlockedPageWaiting {
        guard ContinuousClock.now < deadline else {
            Issue.record("blocked page never started loading")
            task.cancel()
            fixture.releaseBlockedPage()
            return
        }
        try await Task.sleep(for: .milliseconds(5))
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
        case .badStatus, .messagePageTooLarge, .sessionPageLimitExceeded, .noMutableFields,
             .sessionNotFound,
             .purgeEmptyIDs, .purgeBatchTooLarge, .purgeInvalidConfirmation,
             .purgeUnsupportedEndpoint, .purgeHTTPError, .purgeMalformedResponse:
            Issue.record("unexpected REST error: \(error)")
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(fixture.offsets.count == RestClient.maximumMessagePages)
    #expect(fixture.offsets.last == (RestClient.maximumMessagePages - 1) * 500)
}

private actor StreamPageCollector {
    private(set) var ids: [Int64?] = []
    private(set) var maximumPageRows = 0

    func append(_ page: TranscriptMessagePage) {
        ids.append(contentsOf: pagingIDs(page.messages))
        maximumPageRows = max(maximumPageRows, page.messages.count)
    }
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

private struct PagingParkedLoad {
    let proto: PagingURLProtocol
    let client: URLProtocolClient
    let offset: Int
}

private final class PagingFixture: @unchecked Sendable {
    let id: String
    private let pages: [PagingPage]
    private let blockedPage: Int?
    private let lock = NSLock()
    private var requests: [Int] = []
    private var nextPage = 0
    private var blockedPageIsWaiting = false
    private var parkedLoad: PagingParkedLoad?

    init(pages: [PagingPage], blockedPage: Int? = nil) {
        self.id = UUID().uuidString
        self.pages = pages
        self.blockedPage = blockedPage
    }

    var offsets: [Int] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    var isBlockedPageWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        return blockedPageIsWaiting
    }

    enum StartResult {
        case park
        case complete(Int, Data)
    }

    func start(
        _ proto: PagingURLProtocol,
        client: URLProtocolClient,
        request: URLRequest
    ) -> StartResult {
        let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "offset" }!.value!
        let parsedOffset = Int(offset)!
        lock.lock()
        requests.append(parsedOffset)
        let pageIndex = nextPage
        let page = pages[min(nextPage, pages.count - 1)]
        nextPage += 1
        if pageIndex == blockedPage {
            blockedPageIsWaiting = true
            parkedLoad = PagingParkedLoad(proto: proto, client: client, offset: parsedOffset)
            lock.unlock()
            return .park
        }
        lock.unlock()
        return .complete(page.status, Self.payload(page: page, offset: parsedOffset))
    }

    func releaseBlockedPage() {
        failParkedLoad(matching: nil)
    }

    func releaseBlockedPage(for request: URLRequest) {
        guard let offsetValue = URLComponents(
            url: request.url!,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "offset" })?.value,
        let offset = Int(offsetValue)
        else {
            return
        }
        failParkedLoad(matching: offset)
    }

    private func failParkedLoad(matching offset: Int?) {
        lock.lock()
        guard blockedPageIsWaiting,
              let parked = parkedLoad,
              offset == nil || parked.offset == offset
        else {
            lock.unlock()
            return
        }
        parkedLoad = nil
        blockedPageIsWaiting = false
        lock.unlock()
        parked.client.urlProtocol(parked.proto, didFailWithError: URLError(.cancelled))
    }

    private static func payload(page: PagingPage, offset: Int) -> Data {
        let body: JSONValue = .object([
            "messages": .array(page.rows),
            "pagination": .object([
                "limit": .integer(500),
                "offset": .integer(Int64(offset)),
                "order": .string("oldest"),
                "returned": .integer(Int64(page.returned))
            ])
        ])
        return try! JSONEncoder().encode(body)
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
        guard let protocolClient = client else { return }
        guard let fixture = PagingRegistry.shared.fixture(for: request) else {
            protocolClient.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        switch fixture.start(self, client: protocolClient, request: request) {
        case .park:
            return
        case let .complete(status, data):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            protocolClient.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolClient.urlProtocol(self, didLoad: data)
            protocolClient.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        PagingRegistry.shared.fixture(for: request)?.releaseBlockedPage(for: request)
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
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = 5
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
