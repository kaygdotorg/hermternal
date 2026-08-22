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

/// The account label and optional secondary detail rendered by composition.
///
/// `accountID` remains available for an accessibility label or tooltip when
/// the visible title is the intentionally truncated account identifier.
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
    /// Resolves the account label in priority order:
    /// display name, email, truncated account ID, provider display name,
    /// gateway host, then the configured URL.
    ///
    /// Empty or whitespace-only values are treated as absent. The account ID
    /// is deliberately presented as an account label, never as a person's
    /// name. Hermes's web widget truncates IDs after 14 characters; matching
    /// that rule keeps both surfaces recognizable while `accountID` retains
    /// the complete value for a tooltip.
    public static func resolve(
        identity: AccountIdentity?,
        provider: AuthProvider?,
        gateway: URL
    ) -> AccountIdentityPresentation {
        let displayName = nonEmpty(identity?.displayName)
        let email = nonEmpty(identity?.email)
        let userID = nonEmpty(identity?.userID)
        let organizationID = nonEmpty(identity?.orgID)
        let providerName = nonEmpty(provider?.displayName)
        let host = nonEmpty(gateway.host)
        let configuredURL = nonEmpty(gateway.absoluteString) ?? gateway.absoluteString

        if let displayName {
            return AccountIdentityPresentation(
                title: displayName,
                detail: email ?? organizationID,
                accountID: userID
            )
        }
        if let email {
            return AccountIdentityPresentation(
                title: email,
                detail: organizationID,
                accountID: userID
            )
        }
        if let userID {
            return AccountIdentityPresentation(
                title: truncateAccountID(userID),
                detail: organizationID,
                accountID: userID
            )
        }
        if let providerName {
            return AccountIdentityPresentation(title: providerName, detail: organizationID)
        }
        if let host {
            return AccountIdentityPresentation(title: host, detail: configuredURL == host ? nil : configuredURL)
        }
        return AccountIdentityPresentation(title: configuredURL)
    }

    /// Hermes's web widget returns the first 14 characters and a horizontal
    /// ellipsis for longer IDs.
    public static func truncateAccountID(_ userID: String) -> String {
        guard userID.count > 14 else { return userID }
        return String(userID.prefix(14)) + "…"
    }

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
