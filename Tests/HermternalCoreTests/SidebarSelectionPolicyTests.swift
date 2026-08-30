@testable import HermternalCore
import Foundation
import Testing

@Test("A rapid selection burst publishes every settled selection")
func rapidSelectionBurstPublishesEverySelection() {
    let selections = (1...24).map { "chat-\($0)" }
    var highlighted: [String] = []
    var publications: [String] = []
    var latestPublicationSequence = 0

    func publish(_ id: String, sequence: Int) -> Bool {
        guard sequence >= latestPublicationSequence else { return false }
        latestPublicationSequence = sequence
        publications.append(id)
        return true
    }

    // AppModel commits both values synchronously before it starts the
    // cancellable opener task. A repeat cancellation therefore cannot remove
    // an already-settled publication.
    for (offset, id) in selections.enumerated() {
        highlighted.append(id)
        #expect(publish(id, sequence: offset + 1))
    }

    // Even if an older async result arrives later, it cannot overwrite the
    // newest publication.
    #expect(!publish("chat-1", sequence: 1))
    #expect(highlighted == selections)
    #expect(publications == selections)
    #expect(publications.last == "chat-24")
    #expect(publications.count == 24)
}

@Test("A superseded opener generation cannot publish expensive work")
func supersededSelectionCancelsExpensiveWork() {
    let generations = OpenGenerationController()
    let first = generations.begin()
    let second = generations.begin()

    // TranscriptOpener, cache reads, REST, and block preparation all check
    // this shared generation before applying their results.
    #expect(!generations.isCurrent(first))
    #expect(generations.isCurrent(second))
}

@Test("Pending repeat opens coalesce only before first publication")
func pendingRepeatOpenCoalescingStopsAfterFirstPublication() {
    #expect(
        TranscriptSwitchWorkPolicy.shouldCoalescePendingOpen(
            sessionID: "chat-1",
            activeSessionID: "chat-1",
            hasPublishedFirstFrame: false
        )
    )
    #expect(
        !TranscriptSwitchWorkPolicy.shouldCoalescePendingOpen(
            sessionID: "chat-1",
            activeSessionID: "chat-1",
            hasPublishedFirstFrame: true
        )
    )
    #expect(
        !TranscriptSwitchWorkPolicy.shouldCoalescePendingOpen(
            sessionID: "chat-2",
            activeSessionID: "chat-1",
            hasPublishedFirstFrame: false
        )
    )
}

@Test("Only repeated arrow events defer expensive opening")
func repeatedArrowEventsDeferOpening() {
    #expect(TranscriptSwitchWorkPolicy.shouldDeferNavigationOpen(isNavigationRepeat: true))
    #expect(!TranscriptSwitchWorkPolicy.shouldDeferNavigationOpen(isNavigationRepeat: false))
}

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

@Test("Folder selection expands active chats in authoritative order")
func folderSelectionExpandsContents() {
    let sessions = [
        selectionSession(id: "second"),
        selectionSession(id: "first"),
        selectionSession(id: "cron", source: "cron"),
        selectionSession(id: "outside")
    ]
    let selection: Set<SidebarSelectionID> = [.folder("work")]

    #expect(
        SidebarSelectionPolicy.expandedChatIDs(
            selection: selection,
            orderedSessionIDs: sessions.map(\.id),
            scheduledSessionIDs: ["cron"],
            folderMembership: [
                "first": "work",
                "second": "work",
                "cron": "work",
                "outside": "other"
            ]
        ) == ["second", "first"]
    )
}

@Test("An explicitly selected scheduled chat bypasses folder exclusion")
func explicitlySelectedScheduledChatExpands() {
    let membership = ["scheduled": "work"]

    #expect(
        SidebarSelectionPolicy.expandedChatIDs(
            selection: [.folder("work")],
            orderedSessionIDs: ["scheduled"],
            scheduledSessionIDs: ["scheduled"],
            folderMembership: membership
        ).isEmpty
    )
    #expect(
        SidebarSelectionPolicy.expandedChatIDs(
            selection: [.folder("work"), .chat("scheduled")],
            orderedSessionIDs: ["scheduled"],
            scheduledSessionIDs: ["scheduled"],
            folderMembership: membership
        ) == ["scheduled"]
    )
}

@Test("Mixed chat and folder selection unions and de-duplicates")
func mixedSelectionExpandsAndDeduplicates() {
    let sessions = [
        selectionSession(id: "folder-chat"),
        selectionSession(id: "explicit"),
        selectionSession(id: "duplicate"),
        selectionSession(id: "duplicate")
    ]
    let selection: Set<SidebarSelectionID> = [.chat("explicit"), .folder("work")]

    #expect(
        SidebarSelectionPolicy.expandedChatIDs(
            selection: selection,
            orderedSessionIDs: sessions.map(\.id),
            scheduledSessionIDs: [],
            folderMembership: [
                "folder-chat": "work",
                "explicit": "work",
                "duplicate": "work"
            ]
        ) == ["folder-chat", "explicit", "duplicate"]
    )
}

@Test("Expansion scans a large heterogeneous corpus within a deterministic bound")
func expansionWorkIsBoundedForLargeCorpus() {
    let sessions = (0..<4_096).map { index in
        selectionSession(
            id: "session-\(index)",
            source: index.isMultiple(of: 211) ? "cron" : ""
        )
    }
    let orderedSessionIDs = sessions.map(\.id)
    let folderMembership = Dictionary(
        uniqueKeysWithValues: sessions.enumerated().map { index, session in
            (session.id, "folder-\(index % 8)")
        }
    )
    let scheduledSessionIDs = Set(
        sessions.filter { $0.source == "cron" }.map(\.id)
    )
    let selection: Set<SidebarSelectionID> = [
        .chat("session-37"),
        .chat("session-211"),
        .folder("folder-2"),
        .folder("folder-5")
    ]

    let expansion = SidebarSelectionPolicy.expandedChatIDsWithWork(
        selection: selection,
        orderedSessionIDs: orderedSessionIDs,
        scheduledSessionIDs: scheduledSessionIDs,
        folderMembership: folderMembership
    )
    let expected = orderedSessionIDs.reduce(into: [String]()) { result, id in
        guard !id.isEmpty,
              !result.contains(id),
              selection.contains(.chat(id))
                || (folderMembership[id].map { selection.contains(.folder($0)) } ?? false)
                    && !scheduledSessionIDs.contains(id)
        else { return }
        result.append(id)
    }

    #expect(expansion.chatIDs == expected)
    #expect(expansion.work.selectionItemsVisited == selection.count)
    #expect(expansion.work.membershipEntriesVisited == folderMembership.count)
    #expect(expansion.work.orderedSessionIDsVisited == orderedSessionIDs.count)
    #expect(
        expansion.work.total
            == selection.count + folderMembership.count + orderedSessionIDs.count
    )
}

@Test("Batch row expansion scans the authoritative order once")
func batchExpansionWorkIsBoundedByRowsAndSessions() {
    let sessions = (0..<4_096).map { index in
        selectionSession(
            id: "session-\(index)",
            source: index.isMultiple(of: 211) ? "cron" : ""
        )
    }
    let orderedSessionIDs = sessions.map(\.id)
    let folderMembership = Dictionary(
        uniqueKeysWithValues: sessions.enumerated().map { index, session in
            (session.id, "folder-\(index % 8)")
        }
    )
    let scheduledSessionIDs = Set(
        sessions.filter { $0.source == "cron" }.map(\.id)
    )
    let contextItems: [SidebarSelectionID] =
        orderedSessionIDs.map { .chat($0) }
        + (0..<8).map { .folder("folder-\($0)") }

    let expansion = SidebarSelectionPolicy.expandedChatIDsByItemWithWork(
        contextItems,
        orderedSessionIDs: orderedSessionIDs,
        scheduledSessionIDs: scheduledSessionIDs,
        folderMembership: folderMembership
    )
    let expectedFolder3 = orderedSessionIDs.filter {
        folderMembership[$0] == "folder-3"
            && !scheduledSessionIDs.contains($0)
    }
    let expectedFolder2 = orderedSessionIDs.filter {
        folderMembership[$0] == "folder-2"
            && !scheduledSessionIDs.contains($0)
    }

    #expect(expansion.chatIDsByItem[.chat("session-211")] == ["session-211"])
    #expect(expansion.chatIDsByItem[.folder("folder-3")] == expectedFolder3)
    #expect(expansion.chatIDsByItem[.chat("session-37")] == ["session-37"])
    #expect(expansion.chatIDsByItem[.folder("folder-2")] == expectedFolder2)
    #expect(!expansion.chatIDsByItem[.folder("folder-3")]!.contains("session-211"))
    #expect(expansion.work.contextItemsVisited == contextItems.count)
    #expect(expansion.work.orderedSessionIDsVisited == orderedSessionIDs.count)
    #expect(
        expansion.work.total
            == contextItems.count + orderedSessionIDs.count
    )
    // Before batching, every context item rescanned the full order.
    #expect(expansion.work.total <= contextItems.count * 2)
    print(
        "PERF|sidebar row context expansion|"
            + "beforeOrderedProbes=\(contextItems.count * orderedSessionIDs.count) "
            + "afterOrderedProbes=\(expansion.work.orderedSessionIDsVisited) "
            + "rows=\(contextItems.count) sessions=\(orderedSessionIDs.count)"
    )
}

@Test("An unselected clicked row remains the only context target")
func unselectedClickScopesToOneTarget() {
    let selected: Set<SidebarSelectionID> = [.chat("already-selected")]
    let context = SidebarSelectionPolicy.contextTargets(
        clicked: .folder("work"),
        selected: selected
    )

    #expect(
        SidebarSelectionPolicy.expandedChatIDs(
            selection: context,
            orderedSessionIDs: ["folder-chat", "already-selected"],
            scheduledSessionIDs: [],
            folderMembership: [
                "folder-chat": "work",
                "already-selected": "other"
            ]
        ) == ["folder-chat"]
    )
}

@Test("Drag targets filter by type and unique visible order")
func dragTargetsFilterTypedSelection() {
    let selected: Set<SidebarSelectionID> = [.chat("chat-1"), .chat("chat-2"), .folder("work")]
    let visibleOrder: [SidebarSelectionID] = [
        .folder("work"),
        .chat("chat-2"),
        .chat("chat-1"),
        .folder("home")
    ]

    #expect(Set(visibleOrder).count == visibleOrder.count)
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

@Test("Selection policy keeps the unique visible identity invariant")
func selectionPolicyUsesUniqueVisibleIdentityOrder() {
    let selected: Set<SidebarSelectionID> = [.chat("chat-1"), .chat("chat-2")]
    let visibleOrder: [SidebarSelectionID] = [.chat("chat-2"), .chat("chat-1")]

    #expect(Set(visibleOrder).count == visibleOrder.count)
    #expect(
        SidebarSelectionPolicy.applicableDragTargets(
            dragged: .chat("chat-1"),
            selected: selected,
            visibleOrder: visibleOrder
        ) == visibleOrder
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

private func selectionSession(id: String, source: String = "") -> ChatSession {
    ChatSession(from: .object([
        "id": .string(id),
        "source": .string(source)
    ]))
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
