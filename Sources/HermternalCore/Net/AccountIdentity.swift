import Foundation

/// The authenticated account returned by `GET /api/auth/me`.
///
/// Gateways may omit fields or return empty strings (notably the self-hosted
/// provider), so every server field is optional. `userID` identifies the
/// account, but is not itself a human name.
public struct AccountIdentity: Codable, Equatable, Sendable {
    public let userID: String?
    public let email: String?
    public let displayName: String?
    public let orgID: String?
    public let provider: String?
    public let expiresAt: Int?

    public init(
        userID: String? = nil,
        email: String? = nil,
        displayName: String? = nil,
        orgID: String? = nil,
        provider: String? = nil,
        expiresAt: Int? = nil
    ) {
        self.userID = userID
        self.email = email
        self.displayName = displayName
        self.orgID = orgID
        self.provider = provider
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case email
        case displayName = "display_name"
        case orgID = "org_id"
        case provider
        case expiresAt = "expires_at"
    }
}

/// The identity at the foot of the sidebar: the gateway, and the account.
///
/// `title` is the gateway. A person needs the gateway to tell two windows
/// apart when each window uses a different backend. `detail` is the
/// human-readable account name, if the gateway supplies one. `accountID` is
/// available for a tooltip and for an accessibility label. `accountID` never
/// takes a visible line, because an opaque identifier is not a name.
public struct AccountIdentityPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String?
    public let accountID: String?

    public init(title: String, detail: String? = nil, accountID: String? = nil) {
        self.title = title
        self.detail = detail
        self.accountID = accountID
    }
}

/// Pure account-label resolution shared by platform compositions.
public enum AccountIdentityResolver {
    /// Resolves the sidebar identity. The gateway is first. A human-readable
    /// account name is second.
    ///
    /// Empty values and whitespace-only values are absent. The gateway label
    /// contains a host and an explicit port only. It never contains a scheme,
    /// a path, a query, or credentials. If the configuration gives no host,
    /// the label is the account name, then the provider name. The label is
    /// never the complete URL.
    public static func resolve(
        identity: AccountIdentity?,
        provider: AuthProvider?,
        gateway: URL
    ) -> AccountIdentityPresentation {
        let userID = nonEmpty(identity?.userID)
        // The order in which a person recognizes an account. The account ID
        // is not in this chain, because an identifier is not a name.
        let accountName = nonEmpty(identity?.displayName)
            ?? nonEmpty(identity?.email)
            ?? nonEmpty(identity?.orgID)

        if let gatewayName = gatewayLabel(for: gateway) {
            return AccountIdentityPresentation(
                title: gatewayName,
                detail: accountName,
                accountID: userID
            )
        }
        if let accountName {
            return AccountIdentityPresentation(title: accountName, accountID: userID)
        }
        return AccountIdentityPresentation(
            title: nonEmpty(provider?.displayName) ?? Self.unnamedGateway,
            accountID: userID
        )
    }

    /// The gateway host, and the port if the URL gives one.
    ///
    /// The result is absent if the URL has no authority component. Such a URL
    /// is a misconfiguration. Its path can also contain a token, and this
    /// function must not show a token.
    public static func gatewayLabel(for gateway: URL) -> String? {
        guard let host = nonEmpty(gateway.host(percentEncoded: false)) else {
            return nil
        }
        // Foundation removes the brackets from an IPv6 literal. Without the
        // brackets, a reader cannot tell the address from the port.
        let authority = host.contains(":") ? "[\(host)]" : host
        guard let port = gateway.port else { return authority }
        return "\(authority):\(port)"
    }

    /// Used only if the configuration gives no host and the account has no
    /// name. Every other value would show a URL or an opaque identifier.
    public static let unnamedGateway = "No gateway"

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A single-use WebSocket upgrade ticket and the gateway's advertised
/// lifetime. The lifetime is informational today; composition may use it to
/// plan a reconnect or refresh before the ticket expires.
public struct WebSocketTicket: Codable, Equatable, Sendable {
    public let ticket: String
    public let ttlSeconds: Int?

    public init(ticket: String, ttlSeconds: Int? = nil) {
        self.ticket = ticket
        self.ttlSeconds = ttlSeconds
    }

    enum CodingKeys: String, CodingKey {
        case ticket
        case ttlSeconds = "ttl_seconds"
    }
}
