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

    public init(server: URL, auth: AuthClient, urlSession: URLSession = .shared) {
        self.server = server
        self.auth = auth
        self.urlSession = urlSession
    }

    /// Persisted transcript rows for a durable session id.
    ///
    /// Rows come straight from the database, so they carry `content` rather
    /// than the socket projection's `text`, and include scaffolding the
    /// socket path filters out.
    public func sessionMessages(durableID: String, limit: Int = 500) async throws -> [JSONValue] {
        let credentials = try await auth.validCredentials()

        var components = URLComponents(
            url: server.appending(path: "api/sessions/\(durableID)/messages"),
            resolvingAgainstBaseURL: false
        )
        // The endpoint clamps to 500 per page regardless.
        components?.queryItems = [.init(name: "limit", value: String(limit))]
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
        return try JSONDecoder().decode(MessagesResponse.self, from: data).messages
    }

    private struct MessagesResponse: Decodable {
        let messages: [JSONValue]
    }
}

public enum RestError: LocalizedError {
    case badStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let status, let body):
            "Request failed (HTTP \(status)): \(body)"
        }
    }
}
