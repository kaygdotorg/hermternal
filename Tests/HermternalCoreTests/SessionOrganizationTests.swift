import Foundation
import HermternalCore
import Testing

@Test("Session organization round trip preserves every field")
func sessionOrganizationRoundTrip() throws {
    let organization = SessionOrganization(
        grouping: .init(byDate: false),
        sort: .init(mode: .title),
        folders: [
            Folder(id: "work", name: "Work", order: 2),
            Folder(id: "home", name: "Home", order: 0)
        ],
        gateways: [
            "gateway.example": .init(folderMembership: ["session-1": "work", "session-2": "home"])
        ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let decoder = JSONDecoder()

    let bytes = try encoder.encode(organization)
    let decoded = try decoder.decode(SessionOrganization.self, from: bytes)

    #expect(decoded == organization)
    #expect(decoded.schemaVersion == SessionOrganization.currentSchemaVersion)
}

@Test("Default organization storage uses the platform-neutral core directory")
func defaultOrganizationStoreUsesPlatformNeutralDirectory() {
    let expectedDirectory = FileManager.default.temporaryDirectory
        .appending(path: SessionOrganizationStore.configurationDirectoryName, directoryHint: .isDirectory)
    let store = SessionOrganizationStore()

    #expect(SessionOrganizationStore.defaultDirectory == expectedDirectory)
    #expect(store.configurationURL == expectedDirectory.appending(path: SessionOrganizationStore.configurationFileName))
}

@Test("Injected organization directory determines the configuration path")
func injectedOrganizationDirectoryDeterminesConfigurationPath() {
    let directory = URL(fileURLWithPath: "/injected/session-organization", isDirectory: true)
    let store = SessionOrganizationStore(directory: directory)

    #expect(store.configurationURL == directory.appending(path: SessionOrganizationStore.configurationFileName))
}

@Test("Unknown organization keys are ignored")
func sessionOrganizationIgnoresUnknownKeys() throws {
    let data = Data(#"""
        {
            "schemaVersion": 1,
            "grouping": {"byDate": true},
            "sort": {"mode": "lastActivity"},
            "folders": [{"id": "work", "name": "Work", "order": 0, "futureFolderKey": "ignored"}],
            "gateways": {},
            "futureTopLevelKey": {"ignored": true}
        }
        """#.utf8)

    let organization = try JSONDecoder().decode(SessionOrganization.self, from: data)
    #expect(organization.folders == [Folder(id: "work", name: "Work", order: 0)])
}

@Test("Missing grouping and sort use documented defaults")
func sessionOrganizationMissingSectionsUseDefaults() throws {
    let data = Data(#"""
        {
            "schemaVersion": 1,
            "folders": [],
            "gateways": {}
        }
        """#.utf8)

    let organization = try JSONDecoder().decode(SessionOrganization.self, from: data)
    #expect(organization.grouping == SessionOrganization.Grouping(byDate: true))
    #expect(organization.sort == SessionOrganization.Sort(mode: .lastActivity))
}

@Test("Unsupported schema versions are rejected clearly")
func sessionOrganizationRejectsUnsupportedSchema() throws {
    let data = Data(#"{"schemaVersion": 9}"#.utf8)

    do {
        _ = try JSONDecoder().decode(SessionOrganization.self, from: data)
        Issue.record("Unsupported schema version was accepted")
    } catch let error as SessionOrganizationError {
        #expect(error == .unsupportedSchemaVersion(9))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Malformed configuration leaves original bytes untouched")
func malformedConfigurationDoesNotDestroyFile() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: SessionOrganizationStore.configurationFileName)
    let original = Data(#"{"schemaVersion": 1, "grouping": "not-an-object"}"#.utf8)
    try original.write(to: fileURL)
    let store = SessionOrganizationStore(directory: directory)

    do {
        _ = try await store.load()
        Issue.record("Malformed configuration was accepted")
    } catch let error as SessionOrganizationError {
        guard case .malformedConfiguration = error else {
            Issue.record("Unexpected organization error: \(error)")
            return
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(try Data(contentsOf: fileURL) == original)
}

@Test("Saving identical content performs no write")
func identicalOrganizationSaveSkipsWrite() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileSystem = CountingOrganizationFileSystem()
    let store = SessionOrganizationStore(directory: directory, fileSystem: fileSystem)
    let organization = SessionOrganization(
        grouping: .init(byDate: false),
        sort: .init(mode: .created),
        folders: [Folder(id: "work", name: "Work", order: 0)]
    )

    try await store.save(organization)
    let writesAfterFirstSave = fileSystem.atomicWriteCount
    try await store.save(organization)

    #expect(writesAfterFirstSave == 1)
    #expect(fileSystem.atomicWriteCount == writesAfterFirstSave)
}

@Test("Canonical organization output is stable")
func organizationEncodingIsStable() throws {
    let organization = SessionOrganization(
        folders: [Folder(id: "work", name: "Work", order: 0)],
        gateways: ["gateway": .init(folderMembership: ["session": "work"])]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    let first = try encoder.encode(organization)
    let second = try encoder.encode(organization)
    #expect(first == second)
}

@Test("Folder mutations persist through reload")
func folderMutationsRoundTrip() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionOrganizationStore(directory: directory)

    let work = try await store.createFolder(name: "Work")
    let home = try await store.createFolder(name: "Home")
    try await store.renameFolder(id: work.id, name: "Renamed")
    try await store.reorderFolders(ids: [home.id, work.id])
    try await store.assignChat(sessionID: "session-1", toFolderID: work.id, gatewayHost: "gateway-a")

    var reloaded = try await SessionOrganizationStore(directory: directory).load()
    #expect(reloaded.folders.map(\.id) == [home.id, work.id])
    #expect(reloaded.folders.map(\.order) == [0, 1])
    #expect(reloaded.folders[1].name == "Renamed")
    #expect(reloaded.gateways["gateway-a"]?.folderMembership == ["session-1": work.id])

    try await store.clearChatAssignment(sessionID: "session-1", gatewayHost: "gateway-a")
    reloaded = try await SessionOrganizationStore(directory: directory).load()
    #expect(reloaded.gateways["gateway-a"]?.folderMembership == [:])
}

@Test("Deleting a folder removes only its memberships and keeps order contiguous")
func deletingFolderRemovesItsMemberships() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionOrganizationStore(directory: directory)
    let organization = SessionOrganization(
        folders: [
            Folder(id: "work", name: "Work", order: 0),
            Folder(id: "home", name: "Home", order: 1),
            Folder(id: "later", name: "Later", order: 2)
        ],
        gateways: [
            "gateway-a": .init(folderMembership: [
                "work-session": "work",
                "home-session": "home",
                "unfiled-session": "missing"
            ]),
            "gateway-b": .init(folderMembership: ["other-work-session": "work"])
        ]
    )
    try await store.save(organization)

    let removed = try await store.deleteFolder(id: "work")
    let reloaded = try await SessionOrganizationStore(directory: directory).load()

    #expect(removed.sorted() == ["other-work-session", "work-session"])
    #expect(reloaded.folders.map(\.id) == ["home", "later"])
    #expect(reloaded.folders.map(\.order) == [0, 1])
    #expect(reloaded.gateways["gateway-a"]?.folderMembership == [
        "home-session": "home",
        "unfiled-session": "missing"
    ])
    #expect(reloaded.gateways["gateway-b"]?.folderMembership.isEmpty == true)
    #expect(reloaded.gateways.values.allSatisfy { gateway in
        !gateway.folderMembership.values.contains("work")
    })
}

@Test("Unknown folder IDs fail clearly")
func unknownFolderIDsFailClearly() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionOrganizationStore(directory: directory)
    try await store.save(SessionOrganization(folders: [
        Folder(id: "known", name: "Known", order: 0)
    ]))

    await expectFolderNotFound("missing") {
        try await store.renameFolder(id: "missing", name: "Nope")
    }
    await expectFolderNotFound("missing") {
        _ = try await store.deleteFolder(id: "missing")
    }
    await expectFolderNotFound("missing") {
        try await store.assignChat(sessionID: "session", toFolderID: "missing", gatewayHost: "gateway")
    }
}

@Test("Gateway membership mutations stay scoped to their host")
func gatewayMembershipIsScoped() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionOrganizationStore(directory: directory)
    try await store.save(SessionOrganization(
        folders: [Folder(id: "work", name: "Work", order: 0)],
        gateways: [
            "gateway-a": .init(folderMembership: ["a-session": "work"]),
            "gateway-b": .init(folderMembership: ["b-session": "work"])
        ]
    ))

    try await store.assignChat(sessionID: "new-session", toFolderID: "work", gatewayHost: "gateway-a")
    try await store.clearChatAssignment(sessionID: "a-session", gatewayHost: "gateway-a")
    let reloaded = try await SessionOrganizationStore(directory: directory).load()

    #expect(reloaded.gateways["gateway-a"]?.folderMembership == ["new-session": "work"])
    #expect(reloaded.gateways["gateway-b"]?.folderMembership == ["b-session": "work"])
}

@Test("Duplicate folder names receive distinct stable IDs")
func duplicateFolderNamesHaveDistinctIDs() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionOrganizationStore(directory: directory)

    let first = try await store.createFolder(name: "Same")
    let second = try await store.createFolder(name: "Same")
    let reloaded = try await SessionOrganizationStore(directory: directory).load()

    #expect(first.id != second.id)
    #expect(first.name == second.name)
    #expect(reloaded.folders.map(\.id) == [first.id, second.id])
}

@Test("Reassigning a chat replaces its folder")
func reassigningChatReplacesMembership() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionOrganizationStore(directory: directory)
    try await store.save(SessionOrganization(folders: [
        Folder(id: "work", name: "Work", order: 0),
        Folder(id: "home", name: "Home", order: 1)
    ]))

    try await store.assignChat(sessionID: "session", toFolderID: "work", gatewayHost: "gateway")
    try await store.assignChat(sessionID: "session", toFolderID: "home", gatewayHost: "gateway")
    let reloaded = try await SessionOrganizationStore(directory: directory).load()

    #expect(reloaded.gateways["gateway"]?.folderMembership == ["session": "home"])
}

@Test("No-change folder mutation performs no write")
func noChangeFolderMutationSkipsWrite() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileSystem = CountingOrganizationFileSystem()
    let store = SessionOrganizationStore(directory: directory, fileSystem: fileSystem)
    try await store.save(SessionOrganization(folders: [
        Folder(id: "work", name: "Work", order: 0)
    ]))
    let writesAfterInitialSave = fileSystem.atomicWriteCount

    try await store.renameFolder(id: "work", name: "Work")
    try await store.assignChat(sessionID: "session", toFolderID: "work", gatewayHost: "gateway")
    let writesAfterAssignment = fileSystem.atomicWriteCount
    try await store.assignChat(sessionID: "session", toFolderID: "work", gatewayHost: "gateway")
    try await store.clearChatAssignment(sessionID: "missing", gatewayHost: "gateway")
    try await store.setGrouping(byDate: true)
    try await store.setSortMode(.lastActivity)

    #expect(writesAfterInitialSave == 1)
    #expect(writesAfterAssignment == 2)
    #expect(fileSystem.atomicWriteCount == writesAfterAssignment)
}

@Test("No-change mutation on a missing file performs no write")
func noChangeMutationOnMissingFileSkipsWrite() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileSystem = CountingOrganizationFileSystem()
    let store = SessionOrganizationStore(directory: directory, fileSystem: fileSystem)

    try await store.setGrouping(byDate: true)

    #expect(fileSystem.atomicWriteCount == 0)
}

@Test("Purge reconciliation removes chats and approved folders in one write")
func reconcilePurgeWritesOnceAndPreservesOthers() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileSystem = CountingOrganizationFileSystem()
    let store = SessionOrganizationStore(directory: directory, fileSystem: fileSystem)
    try await store.save(SessionOrganization(
        folders: [
            Folder(id: "work", name: "Work", order: 0),
            Folder(id: "home", name: "Home", order: 1)
        ],
        gateways: [
            "gateway-a": .init(folderMembership: [
                "purged": "work",
                "retained": "home"
            ]),
            "gateway-b": .init(folderMembership: ["purged-elsewhere": "home"])
        ]
    ))
    let initialWrites = fileSystem.atomicWriteCount

    #expect(try await store.reconcilePurge(
        confirmedSessionIDs: ["purged", "purged-elsewhere"],
        folderIDs: ["work"],
        gatewayHost: "gateway-a"
    ))
    #expect(fileSystem.atomicWriteCount == initialWrites + 1)
    let reloaded = try await SessionOrganizationStore(directory: directory).load()
    #expect(reloaded.folders.map(\.id) == ["home"])
    #expect(reloaded.gateways["gateway-a"]?.folderMembership == ["retained": "home"])
    #expect(reloaded.gateways["gateway-b"]?.folderMembership == ["purged-elsewhere": "home"])
    #expect(try await store.reconcilePurge(
        confirmedSessionIDs: ["purged"],
        folderIDs: [],
        gatewayHost: "gateway-a"
    ) == false)
    #expect(fileSystem.atomicWriteCount == initialWrites + 1)
}

@Test("Purge reconciliation preserves failed assignments and folders")
func reconcilePurgePreservesFailedFolder() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionOrganizationStore(directory: directory)
    try await store.save(SessionOrganization(
        folders: [Folder(id: "work", name: "Work", order: 0)],
        gateways: [
            "gateway": .init(folderMembership: [
                "purged": "work",
                "failed": "work"
            ])
        ]
    ))

    #expect(try await store.reconcilePurge(
        confirmedSessionIDs: ["purged"],
        folderIDs: [],
        gatewayHost: "gateway"
    ))
    let reloaded = try await SessionOrganizationStore(directory: directory).load()
    #expect(reloaded.folders.map(\.id) == ["work"])
    #expect(reloaded.gateways["gateway"]?.folderMembership == ["failed": "work"])
}


@Test("Reordering requires the complete folder permutation")
func reorderRequiresPermutation() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionOrganizationStore(directory: directory)
    try await store.save(SessionOrganization(folders: [
        Folder(id: "work", name: "Work", order: 0),
        Folder(id: "home", name: "Home", order: 1)
    ]))

    do {
        try await store.reorderFolders(ids: ["work"])
        Issue.record("A partial folder order was accepted")
    } catch let error as SessionOrganizationError {
        #expect(error == .invalidFolderOrder)
    }
}

@Test("Sort and grouping settings persist")
func sortAndGroupingPersist() async throws {
    let directory = try makeOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionOrganizationStore(directory: directory)

    try await store.setSortMode(.created)
    try await store.setGrouping(byDate: false)
    let reloaded = try await SessionOrganizationStore(directory: directory).load()

    #expect(reloaded.sort == .init(mode: .created))
    #expect(reloaded.grouping == .init(byDate: false))
}

private func expectFolderNotFound(
    _ expectedID: String,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Unknown folder ID was accepted")
    } catch let error as SessionOrganizationError {
        #expect(error == .folderNotFound(expectedID))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func makeOrganizationTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SessionOrganizationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private final class CountingOrganizationFileSystem: SessionOrganizationFileSystem, @unchecked Sendable {
    private let local = LocalSessionOrganizationFileSystem()
    private(set) var atomicWriteCount = 0

    func data(at url: URL) throws -> Data {
        try local.data(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        local.fileExists(at: url)
    }

    func createDirectory(at url: URL) throws {
        try local.createDirectory(at: url)
    }

    func atomicWrite(_ data: Data, to url: URL) throws {
        atomicWriteCount += 1
        try local.atomicWrite(data, to: url)
    }
}
