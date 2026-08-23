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
