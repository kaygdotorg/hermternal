import Foundation

/// The bearer credential set the gateway hands back at
/// `POST /auth/native/token`.
public struct Credentials: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Absolute Unix expiry of `accessToken`, as reported by the gateway.
    public var expiresAt: Int
    public var provider: String
    public var userID: String

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Int,
        provider: String,
        userID: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.provider = provider
        self.userID = userID
    }

    public func isExpired(skew: TimeInterval = 60) -> Bool {
        Date().timeIntervalSince1970 + skew >= Double(expiresAt)
    }
}

/// Storage capability used by authentication. Implementations are selected at
/// composition time; the protocol deliberately keeps the existing operations.
public protocol CredentialStoring: Sendable {
    func save(_ credentials: Credentials, account: String) throws
    func load(account: String) throws -> Credentials?
    func delete(account: String) throws
}

/// Owner-only on-disk credential store for unsigned and ad-hoc builds.
public struct FileCredentialStore: CredentialStoring, Sendable {
    public enum StorageError: Error, Equatable {
        case applicationSupportDirectoryUnavailable
    }

    private let directory: URL?

    public init(directory: URL? = nil) {
        self.directory = directory
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

    private var resolvedDirectory: URL? { directory ?? Self.defaultDirectory() }

    /// The new filename is an injective percent-encoding of the exact account
    /// string. It remains recognizable while preventing distinct gateway URLs
    /// from sharing a credential file.
    public static func credentialFileURL(account: String, directory: URL) -> URL {
        let encoded = account
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? account.unicodeScalars.map { String(format: "%02X", $0.value) }.joined()
        return directory.appending(path: "\(encoded).json")
    }

    /// The pre-capability filename scheme. Kept only to adopt files written by
    /// older versions; new writes never use it.
    private static func legacyCredentialFileURL(account: String, directory: URL) -> URL {
        let slug = account.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        return directory.appending(path: "\(slug).json")
    }

    public func save(_ credentials: Credentials, account: String) throws {
        guard let directory = resolvedDirectory else {
            throw StorageError.applicationSupportDirectoryUnavailable
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(credentials)
        let target = Self.credentialFileURL(account: account, directory: directory)
        try data.write(to: target, options: [.atomic])
        // .atomic replaces the file, so permissions must be applied after.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: target.path
        )
        // A successful write is the point at which an old lossy filename can
        // safely be retired. Never remove it before the replacement exists.
        let legacy = Self.legacyCredentialFileURL(account: account, directory: directory)
        if legacy != target { try? FileManager.default.removeItem(at: legacy) }
    }

    /// Returns the exact encoded credential bytes. Legacy files are adopted
    /// without re-encoding, preserving fields from newer app versions.
    func loadData(account: String) -> Data? {
        guard let directory = resolvedDirectory else { return nil }
        let current = Self.credentialFileURL(account: account, directory: directory)
        if let data = Self.validData(at: current) { return data }

        let legacy = Self.legacyCredentialFileURL(account: account, directory: directory)
        guard let data = Self.validData(at: legacy) else { return nil }
        if (try? Self.adopt(data: data, to: current, fileManager: .default)) != nil {
            try? FileManager.default.removeItem(at: legacy)
        }
        return data
    }

    public func load(account: String) throws -> Credentials? {
        guard let data = loadData(account: account) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    public func delete(account: String) throws {
        guard let directory = resolvedDirectory else { return }
        let current = Self.credentialFileURL(account: account, directory: directory)
        let legacy = Self.legacyCredentialFileURL(account: account, directory: directory)
        try? FileManager.default.removeItem(at: current)
        if legacy != current { try? FileManager.default.removeItem(at: legacy) }
    }

    private static func validData(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url),
              (try? JSONDecoder().decode(Credentials.self, from: data)) != nil
        else { return nil }
        return data
    }

    private static func adopt(data: Data, to target: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: target, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}

/// Compatibility facade retained for AuthClient. Application composition may
/// replace the default file implementation with `KeychainCredentialStore`.
public enum CredentialStore {
    public typealias StorageError = FileCredentialStore.StorageError
    private static let router = Router()

    private final class Router: @unchecked Sendable {
        private let lock = NSLock()
        private var implementation: any CredentialStoring = FileCredentialStore()
        private var configured = false
        private var keychainError: KeychainError?

        @discardableResult
        func configure(_ implementation: any CredentialStoring) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !configured else { return false }
            self.implementation = implementation
            configured = true
            return true
        }

        var lastKeychainError: KeychainError? {
            lock.lock(); defer { lock.unlock() }
            return keychainError
        }

        func save(_ credentials: Credentials, account: String) throws {
            do {
                try implementation.save(credentials, account: account)
                clearError()
            } catch {
                record(error)
                throw error
            }
        }

        func load(account: String) throws -> Credentials? {
            do {
                let result = try implementation.load(account: account)
                clearError()
                return result
            } catch {
                record(error)
                throw error
            }
        }

        func delete(account: String) throws {
            do {
                try implementation.delete(account: account)
                clearError()
            } catch {
                record(error)
                throw error
            }
        }

        private func clearError() {
            lock.lock(); defer { lock.unlock() }
            keychainError = nil
        }

        private func record(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            keychainError = error as? KeychainError
        }
    }

    @discardableResult
    public static func configure(_ implementation: any CredentialStoring) -> Bool {
        router.configure(implementation)
    }

    public static var lastKeychainError: KeychainError? {
        router.lastKeychainError
    }

    private static func saveThroughRouter(_ credentials: Credentials, account: String) throws {
        try router.save(credentials, account: account)
    }

    private static func loadThroughRouter(account: String) throws -> Credentials? {
        try router.load(account: account)
    }

    private static func deleteThroughRouter(account: String) throws {
        try router.delete(account: account)
    }


    public static func credentialsDirectory(applicationSupportDirectory: URL) -> URL {
        FileCredentialStore.credentialsDirectory(applicationSupportDirectory: applicationSupportDirectory)
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        FileCredentialStore.defaultDirectory(fileManager: fileManager)
    }

    public static func credentialFileURL(account: String, directory: URL) -> URL {
        FileCredentialStore.credentialFileURL(account: account, directory: directory)
    }

    public static func save(_ credentials: Credentials, account: String) throws {
        try saveThroughRouter(credentials, account: account)
    }
    public static func save(
        _ credentials: Credentials,
        account: String,
        directory: URL?
    ) throws {
        if let directory {
            try FileCredentialStore(directory: directory).save(credentials, account: account)
        } else {
            try saveThroughRouter(credentials, account: account)
        }
    }

    public static func load(account: String, directory: URL?) -> Credentials? {
        if let directory {
            return try? FileCredentialStore(directory: directory).load(account: account)
        }
        return load(account: account)
    }

    public static func delete(account: String, directory: URL?) {
        if let directory {
            try? FileCredentialStore(directory: directory).delete(account: account)
        } else {
            delete(account: account)
        }
    }

    /// This non-throwing spelling is retained for existing callers. New
    /// composition code that needs diagnostics should use `loadThrowing`.
    public static func load(account: String) -> Credentials? {
        try? loadThrowing(account: account)
    }

    public static func loadThrowing(account: String) throws -> Credentials? {
        try loadThroughRouter(account: account)
    }

    /// This non-throwing spelling is retained for existing callers.
    public static func delete(account: String) {
        try? deleteThroughRouter(account: account)
    }

    public static func deleteThrowing(account: String) throws {
        try deleteThroughRouter(account: account)
    }
}
