import Foundation

/// The bearer credential set the gateway hands back at
/// `POST /auth/native/token`.
public struct Credentials: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    /// Absolute Unix expiry of `accessToken`, as reported by the gateway.
    public var expiresAt: Int
    public var provider: String
    public var userID: String

    public func isExpired(skew: TimeInterval = 60) -> Bool {
        Date().timeIntervalSince1970 + skew >= Double(expiresAt)
    }
}

/// Owner-only on-disk credential store, keyed by server origin.
///
/// This deliberately does **not** use the Keychain. A generic-password item's
/// ACL is bound to the signing identity of the binary that created it, and an
/// ad-hoc signature (`codesign --sign -`) gets a fresh cdhash on every build.
/// So every rebuild invalidated the "Always Allow" grant and re-prompted —
/// the Keychain cannot hold a stable grant for an ad-hoc binary.
///
/// Tradeoff, stated plainly: a `0600` file is readable by any process running
/// as this user, whereas an approved Keychain item is readable only by the
/// approved binary. Acceptable for an unsigned development build holding a
/// short-lived access token, and it is the reason `Scripts/build-app.sh`
/// prefers a real codesigning identity when one is installed. Once a Developer
/// ID certificate exists, the ACL becomes stable and this should move back to
/// the Keychain.
public enum CredentialStore {
    /// `~/Library/Application Support/Hermternal/credentials/`
    private static var directory: URL {
        let base = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Hermternal/credentials", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return base
    }

    /// Origin-derived filename so pointing the app at another instance does
    /// not clobber the previous instance's tokens.
    private static func url(for account: String) -> URL {
        let slug = account.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        return directory.appending(path: "\(slug).json")
    }

    static func save(_ credentials: Credentials, account: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let target = url(for: account)
        try data.write(to: target, options: [.atomic])
        // .atomic replaces the file, so permissions must be applied after.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: target.path
        )
    }

    static func load(account: String) -> Credentials? {
        guard let data = try? Data(contentsOf: url(for: account)) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func delete(account: String) {
        try? FileManager.default.removeItem(at: url(for: account))
    }
}
