import Foundation
#if canImport(Security)
import Security
#endif

/// The two generic-password policies used by the capability. Browser bearer
/// and refresh tokens are device-scoped; a future username/password provider
/// can opt into iCloud Keychain synchronization.
public enum KeychainSecretKind: Sendable, Equatable {
    case password
    case bearerTokens

    public var synchronizable: Bool {
        switch self {
        case .password: true
        case .bearerTokens: false
        }
    }
}

/// Value passed through the injected Security seam. Keeping the attributes in
/// this value makes synchronization policy testable without a real Keychain.
public struct KeychainSecret: Sendable, Equatable {
    public let account: String
    public let data: Data
    public let kind: KeychainSecretKind

    public init(account: String, data: Data, kind: KeychainSecretKind) {
        self.account = account
        self.data = data
        self.kind = kind
    }

    public var synchronizable: Bool { kind.synchronizable }
}

/// Minimal Security seam. The production implementation below translates
/// these operations to SecItem* calls; tests can inject an in-memory client.
public protocol KeychainClient: Sendable {
    func read(account: String) throws -> KeychainSecret?
    func write(_ secret: KeychainSecret) throws
    func delete(account: String) throws
}

public enum KeychainError: Error, Equatable, Sendable {
    case unavailable(status: Int32)
    case accessDenied(status: Int32)
    case operationFailed(operation: String, status: Int32)
    case invalidData

    public var status: Int32? {
        switch self {
        case let .unavailable(status), let .accessDenied(status), let .operationFailed(_, status): status
        case .invalidData: nil
        }
    }
}

/// Keychain-backed credential capability. Generic-password account identity
/// is the exact gateway absolute URL; no normalization or lossy filename is
/// involved. A legacy file is only removed after its replacement has been
/// successfully written to Keychain.
public struct KeychainCredentialStore: CredentialStoring, Sendable {
    private let client: any KeychainClient
    private let fileStore: FileCredentialStore

    public init(client: any KeychainClient, fileStore: FileCredentialStore = FileCredentialStore()) {
        self.client = client
        self.fileStore = fileStore
    }

    /// Selects the system Security implementation. Unsigned/ad-hoc builds
    /// should catch `.unavailable` and compose `FileCredentialStore` instead.
    public init(fileStore: FileCredentialStore = FileCredentialStore()) throws {
        #if canImport(Security)
        self.init(client: SystemKeychainClient(), fileStore: fileStore)
        #else
        self.client = UnavailableKeychainClient(status: -4)
        self.fileStore = fileStore
        throw KeychainError.unavailable(status: -4)
        #endif
    }

    public func save(_ credentials: Credentials, account: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credentials)
        } catch {
            throw KeychainError.invalidData
        }
        try client.write(KeychainSecret(account: account, data: data, kind: .bearerTokens))
        // If this was a migration or a previous file-backed run, only remove
        // the file after the Keychain write has completed successfully.
        try fileStore.delete(account: account)
    }

    public func load(account: String) throws -> Credentials? {
        if let secret = try client.read(account: account) {
            guard secret.kind == .bearerTokens else { throw KeychainError.invalidData }
            guard let credentials = try? JSONDecoder().decode(Credentials.self, from: secret.data) else {
                throw KeychainError.invalidData
            }
            return credentials
        }

        // A missing Keychain item is normal on first launch. Adopt an existing
        // file's exact bytes and remove it only after the Keychain write succeeds.
        guard let data = try fileStore.loadData(account: account) else { return nil }
        let credentials: Credentials
        do {
            credentials = try JSONDecoder().decode(Credentials.self, from: data)
        } catch {
            throw KeychainError.invalidData
        }
        try client.write(KeychainSecret(account: account, data: data, kind: .bearerTokens))
        try fileStore.delete(account: account)
        return credentials
    }

    public func delete(account: String) throws {
        try client.delete(account: account)
        try fileStore.delete(account: account)
    }
}

private struct UnavailableKeychainClient: KeychainClient {
    let status: Int32

    func read(account: String) throws -> KeychainSecret? {
        throw KeychainError.unavailable(status: status)
    }

    func write(_ secret: KeychainSecret) throws {
        throw KeychainError.unavailable(status: status)
    }

    func delete(account: String) throws {
        throw KeychainError.unavailable(status: status)
    }
}

#if canImport(Security)

private struct SystemKeychainClient: KeychainClient {
    private let service = "org.kayg.hermternal.credentials"

    func read(account: String) throws -> KeychainSecret? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { throw KeychainError.from(status: status, operation: "read") }
        guard let attributes = result as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data
        else { throw KeychainError.invalidData }
        let synchronizable = (attributes[kSecAttrSynchronizable as String] as? Bool) ?? false
        let kind: KeychainSecretKind = synchronizable ? .password : .bearerTokens
        return KeychainSecret(account: account, data: data, kind: kind)
    }

    func write(_ secret: KeychainSecret) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.account,
        ]
        let add: [String: Any] = query.merging([
            kSecValueData as String: secret.data,
            kSecAttrSynchronizable as String: secret.synchronizable,
        ]) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: secret.data]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.from(status: updateStatus, operation: "update")
            }
        } else if status != errSecSuccess {
            throw KeychainError.from(status: status, operation: "write")
        }
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.from(status: status, operation: "delete")
        }
    }
}

private extension KeychainError {
    static func from(status: OSStatus, operation: String) -> KeychainError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable:
            return .unavailable(status: status)
        case errSecAuthFailed, errSecMissingEntitlement:
            return .accessDenied(status: status)
        default:
            return .operationFailed(operation: operation, status: status)
        }
    }
}
#endif
