import Foundation

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
}

public enum RestError: LocalizedError {
    case badStatus(Int, String)
    case messagePageLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .badStatus(let status, let body):
            "Request failed (HTTP \(status)): \(body)"
        case .messagePageLimitExceeded:
            "The transcript exceeded the maximum number of REST pages."
        }
    }
}

