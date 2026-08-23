import Foundation

/// One page of durable dashboard sessions returned by the REST API.
public struct SessionListPage: Sendable {
    public let sessions: [JSONValue]
    public let total: Int
    public let limit: Int
    public let offset: Int
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

    /// The server caps each request at 500 rows. One hundred pages bounds a
    /// malformed or adversarial session at 50,000 rows instead of allowing an
    /// endless loop when pagination never reports a short page.
    public static let maximumMessagePages = 100

    public init(server: URL, auth: AuthClient, urlSession: URLSession = .shared) {
        self.server = server
        self.auth = auth
        self.urlSession = urlSession
    }

    /// All persisted transcript rows for a durable session id, in server order.
    ///
    /// The endpoint hard-clamps `limit` to 500. Pages are requested oldest
    /// first and concatenated without sorting so the database's stable order
    /// is preserved.
    public func sessionMessages(durableID: String, limit: Int = 500) async throws -> [JSONValue] {
        var credentials = try await auth.validCredentials()
        var hasRefreshedAfterUnauthorized = false
        let pageLimit = min(max(limit, 1), 500)
        var rows: [JSONValue] = []
        rows.reserveCapacity(pageLimit)
        var offset = 0

        // A full page is not proof of completion: the API exposes no total or
        // has-more flag, so an exact multiple of 500 pays one empty probe.
        // TranscriptOpener's AsyncStream onTermination cancels this task, so
        // these checks stop paging when navigation supersedes an open.
        for _ in 0..<Self.maximumMessagePages {
            try Task.checkCancellation()
            let page: MessagesResponse
            do {
                page = try await fetchMessagePage(
                    durableID: durableID,
                    limit: pageLimit,
                    offset: offset,
                    credentials: credentials
                )
            } catch {
                guard case RestError.badStatus(let status, _) = error,
                      status == 401,
                      hasRefreshedAfterUnauthorized == false
                else {
                    throw error
                }
                hasRefreshedAfterUnauthorized = true
                // The local expiry can lag server-side revocation. Refresh
                // once, then retry this page with the new bearer; a refresh
                // failure is sessionExpired and escapes without a loop.
                credentials = try await auth.refreshCredentials()
                page = try await fetchMessagePage(
                    durableID: durableID,
                    limit: pageLimit,
                    offset: offset,
                    credentials: credentials
                )
            }
            try Task.checkCancellation()
            rows.append(contentsOf: page.messages)

            let returned = page.pagination?.returned ?? page.messages.count
            if returned < pageLimit {
                return rows
            }
            offset += pageLimit
        }

        throw RestError.messagePageLimitExceeded
    }

    private func fetchMessagePage(
        durableID: String,
        limit: Int,
        offset: Int,
        credentials: Credentials
    ) async throws -> MessagesResponse {
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
        return try JSONDecoder().decode(MessagesResponse.self, from: data)
    }

    private struct MessagesResponse: Decodable {
        let messages: [JSONValue]
        let pagination: Pagination?
    }

    private struct Pagination: Decodable {
        let returned: Int?
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
        archived: String = "exclude",
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
                profile: profile,
                credentials: credentials
            )
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
        archived: String,
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
            .init(name: "archived", value: archived)
        ]
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

        let envelope = try JSONDecoder().decode(SessionListResponse.self, from: data)
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
        return try JSONDecoder().decode(JSONValue.self, from: data)
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
    case noMutableFields
    case sessionNotFound

    public var errorDescription: String? {
        switch self {
        case .badStatus(let status, let body):
            "Request failed (HTTP \(status)): \(body)"
        case .messagePageLimitExceeded:
            "The transcript exceeded the maximum number of REST pages."
        case .noMutableFields:
            "At least one mutable session field must be supplied."
        case .sessionNotFound:
            "The durable session does not exist."
        }
    }
}

