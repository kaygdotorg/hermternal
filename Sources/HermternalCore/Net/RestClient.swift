import Foundation

private final class TranscriptRowAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [JSONValue] = []

    func append(_ values: [JSONValue]) {
        lock.lock()
        rows.append(contentsOf: values)
        lock.unlock()
    }

    var value: [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }
}
/// Controls which archived durable sessions a session-list request returns.
public enum SessionArchiveFilter: String, Sendable {
    case exclude
    case include
    case only
}

/// One bounded page of durable transcript messages.
public struct TranscriptMessagePage: Sendable {
    public let messages: [JSONValue]
    public let returned: Int
    public let offset: Int
    public let serverTotal: Int?
    public let byteCount: Int
    public let hasMore: Bool

    public init(
        messages: [JSONValue],
        returned: Int? = nil,
        offset: Int,
        serverTotal: Int? = nil,
        byteCount: Int = 0,
        hasMore: Bool = false
    ) {
        self.messages = messages
        self.returned = returned ?? messages.count
        self.offset = offset
        self.serverTotal = serverTotal
        self.byteCount = byteCount
        self.hasMore = hasMore
    }
}

/// A bounded page callback. The callback is awaited before the next network
/// page is requested, providing back-pressure to a paged transcript store.
public typealias TranscriptMessagePageConsumer = @Sendable (TranscriptMessagePage) async throws -> Void

/// One page of durable dashboard sessions returned by the REST API.
public struct SessionListPage: Sendable {
    public let sessions: [JSONValue]
    public let total: Int
    public let limit: Int
    public let offset: Int
}

/// The exact confirmation value required by the destructive purge endpoint.
public enum SessionPurgeConfirmation {
    public static let requiredValue = "delete"

    public static func isExact(_ value: String) -> Bool {
        value == requiredValue
    }
}

public struct SessionPurgeRequest: Encodable, Equatable, Sendable {
    public let ids: [String]
    public let confirm: String

    public init(ids: [String], confirm: String = SessionPurgeConfirmation.requiredValue) {
        self.ids = ids
        self.confirm = confirm
    }
}

public struct SessionPurgeFailure: Decodable, Equatable, Sendable {
    public let id: String
    public let code: String
    public let message: String
    public init(id: String, code: String, message: String) {
        self.id = id
        self.code = code
        self.message = message
    }
}

public struct SessionPurgeResult: Decodable, Equatable, Sendable {
    public let object: String
    public let complete: Bool
    public let purged: [String]
    public let retainedBranches: [String]
    public let failed: [SessionPurgeFailure]

    public var successfulIDs: Set<String> { Set(purged) }

    enum CodingKeys: String, CodingKey {
        case object
        case complete
        case purged
        case retainedBranches = "retained_branches"
        case failed
    }
    public init(
        object: String,
        complete: Bool,
        purged: [String],
        retainedBranches: [String],
        failed: [SessionPurgeFailure]
    ) {
        self.object = object
        self.complete = complete
        self.purged = purged
        self.retainedBranches = retainedBranches
        self.failed = failed
    }

}


/// Authenticated REST calls against the dashboard.
///
/// Used for read-only transcript hydration. `session.resume` over the socket
/// registers a *live* server-side session, so warming 30+ chats through it
/// would spin up 30+ live agents. `GET /api/sessions/{id}/messages` opens the
/// session database read-only and creates nothing, which is what makes
/// prefetching safe.
public actor RestClient {
    private let server: URL
    private let auth: AuthClient
    private let urlSession: URLSession
    /// One decoder per client. `fetchMessagePage` runs inside a loop bounded at
    /// 100 pages, so a per-call decoder allocated up to 100 strategy caches for
    /// a single transcript open.
    private let responseDecoder = JSONDecoder()

    /// The server caps each request at 500 rows. One hundred pages bounds a
    /// malformed or adversarial session at 50,000 rows instead of allowing an
    /// endless loop when pagination never reports a short page.
    public static let maximumMessagePages = 100
    /// One hundred pages bound a malformed session list at 10,000 rows and
    /// prevents an endless loop when pinned rows repeat forever.
    public static let maximumSessionPages = 100

    public init(server: URL, auth: AuthClient, urlSession: URLSession = .shared) {
        self.server = server
        self.auth = auth
        self.urlSession = urlSession
    }

    /// Delivers durable transcript pages oldest-first. The consumer is awaited
    /// before the next page is requested, so callers can apply explicit
    /// memory admission and persist records without an accumulating stream.
    public func streamSessionMessages(
        durableID: String,
        limit: Int = 500,
        maximumPageBytes: Int = TranscriptPageRequest.hardMaximumBytes,
        onPage: @escaping TranscriptMessagePageConsumer
    ) async throws -> TranscriptSummary {
        let pageLimit = min(max(limit, 1), 500)
        let byteLimit = max(1, min(maximumPageBytes, TranscriptPageRequest.hardMaximumBytes))
        var credentials = try await auth.validCredentials()
        var hasRefreshedAfterUnauthorized = false
        var offset = 0
        var messageCount = 0

        for _ in 0..<Self.maximumMessagePages {
            try Task.checkCancellation()
            let page: MessagesResponse
            let bytes: Int
            do {
                let fetched = try await fetchMessagePage(
                    durableID: durableID,
                    limit: pageLimit,
                    offset: offset,
                    credentials: credentials,
                    maximumBytes: byteLimit
                )
                page = fetched.response
                bytes = fetched.byteCount
            } catch {
                guard case RestError.badStatus(let status, _) = error,
                      status == 401,
                      !hasRefreshedAfterUnauthorized
                else { throw error }
                hasRefreshedAfterUnauthorized = true
                credentials = try await auth.refreshCredentials()
                let fetched = try await fetchMessagePage(
                    durableID: durableID,
                    limit: pageLimit,
                    offset: offset,
                    credentials: credentials,
                    maximumBytes: byteLimit
                )
                page = fetched.response
                bytes = fetched.byteCount
            }
            try Task.checkCancellation()
            let returned = page.pagination?.returned ?? page.messages.count
            let total = page.pagination?.total
            let hasMore = returned >= pageLimit
            try await onPage(TranscriptMessagePage(
                messages: page.messages,
                returned: returned,
                offset: offset,
                serverTotal: total,
                byteCount: bytes,
                hasMore: hasMore
            ))
            messageCount += page.messages.count
            if !hasMore {
                return TranscriptSummary(
                    rowCount: messageCount,
                    messageCount: messageCount,
                    countKind: .exact,
                    generation: 0,
                    epoch: 0
                )
            }
            offset += pageLimit
        }
        throw RestError.messagePageLimitExceeded
    }

    public func sessionMessages(durableID: String, limit: Int = 500) async throws -> [JSONValue] {
        let accumulator = TranscriptRowAccumulator()
        _ = try await streamSessionMessages(durableID: durableID, limit: limit) { page in
            try Task.checkCancellation()
            accumulator.append(page.messages)
        }
        return accumulator.value
    }

    private func fetchMessagePage(
        durableID: String,
        limit: Int,
        offset: Int,
        credentials: Credentials,
        maximumBytes: Int
    ) async throws -> (response: MessagesResponse, byteCount: Int) {
        var components = URLComponents(
            url: server.appending(path: "api/sessions/\(durableID)/messages"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            .init(name: "limit", value: String(limit)),
            .init(name: "offset", value: String(offset)),
            .init(name: "order", value: "oldest")
        ]
        guard let url = components?.url else { throw AuthError.badServerURL }

        var request = URLRequest(url: url)
        request.setValue(
            "Bearer \(credentials.accessToken)",
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw RestError.badStatus(
                status,
                String(decoding: data.prefix(512), as: UTF8.self)
            )
        }
        // A single provider token can exceed the in-memory page admission.
        // Spool that response before decoding rather than rejecting valid
        // history; the callback still applies back-pressure one page at a time.
        if data.count > maximumBytes {
            let spool = FileManager.default.temporaryDirectory
                .appendingPathComponent("hermternal-transcript-\(UUID().uuidString).json")
            try data.write(to: spool, options: [.atomic])
            defer { try? FileManager.default.removeItem(at: spool) }
            try Task.checkCancellation()
            let spooled = try Data(contentsOf: spool)
            return (try responseDecoder.decode(MessagesResponse.self, from: spooled), spooled.count)
        }
        return (try responseDecoder.decode(MessagesResponse.self, from: data), data.count)
    }

    private struct MessagesResponse: Decodable {
        let messages: [JSONValue]
        let pagination: Pagination?
    }

    private struct Pagination: Decodable {
        let returned: Int?
        let total: Int?
    }

    /// Lists durable dashboard sessions without opening or resuming live sessions.
    ///
    /// The server appends every matching pinned row to every page, ignoring
    /// `limit` and `offset`, ordered by `started_at DESC`. Pinned rows therefore
    /// repeat across pages, and `total` does not count them. Any caller that
    /// pages MUST de-duplicate by `id`.
    public func sessionList(
        limit: Int = 100,
        offset: Int = 0,
        order: String = "recent",
        archived: SessionArchiveFilter = .exclude,
        excludeSources: [String] = [],
        profile: String? = nil
    ) async throws -> SessionListPage {
        var credentials = try await auth.validCredentials()
        // The server clamps limit to 100 and rejects a negative offset with 422,
        // so both are clamped here rather than sending a request that cannot succeed.
        let pageLimit = min(max(limit, 1), 100)
        let pageOffset = max(offset, 0)

        do {
            return try await fetchSessionListPage(
                limit: pageLimit,
                offset: pageOffset,
                order: order,
                archived: archived,
                excludeSources: excludeSources,
                profile: profile,
                credentials: credentials
            )
        } catch {
            guard case RestError.badStatus(let status, _) = error, status == 401 else {
                throw error
            }
            credentials = try await auth.refreshCredentials()
            return try await fetchSessionListPage(
                limit: pageLimit,
                offset: pageOffset,
                order: order,
                archived: archived,
                excludeSources: excludeSources,
                profile: profile,
                credentials: credentials
            )
        }
    }

    /// Returns the complete durable session list, de-duplicated by id.
    ///
    /// Pinned rows repeat on every REST page, so `total` and a short page are
    /// not completion signals. A page that adds no new id is the only reliable
    /// stopping condition. The offset always advances by the requested page
    /// size, not by the number of newly added rows.
    public func allSessions(
        order: String = "recent",
        archived: SessionArchiveFilter = .exclude,
        excludeSources: [String] = [],
        profile: String? = nil
    ) async throws -> [JSONValue] {
        let pageLimit = 100
        var offset = 0
        var rows: [JSONValue] = []
        var ids = Set<String>()
        rows.reserveCapacity(pageLimit)

        for _ in 0..<Self.maximumSessionPages {
            try Task.checkCancellation()
            let page = try await sessionList(
                limit: pageLimit,
                offset: offset,
                order: order,
                archived: archived,
                excludeSources: excludeSources,
                profile: profile
            )
            var added = 0
            for row in page.sessions {
                guard let id = row["id"]?.stringValue, ids.insert(id).inserted else {
                    continue
                }
                rows.append(row)
                added += 1
            }
            guard added > 0 else { return rows }
            offset += pageLimit
        }

        throw RestError.sessionPageLimitExceeded
    }

    /// Permanently removes application state through the advertised REST
    /// endpoint. There is intentionally no DELETE or WebSocket fallback.
    public func purgeSessions(
        ids: [String],
        capability: SessionPurgeCapability,
        profile: String? = nil,
        confirmation: String = SessionPurgeConfirmation.requiredValue
    ) async throws -> SessionPurgeResult {
        var seen = Set<String>()
        let uniqueIDs = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !uniqueIDs.isEmpty else { throw RestError.purgeEmptyIDs }
        guard uniqueIDs.count <= capability.maxBatch else {
            throw RestError.purgeBatchTooLarge(max: capability.maxBatch)
        }
        guard SessionPurgeConfirmation.isExact(confirmation) else {
            throw RestError.purgeInvalidConfirmation
        }
        guard capability.method == "POST", capability.path == "/api/sessions/purge" else {
            throw RestError.purgeUnsupportedEndpoint
        }

        let body = try Self.bodyEncoder.encode(
            SessionPurgeRequest(ids: uniqueIDs, confirm: confirmation)
        )
        var credentials = try await auth.validCredentials()
        do {
            return try await fetchPurge(
                body: body,
                path: capability.path,
                profile: profile,
                credentials: credentials
            )
        } catch {
            guard case RestError.purgeHTTPError(let status) = error, status == 401 else {
                throw error
            }
            credentials = try await auth.refreshCredentials()
            return try await fetchPurge(
                body: body,
                path: capability.path,
                profile: profile,
                credentials: credentials
            )
        }
    }

    private func fetchPurge(
        body: Data,
        path: String,
        profile: String?,
        credentials: Credentials
    ) async throws -> SessionPurgeResult {
        var components = URLComponents(
            url: server.appending(path: String(path.dropFirst(path.hasPrefix("/") ? 1 : 0))),
            resolvingAgainstBaseURL: false
        )
        if let profile {
            components?.queryItems = [.init(name: "profile", value: profile)]
        }
        guard let url = components?.url else { throw AuthError.badServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        do {
            let result = try responseDecoder.decode(SessionPurgeResult.self, from: data)
            guard result.object == "hermes.session.purge_result" else {
                throw RestError.purgeMalformedResponse
            }
            // The gateway uses 409/500 for incomplete typed results, so keep
            // the per-id failures instead of discarding the response.
            return result
        } catch let error as RestError {
            throw error
        } catch {
            guard status == 200 else { throw RestError.purgeHTTPError(status) }
            throw RestError.purgeMalformedResponse
        }
    }

    /// Updates a durable session by id without needing a live session or resume.
    ///
    /// This endpoint takes the DURABLE session id, needs no live session and no
    /// resume. A title written here records `user` provenance so later
    /// automatic titling cannot overwrite it.
    public func patchSession(
        durableID: String,
        title: String? = nil,
        pinned: Bool? = nil,
        archived: Bool? = nil,
        profile: String? = nil
    ) async throws -> JSONValue {
        guard title != nil || pinned != nil || archived != nil else {
            throw RestError.noMutableFields
        }

        var body: [String: JSONValue] = [:]
        if let title {
            body["title"] = .string(title)
        }
        if let pinned {
            body["pinned"] = .bool(pinned)
        }
        if let archived {
            body["archived"] = .bool(archived)
        }
        // The server routes the write to a profile's own database, so a session
        // that belongs to a named profile must carry it or the write lands in
        // the default database.
        if let profile {
            body["profile"] = .string(profile)
        }
        let encodedBody = try Self.bodyEncoder.encode(JSONValue.object(body))

        var credentials = try await auth.validCredentials()
        do {
            return try await fetchPatchedSession(
                durableID: durableID,
                body: encodedBody,
                credentials: credentials
            )
        } catch {
            guard case RestError.badStatus(let status, _) = error, status == 401 else {
                throw error
            }
            credentials = try await auth.refreshCredentials()
            return try await fetchPatchedSession(
                durableID: durableID,
                body: encodedBody,
                credentials: credentials
            )
        }
    }

    private static let bodyEncoder = JSONEncoder()

    private func fetchSessionListPage(
        limit: Int,
        offset: Int,
        order: String,
        archived: SessionArchiveFilter,
        excludeSources: [String],
        profile: String?,
        credentials: Credentials
    ) async throws -> SessionListPage {
        var components = URLComponents(
            url: server.appending(path: "api/sessions"),
            resolvingAgainstBaseURL: false
        )
        var queryItems: [URLQueryItem] = [
            .init(name: "limit", value: String(limit)),
            .init(name: "offset", value: String(offset)),
            .init(name: "order", value: order),
            .init(name: "archived", value: archived.rawValue)
        ]
        // Filtering here means the server never sends a row the sidebar would
        // discard. Subagent rows outnumber real chats several times over, so
        // dropping them client-side would waste transfer and mapping work.
        if !excludeSources.isEmpty {
            queryItems.append(
                .init(name: "exclude_sources", value: excludeSources.joined(separator: ","))
            )
        }
        if let profile {
            queryItems.append(.init(name: "profile", value: profile))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw AuthError.badServerURL }

        var request = URLRequest(url: url)
        request.setValue(
            "Bearer \(credentials.accessToken)",
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw RestError.badStatus(
                status,
                String(decoding: data.prefix(512), as: UTF8.self)
            )
        }

        let envelope = try responseDecoder.decode(SessionListResponse.self, from: data)
        return SessionListPage(
            sessions: envelope.sessions,
            total: envelope.total ?? envelope.sessions.count,
            limit: envelope.limit,
            offset: envelope.offset
        )
    }

    private func fetchPatchedSession(
        durableID: String,
        body: Data,
        credentials: Credentials
    ) async throws -> JSONValue {
        let url = server.appending(path: "api/sessions/\(durableID)")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(
            "Bearer \(credentials.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 404 {
            throw RestError.sessionNotFound
        }
        guard status == 200 else {
            throw RestError.badStatus(
                status,
                String(decoding: data.prefix(512), as: UTF8.self)
            )
        }
        return try responseDecoder.decode(JSONValue.self, from: data)
    }

    private struct SessionListResponse: Decodable {
        let sessions: [JSONValue]
        let total: Int?
        let limit: Int
        let offset: Int
    }

}

public enum RestError: LocalizedError, Sendable {
    case badStatus(Int, String)
    case messagePageLimitExceeded
    case messagePageTooLarge(maxBytes: Int)
    case sessionPageLimitExceeded
    case noMutableFields
    case sessionNotFound
    case purgeEmptyIDs
    case purgeBatchTooLarge(max: Int)
    case purgeInvalidConfirmation
    case purgeUnsupportedEndpoint
    case purgeHTTPError(Int)
    case purgeMalformedResponse

    public var errorDescription: String? {
        switch self {
        case .badStatus(let status, let body):
            "Request failed (HTTP \(status)): \(body)"
        case .messagePageLimitExceeded:
            "The transcript exceeded the maximum number of REST pages."
        case .messagePageTooLarge(let maxBytes):
            "The transcript page exceeded the \(maxBytes)-byte admission limit."
        case .sessionPageLimitExceeded:
            "The session list exceeded the maximum number of REST pages."
        case .noMutableFields:
            "At least one mutable session field must be supplied."
        case .sessionNotFound:
            "The durable session does not exist."
        case .purgeEmptyIDs:
            "At least one chat must be selected."
        case .purgeBatchTooLarge(let max):
            "The gateway accepts at most \(max) chats per deletion request."
        case .purgeInvalidConfirmation:
            "Type delete exactly to confirm permanent deletion."
        case .purgeUnsupportedEndpoint:
            "Complete deletion is unavailable on this gateway."
        case .purgeHTTPError(let status):
            "Permanent deletion failed (HTTP \(status))."
        case .purgeMalformedResponse:
            "The gateway returned an invalid permanent deletion result."
        }
    }
}

