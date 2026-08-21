import Foundation
import Security

/// The bearer credential set the gateway hands back at
/// `POST /auth/native/token`.
struct Credentials: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    /// Absolute Unix expiry of `accessToken`, as reported by the gateway.
    var expiresAt: Int
    var provider: String
    var userID: String

    /// Treat a token inside the skew window as already dead so a request
    /// can't lose a race against expiry mid-flight.
    func isExpired(skew: TimeInterval = 60) -> Bool {
        Date().timeIntervalSince1970 + skew >= Double(expiresAt)
    }
}

/// Generic-password Keychain store for the signed-in session.
///
/// Keyed by server origin so pointing the app at a different Hermes
/// instance does not clobber the previous instance's tokens.
enum Keychain {
    private static let service = "com.tavyg.hermternal.credentials"

    static func save(_ credentials: Credentials, account: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Tokens are only needed while the user is active; this keeps
            // them off the device before first unlock.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query.merging(attributes) { $1 }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status)
        }
    }

    static func load(account: String) -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain error \(status): \(detail)"
    }
}
