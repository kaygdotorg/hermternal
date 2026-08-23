import Foundation

public protocol SessionOrganizationFileSystem: Sendable {
    func data(at url: URL) throws -> Data
    func fileExists(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func atomicWrite(_ data: Data, to url: URL) throws
}

public struct LocalSessionOrganizationFileSystem: SessionOrganizationFileSystem {
    public init() {}

    public func data(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func atomicWrite(_ data: Data, to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}

/// Persists the local sidebar organization. A later phase can watch this file;
/// reload-on-change must use the digest guard so the app ignores its own write.
public protocol SessionOrganizationPersisting: Sendable {
    func load() async throws -> SessionOrganization
    func save(_ organization: SessionOrganization) async throws
}

public actor SessionOrganizationStore: SessionOrganizationPersisting {
    public static let configurationDirectoryName = ".config/hermternal"
    public static let configurationFileName = "config.json"

    private let directory: URL
    private let fileURL: URL
    private let fileSystem: any SessionOrganizationFileSystem
    private var storedDigest: UInt64?
    private var hasLoaded = false

    public init(
        directory: URL? = nil,
        fileSystem: any SessionOrganizationFileSystem = LocalSessionOrganizationFileSystem()
    ) {
        let resolvedDirectory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: Self.configurationDirectoryName, directoryHint: .isDirectory)
        self.directory = resolvedDirectory
        self.fileURL = resolvedDirectory.appending(path: Self.configurationFileName)
        self.fileSystem = fileSystem
    }

    public nonisolated var configurationURL: URL {
        fileURL
    }

    public func load() async throws -> SessionOrganization {
        guard fileSystem.fileExists(at: fileURL) else {
            hasLoaded = true
            storedDigest = nil
            return SessionOrganization()
        }

        let data: Data
        do {
            data = try fileSystem.data(at: fileURL)
        } catch {
            throw SessionOrganizationError.fileReadFailed("Could not read \(fileURL.path): \(error)")
        }

        do {
            let organization = try JSONDecoder().decode(SessionOrganization.self, from: data)
            hasLoaded = true
            storedDigest = ContentDigest.value(for: data)
            return organization
        } catch let error as SessionOrganizationError {
            throw error
        } catch {
            throw SessionOrganizationError.malformedConfiguration(
                "Could not decode \(fileURL.path): \(error)"
            )
        }
    }

    public func save(_ organization: SessionOrganization) async throws {
        // A save without an earlier launch read still validates an existing file
        // before replacing it. This keeps malformed user data intact.
        if !hasLoaded {
            _ = try await load()
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(organization)
        } catch {
            throw SessionOrganizationError.fileWriteFailed("Could not encode \(fileURL.path): \(error)")
        }

        let digest = ContentDigest.value(for: data)
        guard digest != storedDigest else { return }

        do {
            try fileSystem.createDirectory(at: directory)
            try fileSystem.atomicWrite(data, to: fileURL)
            storedDigest = digest
            hasLoaded = true
        } catch {
            throw SessionOrganizationError.fileWriteFailed("Could not write \(fileURL.path): \(error)")
        }
    }
}

/// A stable, allocation-free digest for the encoded bytes. The digest lives
/// only in the actor, so it does not duplicate decoded organization state.
private enum ContentDigest {
    static func value(for data: Data) -> UInt64 {
        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return digest
    }
}
