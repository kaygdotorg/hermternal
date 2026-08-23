import Foundation

/// The one destructive operation advertised by a gateway.
public struct SessionPurgeCapability: Codable, Equatable, Sendable {
    public let method: String
    public let path: String
    public let maxBatch: Int

    public init(method: String, path: String, maxBatch: Int) throws {
        guard method == "POST", path == "/api/sessions/purge", maxBatch > 0 else {
            throw GatewayCapabilityError.malformedSessionPurgeEndpoint
        }
        self.method = method
        self.path = path
        self.maxBatch = maxBatch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let method = try container.decode(String.self, forKey: .method)
        let path = try container.decode(String.self, forKey: .path)
        let maxBatch = try container.decode(Int.self, forKey: .maxBatch)
        try self.init(method: method, path: path, maxBatch: maxBatch)
    }

    private enum CodingKeys: String, CodingKey { case method, path, maxBatch = "max_batch" }
}

/// Typed snapshot of the gateway's optional capabilities endpoint.
public struct GatewayCapabilitiesSnapshot: Equatable, Sendable {
    public let sessionPurge: SessionPurgeCapability?
    public let unavailableReason: String?

    public init(sessionPurge: SessionPurgeCapability?, unavailableReason: String? = nil) {
        self.sessionPurge = sessionPurge
        self.unavailableReason = unavailableReason
    }

    public var sessionPurgeAvailable: Bool { sessionPurge != nil }
}

public enum GatewayCapabilityError: LocalizedError, Equatable, Sendable {
    case badStatus(Int)
    case malformedResponse
    case malformedSessionPurgeEndpoint
    case sessionPurgeNotAdvertised

    public var errorDescription: String? {
        switch self {
        case .badStatus(let status): "Capability discovery failed (HTTP \(status))."
        case .malformedResponse: "The gateway returned malformed capability data."
        case .malformedSessionPurgeEndpoint: "The gateway advertised an invalid session purge endpoint."
        case .sessionPurgeNotAdvertised: "Complete deletion is unavailable on this gateway."
        }
    }
}

/// Fetches capabilities once for each connected gateway/profile composition.
/// Results, including an unavailable result, are cached for the lifetime of the
/// module so views and callers never scatter network probes.
public actor GatewayCapabilityModule {
    private let server: URL
    private let auth: AuthClient
    private let urlSession: URLSession
    private let decoder = JSONDecoder()
    private var snapshots: [String: GatewayCapabilitiesSnapshot] = [:]

    public init(server: URL, auth: AuthClient, urlSession: URLSession = .shared) {
        self.server = server
        self.auth = auth
        self.urlSession = urlSession
    }

    public func snapshot(profile: String? = nil) async throws -> GatewayCapabilitiesSnapshot {
        let key = profile ?? ""
        if let cached = snapshots[key] { return cached }

        do {
            var credentials = try await auth.validCredentials()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await fetch(credentials: credentials, profile: profile)
            } catch {
                guard case GatewayCapabilityError.badStatus(401) = error else { throw error }
                credentials = try await auth.refreshCredentials()
                (data, response) = try await fetch(credentials: credentials, profile: profile)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else { throw GatewayCapabilityError.badStatus(status) }
            let result = try Self.decode(data: data)
            snapshots[key] = result
            return result
        } catch let error as GatewayCapabilityError {
            let result = GatewayCapabilitiesSnapshot(
                sessionPurge: nil,
                unavailableReason: error.localizedDescription
            )
            snapshots[key] = result
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let result = GatewayCapabilitiesSnapshot(
                sessionPurge: nil,
                unavailableReason: error.localizedDescription
            )
            snapshots[key] = result
            return result
        }
    }

    public static func decode(data: Data) throws -> GatewayCapabilitiesSnapshot {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let purge: SessionPurgeCapability?
        if decoded.features?.sessionPurge == true {
            guard let endpoint = decoded.endpoints?.sessionPurge else {
                throw GatewayCapabilityError.malformedResponse
            }
            purge = try SessionPurgeCapability(
                method: endpoint.method,
                path: endpoint.path,
                maxBatch: endpoint.maxBatch
            )
        } else {
            purge = nil
        }
        return GatewayCapabilitiesSnapshot(
            sessionPurge: purge,
            unavailableReason: purge == nil
                ? GatewayCapabilityError.sessionPurgeNotAdvertised.localizedDescription
                : nil
        )
    }

    private func fetch(credentials: Credentials, profile: String?) async throws -> (Data, URLResponse) {
        var components = URLComponents(
            url: server.appending(path: "v1/capabilities"),
            resolvingAgainstBaseURL: false
        )
        if let profile {
            components?.queryItems = [.init(name: "profile", value: profile)]
        }
        guard let url = components?.url else { throw AuthError.badServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status != 401 else { throw GatewayCapabilityError.badStatus(401) }
        return (data, response)
    }

    private struct Response: Decodable {
        let features: Features?
        let endpoints: Endpoints?
    }

    private struct Features: Decodable {
        let sessionPurge: Bool?
        enum CodingKeys: String, CodingKey { case sessionPurge = "session_purge" }
    }

    private struct Endpoints: Decodable {
        let sessionPurge: Endpoint?
        enum CodingKeys: String, CodingKey { case sessionPurge = "session_purge" }
    }

    private struct Endpoint: Decodable {
        let method: String
        let path: String
        let maxBatch: Int
        enum CodingKeys: String, CodingKey { case method, path, maxBatch = "max_batch" }
    }
}
