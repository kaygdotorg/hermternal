import Foundation
import HermternalCore
import Testing

@Test("Context targets preserve a mixed selected chat and folder set")
func contextTargetsSupportMixedSelection() {
    let selected: Set<SidebarSelectionID> = [.chat("chat-1"), .folder("work")]

    #expect(
        SidebarSelectionPolicy.contextTargets(clicked: .folder("work"), selected: selected) == selected
    )
    #expect(
        SidebarSelectionPolicy.contextTargets(clicked: .chat("chat-2"), selected: selected) == [.chat("chat-2")]
    )
}

@Test("Drag targets filter by type, visible order, and logical identity")
func dragTargetsFilterTypedSelection() {
    let selected: Set<SidebarSelectionID> = [.chat("chat-1"), .chat("chat-2"), .folder("work")]
    let visibleOrder: [SidebarSelectionID] = [
        .folder("work"),
        .chat("chat-2"),
        .chat("chat-1"),
        .chat("chat-1"),
        .folder("home")
    ]

    #expect(
        SidebarSelectionPolicy.applicableDragTargets(
            dragged: .chat("chat-1"),
            selected: selected,
            visibleOrder: visibleOrder
        ) == [.chat("chat-2"), .chat("chat-1")]
    )
    #expect(
        SidebarSelectionPolicy.applicableDragTargets(
            dragged: .folder("work"),
            selected: selected,
            visibleOrder: visibleOrder
        ) == [.folder("work")]
    )
    #expect(
        SidebarSelectionPolicy.applicableDragTargets(
            dragged: .chat("chat-3"),
            selected: selected,
            visibleOrder: visibleOrder
        ) == [.chat("chat-3")]
    )
}

@Test("Visible chat actions deduplicate pinned copies")
func visibleChatActionsDeduplicatePinnedCopies() {
    let selected: Set<SidebarSelectionID> = [.chat("chat-1"), .chat("chat-2")]
    let visibleOrder: [SidebarSelectionID] = [
        .chat("chat-1"),
        .chat("chat-1"),
        .folder("work"),
        .chat("chat-2"),
        .chat("chat-2")
    ]

    #expect(
        SidebarSelectionPolicy.visibleUniqueChatIDs(selected: selected, visibleOrder: visibleOrder)
            == ["chat-1", "chat-2"]
    )
}

@Test("Pin action converges mixed and all-pinned states")
func convergingPinAction() {
    #expect(SidebarSelectionPolicy.convergingPinAction(for: [true, false]) == .pin)
    #expect(SidebarSelectionPolicy.convergingPinAction(for: [true, true]) == .unpin)
    #expect(SidebarSelectionPolicy.convergingPinAction(for: []) == nil)
}

@Test("Pruning removes chats and folders that no longer exist")
func pruneSelection() {
    let selection: Set<SidebarSelectionID> = [.chat("keep"), .chat("gone"), .folder("work"), .folder("gone-folder")]

    #expect(
        SidebarSelectionPolicy.prunedSelection(
            selection,
            validChatIDs: ["keep"],
            validFolderIDs: ["work"]
        ) == [.chat("keep"), .folder("work")]
    )
}

@Test("Deleting several folders writes once and reports unique affected sessions")
func deletingSeveralFoldersIsAtomic() async throws {
    let directory = try makeSelectionOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileSystem = RecordingOrganizationFileSystem()
    let store = SessionOrganizationStore(directory: directory, fileSystem: fileSystem)
    let organization = SessionOrganization(
        folders: [
            Folder(id: "first", name: "First", order: 0),
            Folder(id: "second", name: "Second", order: 1),
            Folder(id: "keep", name: "Keep", order: 2)
        ],
        gateways: [
            "gateway-a": .init(folderMembership: [
                "first-chat": "first",
                "shared-chat": "second",
                "keep-a": "keep",
                "unfiled": "missing"
            ]),
            "gateway-b": .init(folderMembership: [
                "second-chat": "second",
                "shared-chat": "first",
                "keep-b": "keep"
            ])
        ]
    )
    try await store.save(organization)
    let writesBeforeDelete = fileSystem.atomicWriteCount

    let result = try await store.deleteFolders(ids: ["second", "first"])
    let reloaded = try await store.load()

    #expect(fileSystem.atomicWriteCount == writesBeforeDelete + 1)
    #expect(result.deletedFolderIDs == ["first", "second"])
    #expect(result.affectedSessionIDs == ["first-chat", "second-chat", "shared-chat"])
    #expect(reloaded.folders.map(\.id) == ["keep"])
    #expect(reloaded.folders.map(\.order) == [0])
    #expect(reloaded.gateways["gateway-a"]?.folderMembership == [
        "keep-a": "keep",
        "unfiled": "missing"
    ])
    #expect(reloaded.gateways["gateway-b"]?.folderMembership == ["keep-b": "keep"])
}

@Test("Invalid folder deletion requests do not write or change state")
func invalidFolderDeletionDoesNotWrite() async throws {
    let directory = try makeSelectionOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileSystem = RecordingOrganizationFileSystem()
    let store = SessionOrganizationStore(directory: directory, fileSystem: fileSystem)
    let organization = SessionOrganization(folders: [
        Folder(id: "known", name: "Known", order: 0)
    ])
    try await store.save(organization)
    let writesBeforeInvalidRequests = fileSystem.atomicWriteCount

    do {
        _ = try await store.deleteFolders(ids: ["known", "missing"])
        Issue.record("A partial invalid folder request was accepted")
    } catch let error as SessionOrganizationError {
        #expect(error == .folderNotFound("missing"))
    }
    do {
        _ = try await store.deleteFolders(ids: ["known", "known"])
        Issue.record("A duplicate folder request was accepted")
    } catch let error as SessionOrganizationError {
        #expect(error == .invalidFolderDeletion("Folder IDs must be unique"))
    }

    #expect(fileSystem.atomicWriteCount == writesBeforeInvalidRequests)
    #expect(try await store.load() == organization)
}

@Test("Empty folder deletion is a no-op")
func emptyFolderDeletionDoesNotWrite() async throws {
    let directory = try makeSelectionOrganizationTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileSystem = RecordingOrganizationFileSystem()
    let store = SessionOrganizationStore(directory: directory, fileSystem: fileSystem)

    let result = try await store.deleteFolders(ids: [])

    #expect(result == .init(deletedFolderIDs: [], affectedSessionIDs: []))
    #expect(fileSystem.atomicWriteCount == 0)
}

private func makeSelectionOrganizationTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SidebarSelectionPolicyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private final class RecordingOrganizationFileSystem: SessionOrganizationFileSystem, @unchecked Sendable {
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
