import Foundation
import HermternalCore
import Testing

private final class FakeKeychain: KeychainClient, @unchecked Sendable {
    var values: [String: KeychainSecret] = [:]
    var writes: [KeychainSecret] = []
    var readError: Error?
    var writeError: Error?
    var deleteError: Error?

    func read(account: String) throws -> KeychainSecret? {
        if let readError { throw readError }
        return values[account]
    }

    func write(_ secret: KeychainSecret) throws {
        if let writeError { throw writeError }
        writes.append(secret)
        values[secret.account] = secret
    }

    func delete(account: String) throws {
        if let deleteError { throw deleteError }
        values.removeValue(forKey: account)
    }
}

private let testCredentials = Credentials(
    accessToken: "access",
    refreshToken: "refresh",
    expiresAt: 4_000_000_000,
    provider: "self-hosted",
    userID: "user"
)

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalCredentialStore-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test("keychain credentials round-trip and delete")
func keychainRoundTrip() throws {
    let keychain = FakeKeychain()
    let store = KeychainCredentialStore(client: keychain)
    try store.save(testCredentials, account: "https://gateway.example")
    #expect(try store.load(account: "https://gateway.example") == testCredentials)
    try store.delete(account: "https://gateway.example")
    #expect(try store.load(account: "https://gateway.example") == nil)
}

@Test("missing keychain item is normal")
func keychainMissingIsNotAnError() throws {
    let store = KeychainCredentialStore(client: FakeKeychain())
    #expect(try store.load(account: "https://missing.example") == nil)
}

@Test("bearer secrets are device-scoped")
func bearerSecretsAreNotSynchronizable() throws {
    let keychain = FakeKeychain()
    try KeychainCredentialStore(client: keychain).save(testCredentials, account: "https://gateway.example")
    #expect(keychain.writes.single?.kind == .bearerTokens)
    #expect(keychain.writes.single?.synchronizable == false)
}

@Test("password policy is synchronizable")
func passwordSecretsAreSynchronizable() {
    let secret = KeychainSecret(account: "https://gateway.example", data: Data("password".utf8), kind: .password)
    #expect(secret.synchronizable)
}

@Test("legacy file is adopted and removed during keychain migration")
func keychainMigration() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let account = "https://gateway.example"
    let current = FileCredentialStore.credentialFileURL(account: account, directory: directory)
    let legacyName = account.unicodeScalars
        .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        .reduce(into: "") { $0.append($1) }
    let legacy = directory.appending(path: "\(legacyName).json")
    let legacyData = try JSONEncoder().encode(testCredentials)
    try legacyData.write(to: legacy)

    let keychain = FakeKeychain()
    let loaded = try KeychainCredentialStore(
        client: keychain,
        fileStore: FileCredentialStore(directory: directory)
    ).load(account: account)
    #expect(loaded == testCredentials)
    #expect(keychain.values[account]?.data == legacyData)
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(!FileManager.default.fileExists(atPath: current.path))
}

@Test("keychain failures remain typed and do not remove the file")
func keychainFailureIsTyped() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let account = "https://gateway.example"
    let fileStore = FileCredentialStore(directory: directory)
    try fileStore.save(testCredentials, account: account)
    let keychain = FakeKeychain()
    keychain.writeError = KeychainError.accessDenied(status: -25293)
    let store = KeychainCredentialStore(client: keychain, fileStore: fileStore)
    #expect(throws: KeychainError.accessDenied(status: -25293)) {
        try store.load(account: account)
    }
    #expect(try fileStore.load(account: account) == testCredentials)
}

@Test("distinct gateway URLs receive distinct file names")
func fileNamesAreInjective() {
    let directory = URL(fileURLWithPath: "/fixture/credentials", isDirectory: true)
    let dotted = FileCredentialStore.credentialFileURL(account: "https://a.b", directory: directory)
    let dashed = FileCredentialStore.credentialFileURL(account: "https://a-b", directory: directory)
    #expect(dotted != dashed)
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
