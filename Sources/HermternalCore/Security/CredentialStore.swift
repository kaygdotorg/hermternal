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
    public enum StorageError: Error, Equatable {
        case applicationSupportDirectoryUnavailable
    }

    /// Returns the app-owned credential location under the platform's
    /// application-support directory. On macOS this preserves the existing
    /// `Application Support/Hermternal/credentials` location.
    public static func credentialsDirectory(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appending(path: "Hermternal/credentials", directoryHint: .isDirectory)
    }

    /// Resolves the platform's application-support directory without falling
    /// back to a home-directory path.
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        guard let applicationSupportDirectory = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        else {
            return nil
        }
        return credentialsDirectory(applicationSupportDirectory: applicationSupportDirectory)
    }

    private static func url(for account: String, directory: URL) -> URL {
        let slug = account.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        return directory.appending(path: "\(slug).json")
    }

    public static func save(_ credentials: Credentials, account: String, directory override: URL? = nil) throws {
        guard let directory = override ?? defaultDirectory() else {
            throw StorageError.applicationSupportDirectoryUnavailable
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(credentials)
        let target = url(for: account, directory: directory)
        try data.write(to: target, options: [.atomic])
        // .atomic replaces the file, so permissions must be applied after.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: target.path
        )
    }

    public static func load(account: String, directory override: URL? = nil) -> Credentials? {
        guard let directory = override ?? defaultDirectory() else { return nil }
        guard let data = try? Data(contentsOf: url(for: account, directory: directory)) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    public static func delete(account: String, directory override: URL? = nil) {
        guard let directory = override ?? defaultDirectory() else { return }
        try? FileManager.default.removeItem(at: url(for: account, directory: directory))
    }
}

