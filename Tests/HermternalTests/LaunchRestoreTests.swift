import Foundation
@testable import Hermternal
@testable import HermternalCore
import Testing
import os
import AppKit

@Test("An empty cache launches signed out")
@MainActor
func emptyCacheLaunchPresentsSignIn() throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(cache: HistoryCache(directory: directory))

    #expect(model.phase == .signedOut)
    #expect(model.sessions.isEmpty)
    #expect(!model.sessionExpiredBanner)
}

@Test("A warm session list restores the last selected chat")
@MainActor
func warmSessionListRestoresLastSelection() throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let older = ChatSession(
        id: "older",
        title: "Older",
        lastActive: Date(timeIntervalSince1970: 100),
        messageCount: 1
    )
    let newer = ChatSession(
        id: "newer",
        title: "Newer",
        lastActive: Date(timeIntervalSince1970: 200),
        messageCount: 1
    )
    let list = SessionListCache(directory: directory)
    #expect(list.saveSessions([older, newer]))
    #expect(list.saveSelectedSessionID("older"))

    let model = AppModel(cache: HistoryCache(directory: directory))

    #expect(model.phase == .restoring)
    #expect(model.sessions.map(\.id) == ["newer", "older"])
    #expect(model.selectedSessionID == "older")
}

@Test("A missing selection falls back to the most recently active chat")
@MainActor
func missingSelectionFallsBackToMostRecentActivity() throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let older = ChatSession(
        id: "older",
        title: "Older",
        lastActive: Date(timeIntervalSince1970: 100),
        messageCount: 1
    )
    let newer = ChatSession(
        id: "newer",
        title: "Newer",
        lastActive: Date(timeIntervalSince1970: 200),
        messageCount: 1
    )
    let list = SessionListCache(directory: directory)
    #expect(list.saveSessions([older, newer]))

    let model = AppModel(cache: HistoryCache(directory: directory))

    #expect(model.phase == .restoring)
    #expect(model.selectedSessionID == "newer")
}

@Test("A refresh rejection keeps the cached workspace and raises the banner")
@MainActor
func refreshRejectionKeepsCachedWorkspace() throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let list = SessionListCache(directory: directory)
    #expect(list.saveSessions([ChatSession(id: "chat-1", title: "Cached")]))
    let model = AppModel(cache: HistoryCache(directory: directory))
    #expect(model.phase == .restoring)

    model.handleConnectionFailure(AuthError.sessionExpired)

    #expect(model.phase == .restoring)
    #expect(model.sessionExpiredBanner)
}

@Test("Restore without credentials presents the sign-in screen")
@MainActor
func restoreWithoutCredentialsPresentsSignIn() async throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentialsDirectory = directory.appending(
        path: "credentials",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: credentialsDirectory, withIntermediateDirectories: true)
    let model = AppModel(
        cache: HistoryCache(directory: directory),
        credentialStore: FileCredentialStore(directory: credentialsDirectory)
    )
    model.serverText = "https://launch-restore-test.example"

    await model.restoreOrPromptSignIn()

    #expect(model.phase == .signedOut)
    #expect(!model.sessionExpiredBanner)
}

@Test("Sign Out is reachable from the ready workspace")
@MainActor
func signOutCommandIsReachableFromReadyWorkspace() async throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let list = SessionListCache(directory: directory)
    #expect(list.saveSessions([ChatSession(id: "chat-1", title: "Cached")]))
    let model = AppModel(cache: HistoryCache(directory: directory))
    model.phase = .ready

    #expect(model.canSignOut)
    #expect(!model.isSigningOut)

    await model.signOutCommand()

    #expect(model.phase == .signedOut)
    #expect(model.sessions.isEmpty)
    #expect(!model.canSignOut)
    #expect(!model.isSigningOut)
}

@Test("a signed-out session has no Sign Out command")
@MainActor
func signedOutSessionHasNoSignOutCommand() async throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(cache: HistoryCache(directory: directory))

    #expect(model.phase == .signedOut)
    #expect(!model.canSignOut)
    await model.signOutCommand()
    #expect(model.phase == .signedOut)
}

@Test("Sign Out isolates later gateway stream events")
@MainActor
func signOutIsolatesLaterGatewayStreamEvents() async throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(cache: HistoryCache(directory: directory))
    model.phase = .ready
    model.selectedSessionID = "chat-s1"

    await model.handle(GatewayEvent(
        type: "message.start",
        sessionID: "chat-s1",
        payload: .object(["text": .string("")])
    ))
    await model.handle(GatewayEvent(
        type: "message.delta",
        sessionID: "chat-s1",
        payload: .object(["text": .string("before sign-out")])
    ))
    #expect(model.messages.contains { $0.text.contains("before sign-out") })

    await model.signOut()

    await model.handle(GatewayEvent(
        type: "message.delta",
        sessionID: "chat-s1",
        payload: .object(["text": .string(" after sign-out")])
    ))
    await model.handle(GatewayEvent(
        type: "message.start",
        sessionID: "chat-s1",
        payload: .object(["text": .string("")])
    ))
    await model.handle(GatewayEvent(
        type: "message.complete",
        sessionID: "chat-s1",
        payload: .object(["text": .string("should not land")])
    ))

    #expect(model.phase == .signedOut)
    #expect(model.messages.isEmpty)
    #expect(model.selectedSessionID == nil)

    let token = model.composerModel.route.token
    model.publishUserTurn(text: "ghost", route: token)
    #expect(model.messages.isEmpty)
    #expect(!model.isAwaitingReply)
}

@Test("requestOpen after Sign Out does not restore a selection")
@MainActor
func requestOpenAfterSignOutDoesNotRestoreSelection() async throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = ChatSession(id: "chat-s8", title: "S8", messageCount: 1)
    let model = AppModel(cache: HistoryCache(directory: directory))
    model.phase = .ready
    model.sessions = [session]
    model.selectedSessionID = session.id

    await model.signOut()
    #expect(model.phase == .signedOut)
    #expect(model.selectedSessionID == nil)

    _ = model.requestOpen(session)
    #expect(model.phase == .signedOut)
    #expect(model.selectedSessionID == nil)
    #expect(model.messages.isEmpty)
}

@Test("A closed transport does not keep reducing stream events")
@MainActor
func closedTransportDoesNotReduceLaterStreamEvents() async throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(cache: HistoryCache(directory: directory))
    model.phase = .ready
    model.selectedSessionID = "chat-s1"

    await model.handle(GatewayEvent(
        type: "message.start",
        sessionID: "chat-s1",
        payload: .object(["text": .string("")])
    ))
    await model.handle(GatewayEvent(
        type: "transport.closed",
        sessionID: "chat-s1",
        payload: .object(["text": .string("The gateway connection closed.")])
    ))
    #expect(model.phase == .failed("The gateway connection closed."))
    #expect(!model.isAwaitingReply)

    await model.handle(GatewayEvent(
        type: "message.delta",
        sessionID: "chat-s1",
        payload: .object(["text": .string(" after-close")])
    ))
    #expect(!model.messages.contains { $0.text.contains("after-close") })
}

@Test("a second sign-in click joins the first AuthClient")
@MainActor
func secondSignInClickJoinsTheFirstAuthClient() async throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(cache: HistoryCache(directory: directory))
    model.serverText = "https://launch-restore-test.example"
    let hold = LaunchRestoreSignInHold()
    model.testingInteractiveSignIn = { try await hold.wait() }

    let first = Task { await model.signIn() }
    var spins = 0
    while model.testingAuthClientCount == 0 {
        spins += 1
        if spins > 10_000 {
            Issue.record("sign-in never constructed AuthClient")
            hold.finish()
            await first.value
            return
        }
        await Task.yield()
    }

    #expect(model.isSigningIn)
    #expect(!model.canSignIn)
    #expect(model.testingAuthClientCount == 1)

    let second = Task { await model.signIn() }
    await Task.yield()
    #expect(model.testingAuthClientCount == 1)

    hold.finish()
    await first.value
    await second.value
    #expect(!model.isSigningIn)
    #expect(model.testingAuthClientCount == 1)
}

@Test("A warm transcript cache paints a static restored chat without network")
@MainActor
func warmTranscriptCachePaintsWithoutNetwork() async throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = ChatSession(
        id: "restored-chat",
        title: "Restored",
        lastActive: Date(timeIntervalSince1970: 1_700_000_000),
        messageCount: 4
    )
    let messages = [
        ChatMessage(id: .server(ServerMessageID(rawValue: 1)), role: .user, text: "Hello"),
        ChatMessage(id: .server(ServerMessageID(rawValue: 2)), role: .assistant, text: "Hi", isStreaming: true)
    ]
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: session.id,
        serverTotal: 2,
        fetchedRows: 2,
        projectedMessages: 2,
        truncated: false,
        fetchedAt: Date(timeIntervalSince1970: 0)
    )
    let history = HistoryCache(directory: directory)
    _ = await history.store(messages, snapshot: snapshot, for: session.id)
    let list = SessionListCache(directory: directory)
    #expect(list.saveSessions([session]))
    #expect(list.saveSelectedSessionID(session.id))
    let source = LaunchRestoreProbeSource()
        let model = AppModel(
            cache: history,
            transcriptSource: source,
            warmStore: TranscriptWarmStore()
        )
        model.cacheEnabled = true

        model.publishRestoredTranscript()

    #expect(model.phase == .restoring)
    #expect(model.messages.map(\.text) == ["Hello", "Hi"])
    #expect(model.messages.allSatisfy { !$0.isStreaming })
    #expect(!model.isAwaitingReply)
    #expect(source.touchCount == 0)
    model.cancelOpenPreparation()
}

@Test("AppModel init does not open the search index before first paint")
@MainActor
func appModelInitDoesNotOpenSearchIndex() async throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let searchURL = directory.appendingPathComponent("search.sqlite")
    let model = AppModel(cache: HistoryCache(directory: directory))

    #expect(model.searchQuerying == nil)
    #expect(!FileManager.default.fileExists(atPath: searchURL.path))

    await model.attachSearchIndexIfNeeded()

    #expect(model.searchQuerying != nil)
    #expect(FileManager.default.fileExists(atPath: searchURL.path))
}

@Test("Unchanged network reconcile does not republish or rebuild painted rows")
@MainActor
func unchangedNetworkReconcileDoesNotRepublishOrRebuildRows() async throws {
    _ = NSApplication.shared
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = ChatSession(
        id: "restored-chat",
        title: "Restored",
        lastActive: Date(timeIntervalSince1970: 1_700_000_000),
        messageCount: 4
    )
    let messages = [
        ChatMessage(id: .server(ServerMessageID(rawValue: 1)), role: .user, text: "Hello"),
        ChatMessage(
            id: .server(ServerMessageID(rawValue: 2)),
            role: .assistant,
            text: "Hi",
            isStreaming: true
        )
    ]
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: session.id,
        serverTotal: 2,
        fetchedRows: 2,
        projectedMessages: 2,
        truncated: false,
        fetchedAt: Date(timeIntervalSince1970: 0)
    )
    let history = HistoryCache(directory: directory)
    _ = await history.store(messages, snapshot: snapshot, for: session.id)
    let list = SessionListCache(directory: directory)
    #expect(list.saveSessions([session]))
    #expect(list.saveSelectedSessionID(session.id))
    let rows = [
        launchRestoreTranscriptRow(id: 1, role: "user", text: "Hello"),
        launchRestoreTranscriptRow(id: 2, role: "assistant", text: "Hi")
    ]
    let source = LaunchRestoreMatchingSource(rows: rows)
    let model = AppModel(
        cache: history,
        transcriptSource: source,
        warmStore: TranscriptWarmStore()
    )
    model.cacheEnabled = true
    model.publishRestoredTranscript()

    #expect(model.messages.map(\.text) == ["Hello", "Hi"])
    #expect(model.messages.allSatisfy { !$0.isStreaming })
    let revision = model.transcriptRevision
    let identities = model.messages.map(\.id)

    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = launchRestoreAttachedTranscriptRoot(container)
    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: nil,
            route: nil,
            summary: nil,
            revision: revision,
            isReadOnly: false,
            isStreaming: false,
            findQuery: "",
            pendingMessageID: nil,
            findMessageID: nil,
            showsMetadata: false,
            publishedTail: model.messages,
            onCopyCode: { _ in },
            onPaint: { _ in }
        )
    )
    root.layoutSubtreeIfNeeded()
    let table = container.tableView
    #expect(table.numberOfRows > 0)
    let painted = try #require(
        table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TranscriptTurnRowView
    )

    model.phase = .ready
    await model.reconcileRestoredSessionIfNeeded()

    #expect(model.transcriptRevision == revision)
    #expect(model.messages.map(\.id) == identities)
    #expect(model.messages.map(\.text) == ["Hello", "Hi"])
    #expect(model.selectedSessionID == session.id)

    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: model.activeTranscriptStore,
            route: model.activeTranscriptRoute,
            summary: model.transcriptSummary,
            revision: model.transcriptRevision,
            isReadOnly: false,
            isStreaming: false,
            findQuery: "",
            pendingMessageID: nil,
            findMessageID: nil,
            showsMetadata: false,
            publishedTail: model.messages,
            onCopyCode: { _ in },
            onPaint: { _ in }
        )
    )
    root.layoutSubtreeIfNeeded()
    table.layoutSubtreeIfNeeded()
    let attached = try #require(
        table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? TranscriptTurnRowView
    )
    #expect(attached === painted)
    coordinator.dismantle(container: container)
}

@Test("launch-restore of a long paged chat paints the tail without a selection change — sidecar present")
@MainActor
func launchRestoreLongPagedChatPaintsTailWhenSidecarIsPresent() async throws {
    try await launchRestoreLongPagedChatPaintsTail(source: .sidecar)
}

@Test("launch-restore of a long paged chat paints the tail without a selection change — sidecar absent")
@MainActor
func launchRestoreLongPagedChatPaintsTailWhenSidecarIsAbsent() async throws {
    try await launchRestoreLongPagedChatPaintsTail(source: .pagedStoreOnly)
}

@Test("launch-restore fills an empty sidecar from the cache-resident visible tail")
@MainActor
func launchRestoreFillsEmptySidecarFromVisibleTail() async throws {
    try await launchRestoreLongPagedChatPaintsTail(source: .visibleTailOnly)
}

@Test("publishRestoredTranscript attaches a long paged store without requestOpen")
@MainActor
func publishRestoredTranscriptAttachesLongPagedStoreWithoutRequestOpen() async throws {
    try await launchRestoreLongPagedChatPaintsTail(
        source: .pagedStoreOnly,
        requestOpenAfterPublish: false
    )
}

@Test("Selecting a chat persists the id for the next launch")
@MainActor
func selectingAChatPersistsForNextLaunch() async throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = ChatSession(id: "first", title: "First", lastActive: Date(timeIntervalSince1970: 1))
    let second = ChatSession(id: "second", title: "Second", lastActive: Date(timeIntervalSince1970: 2))
    let list = SessionListCache(directory: directory)
    #expect(list.saveSessions([first, second]))
    let model = AppModel(
        cache: HistoryCache(directory: directory),
        transcriptSource: LaunchRestoreSilentSource()
    )
    model.phase = .ready
    _ = model.requestOpen(second)
    #expect(SessionListCache(directory: directory).loadSelectedSessionID() == "second")

    let relaunched = AppModel(cache: HistoryCache(directory: directory))
    #expect(relaunched.selectedSessionID == "second")
}

private enum LaunchRestoreTailSource {
    case sidecar
    case visibleTailOnly
    case pagedStoreOnly
}

private let launchRestoreLongRowCount = 240
private let launchRestoreTailText = "restore-tail-unique"
private let launchRestoreHeadText = "restore-head-unique"

@MainActor
private func launchRestoreLongPagedChatPaintsTail(
    source: LaunchRestoreTailSource,
    requestOpenAfterPublish: Bool = true
) async throws {
    _ = NSApplication.shared
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = ChatSession(
        id: "restore-long",
        title: "Restored long",
        lastActive: Date(timeIntervalSince1970: 1_700_000_000),
        messageCount: launchRestoreLongRowCount
    )
    let messages = launchRestoreLongMessages()
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: session.id,
        serverTotal: launchRestoreLongRowCount,
        fetchedRows: launchRestoreLongRowCount,
        projectedMessages: launchRestoreLongRowCount,
        truncated: false,
        fetchedAt: Date(timeIntervalSince1970: 0)
    )
    var history = HistoryCache(directory: directory)
    switch source {
    case .sidecar:
        _ = await history.store(messages, snapshot: snapshot, for: session.id)
        _ = try await history.pagedStore(for: session.id)
    case .visibleTailOnly:
        _ = await history.store(messages, snapshot: snapshot, for: session.id)
        launchRestoreRemoveSidecar(in: directory, sessionID: session.id)
        history = HistoryCache(directory: directory)
    case .pagedStoreOnly:
        let store = try await history.pagedStore(for: session.id)
        for (index, message) in messages.enumerated() {
            _ = try await store.append(launchRestoreWireRecord(message, index: index))
        }
    }
    let list = SessionListCache(directory: directory)
    #expect(list.saveSessions([session]))
    #expect(list.saveSelectedSessionID(session.id))
    let model = AppModel(
        cache: history,
        transcriptSource: LaunchRestoreSilentSource(),
        warmStore: TranscriptWarmStore()
    )
    model.cacheEnabled = true
    #expect(model.phase == .restoring)
    #expect(model.selectedSessionID == session.id)

    model.publishRestoredTranscript()
    let selected = model.selectedSessionID
    if requestOpenAfterPublish {
        let openTask = model.requestOpen(session)
        await openTask.value
    }
    #expect(model.selectedSessionID == selected)
    #expect(model.selectedSessionID == session.id)
    let storeAttached = await launchRestoreWaitForStore(model)
    #expect(storeAttached)

    switch source {
    case .sidecar, .visibleTailOnly:
        #expect(!model.messages.isEmpty)
        #expect(model.messages.last?.text == launchRestoreTailText)
    case .pagedStoreOnly:
        break
    }

    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = launchRestoreAttachedTranscriptRoot(container)
    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: model.activeTranscriptStore,
            route: model.activeTranscriptRoute,
            summary: model.transcriptSummary,
            revision: model.transcriptRevision,
            isReadOnly: false,
            isStreaming: false,
            findQuery: "",
            pendingMessageID: nil,
            findMessageID: nil,
            showsMetadata: false,
            publishedTail: model.messages,
            paintIdentity: "live:\(session.id)",
            onCopyCode: { _ in },
            onPaint: { _ in }
        )
    )
    root.layoutSubtreeIfNeeded()
    let table = container.tableView
    let attachRows = table.numberOfRows
    let expectedAttachRows = model.messages.isEmpty ? 0 : CachedTranscript(
        version: HistoryCache.version,
        messages: model.messages,
        snapshot: nil
    ).turns.count
    #expect(attachRows == expectedAttachRows)
    #expect(attachRows != launchRestoreLongRowCount)

    var paintedTail = false
    for _ in 0..<200 {
        await launchRestoreDrainMainQueueOnce()
        root.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        if table.numberOfRows == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            continue
        }
        if launchRestoreTableContains(table, text: launchRestoreTailText) {
            paintedTail = true
            break
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(paintedTail)
    #expect(model.selectedSessionID == session.id)
    coordinator.dismantle(container: container)
    model.cancelOpenPreparation()
}

private func launchRestoreLongMessages() -> [ChatMessage] {
    (0..<launchRestoreLongRowCount).map { index in
        let text: String
        if index == 0 {
            text = launchRestoreHeadText
        } else if index == launchRestoreLongRowCount - 1 {
            text = launchRestoreTailText
        } else {
            text = "row \(index)"
        }
        return ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: text
        )
    }
}

private func launchRestoreWireRecord(_ message: ChatMessage, index: Int) -> WireMessageRecord {
    let id: String
    switch message.id {
    case .server(let value): id = String(value.rawValue)
    case .provisional(let value): id = value.uuidString
    }
    return WireMessageRecord(
        messageID: id.isEmpty ? "m-\(index)" : id,
        role: message.role.rawValue,
        text: message.text
    )
}

private func launchRestoreRemoveSidecar(in directory: URL, sessionID: String) {
    let encoded = sessionID.utf8.reduce(into: "") { result, byte in
        if (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122) {
            result.append(Character(UnicodeScalar(byte)))
        } else {
            result += String(format: "%%%02X", byte)
        }
    }
    let url = directory.appendingPathComponent("tail-\(encoded).json")
    try? FileManager.default.removeItem(at: url)
}

@MainActor
private func launchRestoreWaitForStore(_ model: AppModel) async -> Bool {
    if model.activeTranscriptStore != nil { return true }
    for _ in 0..<400 {
        try? await Task.sleep(nanoseconds: 5_000_000)
        if model.activeTranscriptStore != nil { return true }
    }
    return false
}

@MainActor
private func launchRestoreDrainMainQueueOnce() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

@MainActor
private func launchRestoreTableContains(_ table: NSTableView, text: String) -> Bool {
    guard table.numberOfRows > 0 else { return false }
    for row in 0..<table.numberOfRows {
        guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTurnRowView
        else { continue }
        if launchRestoreRowText(view).contains(text) { return true }
    }
    let last = table.numberOfRows - 1
    guard let view = table.view(atColumn: 0, row: last, makeIfNecessary: true) as? TranscriptTurnRowView
    else { return false }
    return view.accessibilityLabel() != "Loading transcript row"
        && launchRestoreRowText(view).contains(text)
}

@MainActor
private func launchRestoreRowText(_ view: NSView) -> String {
    var parts: [String] = []
    var stack = [view]
    while let current = stack.popLast() {
        if let textView = current as? NSTextView {
            parts.append(textView.string)
        }
        stack.append(contentsOf: current.subviews)
    }
    return parts.joined()
}

private struct LaunchRestoreSilentSource: TranscriptSource {
    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        AuthoritativeTranscript(rows: [], serverTotal: 0)
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        ResumedTranscript(liveSessionID: nil, rows: [])
    }
}

private final class LaunchRestoreProbeSource: TranscriptSource, @unchecked Sendable {
    private let touches = OSAllocatedUnfairLock(initialState: 0)

    var touchCount: Int {
        touches.withLock { $0 }
    }

    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        touches.withLock { $0 += 1 }
        return AuthoritativeTranscript(rows: [], serverTotal: 0)
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        touches.withLock { $0 += 1 }
        return ResumedTranscript(liveSessionID: nil, rows: [])
    }
}

private struct LaunchRestoreMatchingSource: TranscriptSource {
    let rows: [JSONValue]

    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        AuthoritativeTranscript(rows: rows, serverTotal: rows.count)
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        ResumedTranscript(liveSessionID: nil, rows: rows, messageCount: rows.count)
    }
}

private func launchRestoreTranscriptRow(id: Int64, role: String, text: String) -> JSONValue {
    .object([
        "id": .integer(id),
        "role": .string(role),
        "text": .string(text)
    ])
}

@MainActor
private func launchRestoreAttachedTranscriptRoot(
    _ container: BlockTranscriptContainerView
) -> NSView {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 420))
    root.addSubview(container)
    NSLayoutConstraint.activate([
        container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        container.topAnchor.constraint(equalTo: root.topAnchor),
        container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])
    root.layoutSubtreeIfNeeded()
    return root
}


@MainActor
private final class LaunchRestoreSignInHold {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func wait() async throws {
        if finished { return }
        try await withCheckedThrowingContinuation { continuation in
            if finished {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func finish() {
        finished = true
        continuation?.resume()
        continuation = nil
    }
}

private func launchRestoreTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalLaunchRestore-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
