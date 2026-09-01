import AppKit
import Foundation
import HermternalCore
import Testing
@testable import Hermternal

/// Launch used to order an empty shell front, then attach. The first
/// visible frame must already hold the cached workspace.
@Test("launch contract: content attaches before the window orders front")
@MainActor
func launchContentAttachesBeforeOrderFront() throws {
    _ = NSApplication.shared
    LaunchClock.resetForTests()
    LaunchClock.captureProcessStart()
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalTests.LaunchContent.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "HermternalTests.LaunchContent.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let model = AppModel(cache: HistoryCache(directory: directory))
    model.phase = .restoring
    let shell = MainShellViewController(
        appearance: AppearanceSettings(defaults: defaults),
        model: model,
        onModelStateChanged: {}
    )
    let window = launchStartupWindow()
    defer { window.close() }
    MainWindowStartupConfiguration.prepare(window, restoringFrameNamed: nil)
    #expect(window.contentViewController == nil)
    #expect(!window.isVisible)

    LaunchStartupContent.attachCachedWorkspace(shell, to: window, model: model)
    #expect(window.contentViewController === shell)
    #expect(!window.isVisible)
    #expect(LaunchClock.recordedMilliseconds(for: "window.contentReady") != nil)

    window.makeKeyAndOrderFront(nil)
    LaunchClock.mark("window.firstContentFrame")
    #expect(window.contentViewController === shell)
}

@Test("launch contract: first ordered frame has transcript, pin, and composer caret")
@MainActor
func launchComposerIsFirstResponderWhenTheWindowOrdersFront() async throws {
    _ = NSApplication.shared
    LaunchClock.resetForTests()
    LaunchClock.captureProcessStart()
    let directory = try launchStartupTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "HermternalTests.LaunchCaret.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let session = ChatSession(
        id: "restored-chat",
        title: "Restored",
        lastActive: Date(timeIntervalSince1970: 1_700_000_000),
        messageCount: 2
    )
    let messages = [
        ChatMessage(id: .server(ServerMessageID(rawValue: 1)), role: .user, text: "Hello"),
        ChatMessage(id: .server(ServerMessageID(rawValue: 2)), role: .assistant, text: "Hi")
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

    let model = AppModel(
        cache: history,
        transcriptSource: LaunchStartupSilentSource(),
        warmStore: TranscriptWarmStore()
    )
    model.cacheEnabled = true
    model.publishRestoredTranscript()
    #expect(!model.messages.isEmpty)

    let shell = MainShellViewController(
        appearance: AppearanceSettings(defaults: defaults),
        model: model,
        onModelStateChanged: {}
    )
    let window = launchStartupWindow()
    defer { window.close() }
    MainWindowStartupConfiguration.prepare(window, restoringFrameNamed: nil)
    LaunchStartupContent.attachCachedWorkspace(shell, to: window, model: model)
    shell.view.layoutSubtreeIfNeeded()

    let root = try #require(window.contentView)
    let container = try #require(LaunchStartupContent.transcriptContainer(in: root))
    #expect(container.tableView.numberOfRows > 0)
    #expect(TranscriptViewportAnchoring.isNearBottom(container.tableView))

    window.makeKeyAndOrderFront(nil)
    LaunchClock.mark("window.firstContentFrame")
    _ = LaunchStartupContent.focusComposer(in: window, model: model)
    let editor = try #require(LaunchStartupContent.composerEditor(in: root))
    #expect(window.firstResponder === editor)
    #expect(LaunchClock.recordedMilliseconds(for: "interactivity.composerCaret") != nil)
    model.cancelOpenPreparation()
}

@Test("launch contract: store attach after a bottom pin does not move the clip")
@MainActor
func launchStoreAttachReconcilesInPlaceWithoutScrollJump() async throws {
    _ = NSApplication.shared
    let directory = try launchStartupTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = ChatSession(
        id: "restored-chat",
        title: "Restored",
        lastActive: Date(timeIntervalSince1970: 1_700_000_000),
        messageCount: 2
    )
    let messages = [
        ChatMessage(id: .server(ServerMessageID(rawValue: 1)), role: .user, text: "Hello"),
        ChatMessage(id: .server(ServerMessageID(rawValue: 2)), role: .assistant, text: "Hi")
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
        launchStartupTranscriptRow(id: 1, role: "user", text: "Hello"),
        launchStartupTranscriptRow(id: 2, role: "assistant", text: "Hi")
    ]
    let source = LaunchStartupMatchingSource(rows: rows)
    let model = AppModel(
        cache: history,
        transcriptSource: source,
        warmStore: TranscriptWarmStore()
    )
    model.cacheEnabled = true
    model.publishRestoredTranscript()

    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = launchStartupAttachedTranscriptRoot(container)
    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: nil,
            route: nil,
            summary: nil,
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
    TranscriptViewportAnchoring.pinToBottom(container.tableView)
    #expect(TranscriptViewportAnchoring.isNearBottom(container.tableView))
    let clip = try #require(container.tableView.enclosingScrollView?.contentView)
    let originBefore = clip.bounds.origin.y
    let painted = try #require(
        container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TranscriptTurnRowView
    )

    model.phase = .ready
    await model.reconcileRestoredSessionIfNeeded()
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
    container.tableView.layoutSubtreeIfNeeded()
    await launchStartupDrainMainQueueOnce()
    root.layoutSubtreeIfNeeded()
    TranscriptViewportAnchoring.pinToBottom(container.tableView)

    #expect(model.messages.map(\.text) == ["Hello", "Hi"])
    #expect(TranscriptViewportAnchoring.isNearBottom(container.tableView))
    let attached = try #require(
        container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: false) as? TranscriptTurnRowView
    )
    #expect(attached === painted)
    #expect(abs(clip.bounds.origin.y - originBefore) <= 1)
    coordinator.dismantle(container: container)
    model.cancelOpenPreparation()
}

@MainActor
private func launchStartupWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(
            origin: .zero,
            size: MainWindowStartupConfiguration.defaultContentSize
        ),
        styleMask: [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    return window
}

private func launchStartupTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalLaunchStartup-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private func launchStartupAttachedTranscriptRoot(
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
private func launchStartupDrainMainQueueOnce() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

private func launchStartupTranscriptRow(id: Int64, role: String, text: String) -> JSONValue {
    .object([
        "id": .integer(id),
        "role": .string(role),
        "text": .string(text)
    ])
}

private struct LaunchStartupSilentSource: TranscriptSource {
    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        AuthoritativeTranscript(rows: [], serverTotal: 0)
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        ResumedTranscript(liveSessionID: nil, rows: [])
    }
}

private struct LaunchStartupMatchingSource: TranscriptSource {
    let rows: [JSONValue]

    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        AuthoritativeTranscript(rows: rows, serverTotal: rows.count)
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        ResumedTranscript(liveSessionID: nil, rows: rows, messageCount: rows.count)
    }
}
