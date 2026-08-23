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
    private var organization = SessionOrganization()

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
            organization = SessionOrganization()
            return organization
        }

        let data: Data
        do {
            data = try fileSystem.data(at: fileURL)
        } catch {
            throw SessionOrganizationError.fileReadFailed("Could not read \(fileURL.path): \(error)")
        }
        do {
            let decodedOrganization = try JSONDecoder().decode(SessionOrganization.self, from: data)
            hasLoaded = true
            storedDigest = ContentDigest.value(for: data)
            organization = decodedOrganization
            return decodedOrganization
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
        let unchangedMissingFile = storedDigest == nil
            && self.organization == organization
            && !fileSystem.fileExists(at: fileURL)
        guard digest != storedDigest && !unchangedMissingFile else {
            self.organization = organization
            return
        }

        do {
            try fileSystem.createDirectory(at: directory)
            try fileSystem.atomicWrite(data, to: fileURL)
            storedDigest = digest
            hasLoaded = true
            self.organization = organization
        } catch {
            throw SessionOrganizationError.fileWriteFailed("Could not write \(fileURL.path): \(error)")
        }
    }

    public func createFolder(name: String) async throws -> Folder {
        let current = try await loadedOrganization()
        let folder = Folder(id: UUID().uuidString, name: name, order: current.folders.count)
        let folders = reindexed(current.folders + [folder])
        try await save(updated(current, folders: folders))
        return folders[folders.count - 1]
    }

    public func renameFolder(id: String, name: String) async throws {
        let current = try await loadedOrganization()
        guard current.folders.contains(where: { $0.id == id }) else {
            throw SessionOrganizationError.folderNotFound(id)
        }
        let folders = current.folders.map { folder in
            folder.id == id ? Folder(id: folder.id, name: name, order: folder.order) : folder
        }
        try await save(updated(current, folders: folders))
    }

    @discardableResult
    public func deleteFolder(id: String) async throws -> [String] {
        try await deleteFolders(ids: [id]).affectedSessionIDs
    }

    /// Deletes a validated folder set and clears its memberships in one organization write.
    @discardableResult
    public func deleteFolders(ids: [String]) async throws -> SessionOrganizationFolderDeletionResult {
        guard !ids.isEmpty else {
            return SessionOrganizationFolderDeletionResult(deletedFolderIDs: [], affectedSessionIDs: [])
        }

        guard Set(ids).count == ids.count else {
            throw SessionOrganizationError.invalidFolderDeletion("Folder IDs must be unique")
        }

        let current = try await loadedOrganization()
        let folderIDs = Set(current.folders.map(\.id))
        guard let missingID = ids.first(where: { !folderIDs.contains($0) }) else {
            let selectedFolderIDs = Set(ids)
            var affectedSessionIDs = Set<String>()
            var gateways = current.gateways

            for (host, gateway) in current.gateways {
                let removedSessionIDs = gateway.folderMembership.compactMap { sessionID, folderID in
                    selectedFolderIDs.contains(folderID) ? sessionID : nil
                }
                affectedSessionIDs.formUnion(removedSessionIDs)
                guard !removedSessionIDs.isEmpty else { continue }

                var membership = gateway.folderMembership
                for sessionID in removedSessionIDs {
                    membership.removeValue(forKey: sessionID)
                }
                gateways[host] = .init(folderMembership: membership)
            }

            let folders = reindexed(current.folders.filter { !selectedFolderIDs.contains($0.id) })
            try await save(updated(current, folders: folders, gateways: gateways))
            return SessionOrganizationFolderDeletionResult(
                deletedFolderIDs: current.folders.compactMap { selectedFolderIDs.contains($0.id) ? $0.id : nil },
                affectedSessionIDs: affectedSessionIDs.sorted()
            )
        }

        throw SessionOrganizationError.folderNotFound(missingID)
    }

    public func reorderFolders(ids: [String]) async throws {
        let current = try await loadedOrganization()
        let foldersByID = Dictionary(uniqueKeysWithValues: current.folders.map { ($0.id, $0) })
        guard ids.count == current.folders.count,
              Set(ids).count == ids.count
        else {
            throw SessionOrganizationError.invalidFolderOrder
        }
        guard Set(ids) == Set(foldersByID.keys) else {
            let unknownID = ids.first(where: { foldersByID[$0] == nil }) ?? "folder order"
            throw SessionOrganizationError.folderNotFound(unknownID)
        }
        let folders = reindexed(ids.map { foldersByID[$0]! })
        try await save(updated(current, folders: folders))
    }

    public func assignChat(
        sessionID: String,
        toFolderID folderID: String,
        gatewayHost: String
    ) async throws {
        let current = try await loadedOrganization()
        guard current.folders.contains(where: { $0.id == folderID }) else {
            throw SessionOrganizationError.folderNotFound(folderID)
        }
        var gateways = current.gateways
        var membership = gateways[gatewayHost]?.folderMembership ?? [:]
        membership[sessionID] = folderID
        gateways[gatewayHost] = .init(folderMembership: membership)
        try await save(updated(current, gateways: gateways))
    }

    public func clearChatAssignment(sessionID: String, gatewayHost: String) async throws {
        let current = try await loadedOrganization()
        guard var membership = current.gateways[gatewayHost]?.folderMembership,
              membership.removeValue(forKey: sessionID) != nil
        else {
            try await save(current)
            return
        }
        var gateways = current.gateways
        gateways[gatewayHost] = .init(folderMembership: membership)
        try await save(updated(current, gateways: gateways))
    }

    /// Reconciles a confirmed permanent purge in one organization write:
    /// confirmed chat assignments are removed from the current gateway only
    /// and only the caller-approved folders are deleted globally. Failed or
    /// unconfirmed chat IDs remain untouched.
    ///
    /// - Returns: `true` when assignments or folders changed.
    @discardableResult
    public func reconcilePurge(
        confirmedSessionIDs: Set<String>,
        folderIDs: Set<String>,
        gatewayHost: String
    ) async throws -> Bool {
        let confirmed = Set(confirmedSessionIDs.filter { !$0.isEmpty })
        let selectedFolders = Set(folderIDs.filter { !$0.isEmpty })
        guard !confirmed.isEmpty || !selectedFolders.isEmpty else { return false }

        let current = try await loadedOrganization()
        if let missingFolderID = selectedFolders.first(where: { folderID in
            !current.folders.contains(where: { folder in folder.id == folderID })
        }) {
            throw SessionOrganizationError.folderNotFound(missingFolderID)
        }

        var gateways = current.gateways
        var changed = false
        if let gateway = current.gateways[gatewayHost] {
            let membership = gateway.folderMembership
            let filtered = membership.filter {
                !confirmed.contains($0.key) && !selectedFolders.contains($0.value)
            }
            if filtered.count != membership.count {
                gateways[gatewayHost] = .init(folderMembership: filtered)
                changed = true
            }
        }
        if !selectedFolders.isEmpty {
            for (host, gateway) in gateways {
                let membership = gateway.folderMembership
                let filtered = membership.filter { !selectedFolders.contains($0.value) }
                guard filtered.count != membership.count else { continue }
                gateways[host] = .init(folderMembership: filtered)
                changed = true
            }
        }
        let folders: [Folder]
        if selectedFolders.isEmpty {
            folders = current.folders
        } else {
            folders = reindexed(current.folders.filter { !selectedFolders.contains($0.id) })
        }
        if folders != current.folders {
            changed = true
        }
        guard changed else { return false }
        try await save(updated(current, folders: folders, gateways: gateways))
        return true
    }


    public func setSortMode(_ mode: SortMode) async throws {
        let current = try await loadedOrganization()
        try await save(updated(current, sort: .init(mode: mode)))
    }

    public func setGrouping(byDate: Bool) async throws {
        let current = try await loadedOrganization()
        try await save(updated(current, grouping: .init(byDate: byDate)))
    }

    private func loadedOrganization() async throws -> SessionOrganization {
        if !hasLoaded {
            _ = try await load()
        }
        return organization
    }

    private func updated(
        _ current: SessionOrganization,
        grouping: SessionOrganization.Grouping? = nil,
        sort: SessionOrganization.Sort? = nil,
        folders: [Folder]? = nil,
        gateways: [String: SessionOrganization.Gateway]? = nil
    ) -> SessionOrganization {
        SessionOrganization(
            grouping: grouping ?? current.grouping,
            sort: sort ?? current.sort,
            folders: folders ?? current.folders,
            gateways: gateways ?? current.gateways
        )
    }

    /// Folder order is the array position. Reindexing keeps it contiguous.
    private func reindexed(_ folders: [Folder]) -> [Folder] {
        folders.enumerated().map { index, folder in
            Folder(id: folder.id, name: folder.name, order: index)
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
