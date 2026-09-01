import AppKit
import HermternalCore
import SwiftUI
import Testing
@testable import Hermternal

@Test("cache retains an unchanged page turn")
@MainActor
func cacheRetainsUnchangedPageTurn() {
    let turn = TranscriptTurn(id: "accepted", speaker: .hermes, answer: "accepted answer")
    let document = MarkdownDocument.parse(turn.answer).document
    var cache = BlockTranscriptView.Coordinator.MeasuredDocumentCache()
    var measureCount = 0

    let firstAccepted = cache.accept(document: document, for: turn, ordinal: 7, width: 420) { _, _, width in
        measureCount += 1
        return width + 12
    }
    #expect(firstAccepted)
    let retained = cache.accept(document: document, for: turn, ordinal: 7, width: 420) { _, _, width in
        measureCount += 1
        return width + 12
    }
    #expect(!retained)

    #expect(measureCount == 1)
    #expect(cache.documentCount == 1)
    #expect(cache.measurementCount == 1)
    #expect(cache.height(for: 7, turnID: turn.id, width: 420) == 432)
}


@Test("cache deduplicates widths above the reading cap")
@MainActor
func cacheDeduplicatesWidthsAboveReadingCap() {
    let turn = TranscriptTurn(id: "width", speaker: .hermes, answer: "width answer")
    let document = MarkdownDocument.parse(turn.answer).document
    let firstWidth = TranscriptRendererTestSeam.effectiveWidth(for: turn, availableWidth: 760)
    let secondWidth = TranscriptRendererTestSeam.effectiveWidth(for: turn, availableWidth: 1200)
    var cache = BlockTranscriptView.Coordinator.MeasuredDocumentCache()
    var measureCount = 0

    #expect(firstWidth == secondWidth)
    let accepted = cache.accept(document: document, for: turn, ordinal: 3, width: firstWidth) { _, _, width in
        measureCount += 1
        return width
    }
    #expect(accepted)
    let remeasured = cache.remeasureIfNeeded(turn: turn, ordinal: 3, width: secondWidth) { _, _, width in
        measureCount += 1
        return width
    }
    #expect(!remeasured)

    #expect(measureCount == 1)
    #expect(cache.height(for: 3, turnID: turn.id, width: secondWidth) == secondWidth)
}


@Test("cache rejects a stale disclosure height")
@MainActor
func cacheRejectsStaleDisclosureHeight() {
    let turn = TranscriptTurn(
        id: "expanded",
        speaker: .hermes,
        reasoning: TranscriptReasoning(id: "reasoning", text: "details"),
        answer: "answer"
    )
    let document = MarkdownDocument.parse(turn.answer).document
    let collapsed = BlockTranscriptView.Coordinator.MeasuredDocumentCache.DisclosureState()
    let expanded = BlockTranscriptView.Coordinator.MeasuredDocumentCache.DisclosureState(
        reasoningExpanded: true
    )
    var cache = BlockTranscriptView.Coordinator.MeasuredDocumentCache()

    cache.accept(
        document: document,
        for: turn,
        ordinal: 2,
        width: 400,
        disclosure: collapsed
    ) { _, _, _ in 120 }

    #expect(cache.height(for: 2, turn: turn, effectiveWidth: 400, disclosure: expanded) == nil)
    cache.store(
        height: 240,
        for: turn,
        ordinal: 2,
        effectiveWidth: 400,
        disclosure: expanded
    )
    #expect(cache.height(for: 2, turn: turn, effectiveWidth: 400, disclosure: collapsed) == nil)
    #expect(cache.height(for: 2, turn: turn, effectiveWidth: 400, disclosure: expanded) == 240)
}


@Test("revision cancellation retains cached document for remeasurement")
@MainActor
func revisionCancellationRetainsCachedDocumentForRemeasurement() {
    let turn = TranscriptTurn(id: "stale-width", speaker: .hermes, answer: "answer")
    let document = MarkdownDocument.parse(turn.answer).document
    let initialWidth = TranscriptRendererTestSeam.effectiveWidth(
        for: turn,
        availableWidth: 400
    )
    let resizedWidth = TranscriptRendererTestSeam.effectiveWidth(
        for: turn,
        availableWidth: 600
    )
    var cache = BlockTranscriptView.Coordinator.MeasuredDocumentCache()
    let accepted = cache.accept(document: document, for: turn, ordinal: 9, width: initialWidth) {
        _, _, _ in 144
    }
    var state = BlockTranscriptView.Coordinator.MeasurementBatchState()
    let active = state.begin()
    state.reset()

    #expect(accepted)
    #expect(!state.accepts(active.id))
    #expect(cache.document(for: turn) != nil)
    #expect(cache.height(
        for: 9,
        turn: turn,
        effectiveWidth: resizedWidth,
        disclosure: .init()
    ) == nil)
}

@Test("serialized measurement rescheduling waits for the active batch")
func serializedMeasurementReschedulingWaitsForActiveBatch() {
    var state = BlockTranscriptView.Coordinator.MeasurementBatchState()
    let first = state.begin()
    state.queueReschedule()

    #expect(state.accepts(first.id))
    #expect(state.reschedulePending)
    let finished = state.finish(first.id)
    let reschedule = state.takeReschedule()
    #expect(finished)
    #expect(reschedule)

    let second = state.begin()
    #expect(second.replaced == nil)
}

@Test("empty measurement work clears a queued reschedule")
func emptyMeasurementWorkClearsQueuedReschedule() {
    var state = BlockTranscriptView.Coordinator.MeasurementBatchState()
    let active = state.begin()
    state.queueReschedule()
    state.reset()

    #expect(!state.accepts(active.id))
    let reschedule = state.takeReschedule()
    #expect(!reschedule)
}

@Test("provisional transcript height is bounded at normal width")
@MainActor
func provisionalTranscriptHeightIsBoundedAtNormalWidth() {
    let turn = TranscriptTurn(
        id: "long",
        speaker: .hermes,
        answer: String(repeating: "x", count: 10_000)
    )
    let height = TranscriptRendererTestSeam.provisionalHeight(
        for: turn,
        availableWidth: 680,
        reasoningExpanded: false,
        toolsExpanded: false
    )

    #expect(height > 5_000)
    #expect(height < 20_000)
}

private actor CoordinatorPageStore: TranscriptTurnPageLocating {
    private let page: TranscriptTurnPage
    private var readCount = 0
    private var readWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(page: TranscriptTurnPage) {
        self.page = page
    }

    func turnPage(_ request: TranscriptTurnPageRequest) async throws -> TranscriptTurnPage {
        readCount += 1
        readWaiter?.resume()
        readWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return page
    }

    func locateTurn(messageID: String) async throws -> TurnLocation? { nil }

    func waitForRead() async {
        guard readCount == 0 else { return }
        await withCheckedContinuation { readWaiter = $0 }
    }

    func reads() -> Int { readCount }

    func releaseRead() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@Test("coordinator coalesces a repeated pending page")
@MainActor
func coordinatorCoalescesRepeatedPendingPage() async {
    _ = NSApplication.shared
    let turn = TranscriptTurn(id: "same-page", speaker: .hermes, answer: "answer")
    let page = TranscriptTurnPage(
        turns: [turn],
        startOrdinal: 0,
        nextOrdinal: 1,
        totalTurnCount: 1,
        hasMore: false
    )
    let store = CoordinatorPageStore(page: page)
    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let input = TranscriptRendererInput(
        store: store,
        route: TranscriptRoute(sessionID: "same-page"),
        summary: TranscriptSummary(rowCount: 1, messageCount: 1),
        revision: 0,
        isReadOnly: false,
        isStreaming: false,
        findQuery: "",
        pendingMessageID: nil,
        findMessageID: nil,
        showsMetadata: false,
        onCopyCode: { _ in },
        onPaint: { _ in }
    )

    let waiting = Task { await store.waitForRead() }
    coordinator.update(container: container, input: input)
    await waiting.value
    coordinator.update(container: container, input: input)
    let readCount = await store.reads()
    #expect(readCount == 1)
    await store.releaseRead()
    coordinator.dismantle(container: container)
}

@Test("cached published tail paints turns without a Loading placeholder")
@MainActor
func cachedPublishedTailPaintsWithoutLoadingPlaceholder() {
    _ = NSApplication.shared
    let messages = (0..<12).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "cached \(index)"
        )
    }
    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = attachedTranscriptRoot(container)
    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: nil,
            route: nil,
            summary: nil,
            revision: 0,
            isReadOnly: false,
            isStreaming: false,
            findQuery: "",
            pendingMessageID: nil,
            findMessageID: nil,
            showsMetadata: false,
            publishedTail: messages,
            onCopyCode: { _ in },
            onPaint: { _ in }
        )
    )
    root.layoutSubtreeIfNeeded()
    let table = container.tableView
    #expect(table.numberOfRows > 0)
    let view = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TranscriptTurnRowView
    #expect(view != nil)
    #expect(view?.accessibilityLabel() != "Loading transcript row")
    coordinator.dismantle(container: container)
}

@Test("store attach keeps painted published-tail rows for the same session")
@MainActor
func storeAttachKeepsPaintedPublishedTailRowsForTheSameSession() async throws {
    _ = NSApplication.shared
    let messages = (0..<4).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "cached \(index)"
        )
    }
    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = attachedTranscriptRoot(container)
    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: nil,
            route: nil,
            summary: nil,
            revision: 0,
            isReadOnly: false,
            isStreaming: false,
            findQuery: "",
            pendingMessageID: nil,
            findMessageID: nil,
            showsMetadata: false,
            publishedTail: messages,
            onCopyCode: { _ in },
            onPaint: { _ in }
        )
    )
    root.layoutSubtreeIfNeeded()
    let table = container.tableView
    let paintedRows = table.numberOfRows
    #expect(paintedRows > 0)
    let painted = try #require(
        table.view(atColumn: 0, row: 0, makeIfNecessary: true)
            as? TranscriptTurnRowView
    )
    let paintedLabel = painted.accessibilityLabel()
    #expect(paintedLabel != "Loading transcript row")

    // Hold the first store page. Teardown would show Loading placeholders
    // at the summary count before that page could land.
    let store = HeldTranscriptPageStore(
        page: TranscriptTurnPage(
            turns: [TranscriptTurn(id: "stale", speaker: .hermes, answer: "from store")],
            startOrdinal: 0,
            nextOrdinal: 1,
            totalTurnCount: 128,
            hasMore: false
        )
    )
    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: store,
            route: TranscriptRoute(sessionID: "restored-chat", generation: 7),
            summary: TranscriptSummary(rowCount: 128, messageCount: 128),
            revision: 1,
            isReadOnly: false,
            isStreaming: false,
            findQuery: "",
            pendingMessageID: nil,
            findMessageID: nil,
            showsMetadata: false,
            publishedTail: messages,
            onCopyCode: { _ in },
            onPaint: { _ in }
        )
    )
    root.layoutSubtreeIfNeeded()
    table.layoutSubtreeIfNeeded()
    #expect(table.numberOfRows == paintedRows)
    let attached = try #require(
        table.view(atColumn: 0, row: 0, makeIfNecessary: false)
            as? TranscriptTurnRowView
    )
    #expect(attached === painted)
    #expect(attached.accessibilityLabel() == paintedLabel)
    #expect(attached.accessibilityLabel() != "Loading transcript row")
    coordinator.dismantle(container: container)
    await store.releaseAllReads()
}

@Test("switching paint identity installs a new tail on the update turn")
@MainActor
func switchingPaintIdentityInstallsNewTailOnTheUpdateTurn() {
    _ = NSApplication.shared
    let first = (0..<4).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "first \(index)"
        )
    }
    let second = (0..<3).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index + 10))),
            role: .assistant,
            text: "second \(index)"
        )
    }
    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: nil,
            route: nil,
            summary: nil,
            revision: 0,
            isReadOnly: false,
            isStreaming: false,
            findQuery: "",
            pendingMessageID: nil,
            findMessageID: nil,
            showsMetadata: false,
            publishedTail: first,
            paintIdentity: "live:first",
            onCopyCode: { _ in },
            onPaint: { _ in }
        )
    )
    let table = container.tableView
    #expect(table.numberOfRows == 4)
    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: nil,
            route: nil,
            summary: nil,
            revision: 1,
            isReadOnly: false,
            isStreaming: false,
            findQuery: "",
            pendingMessageID: nil,
            findMessageID: nil,
            showsMetadata: false,
            publishedTail: second,
            paintIdentity: "live:second",
            onCopyCode: { _ in },
            onPaint: { _ in }
        )
    )
    #expect(table.numberOfRows == 3)
    coordinator.dismantle(container: container)
}

@Test("new-chat paint identity stays stable through adopt-live")
func newChatPaintIdentityStaysStableThroughAdoptLive() {
    let before = TranscriptPaintIdentity.make(
        archivedSessionID: nil,
        selectedSessionID: nil,
        liveSessionID: "durable-chat"
    )
    let after = TranscriptPaintIdentity.make(
        archivedSessionID: nil,
        selectedSessionID: "durable-chat",
        liveSessionID: "durable-chat"
    )
    #expect(before == "live:durable-chat")
    #expect(after == before)
    #expect(
        TranscriptPaintIdentity.make(
            archivedSessionID: nil,
            selectedSessionID: nil,
            liveSessionID: nil
        ) == "live:none"
    )
    #expect(
        TranscriptPaintIdentity.make(
            archivedSessionID: "old",
            selectedSessionID: "durable-chat",
            liveSessionID: "durable-chat"
        ) == "archived:old"
    )
}

@Test("new-chat send paints the published tail and streams across the durable flip")
@MainActor
func newChatSendPaintsPublishedTailAndStreamsAcrossDurableFlip() async throws {
    _ = NSApplication.shared
    let user = ChatMessage(
        id: .server(ServerMessageID(rawValue: 1)),
        role: .user,
        text: "Hello from new chat"
    )
    var assistant = ChatMessage(
        id: .server(ServerMessageID(rawValue: 2)),
        role: .assistant,
        text: "Hi",
        isStreaming: true
    )
    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = attachedTranscriptRoot(container)
    let table = container.tableView

    coordinator.update(
        container: container,
        input: newChatPaintInput(
            paintIdentity: "new",
            publishedTail: [],
            revision: 0,
            isStreaming: false
        )
    )
    #expect(table.numberOfRows == 0)

    coordinator.update(
        container: container,
        input: newChatPaintInput(
            paintIdentity: "new",
            publishedTail: [user],
            revision: 1,
            isStreaming: true
        )
    )
    root.layoutSubtreeIfNeeded()
    #expect(table.numberOfRows == 1)
    let userRow = try #require(
        table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TranscriptTurnRowView
    )
    #expect(userRow.answerViewForTesting.string == "Hello from new chat")
    #expect(userRow.accessibilityLabel() != "Loading transcript row")

    let store = HeldTranscriptPageStore(
        page: TranscriptTurnPage(
            turns: CachedTranscript(
                version: HistoryCache.version,
                messages: [user],
                snapshot: nil
            ).turns,
            startOrdinal: 0,
            nextOrdinal: 1,
            totalTurnCount: 1,
            hasMore: false
        )
    )
    coordinator.update(
        container: container,
        input: newChatPaintInput(
            store: store,
            sessionID: "durable-chat",
            paintIdentity: "new",
            publishedTail: [user],
            revision: 2,
            isStreaming: true
        )
    )
    root.layoutSubtreeIfNeeded()
    #expect(table.numberOfRows == 1)
    let afterStore = try #require(
        table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? TranscriptTurnRowView
    )
    #expect(afterStore === userRow)
    #expect(afterStore.answerViewForTesting.string == "Hello from new chat")

    coordinator.update(
        container: container,
        input: newChatPaintInput(
            store: store,
            sessionID: "durable-chat",
            paintIdentity: "new",
            publishedTail: [user, assistant],
            revision: 3,
            isStreaming: true
        )
    )
    root.layoutSubtreeIfNeeded()
    #expect(table.numberOfRows == 2)
    let streamed = try #require(
        table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? TranscriptTurnRowView
    )
    #expect(streamed.answerViewForTesting.string == "Hi")

    coordinator.update(
        container: container,
        input: newChatPaintInput(
            store: store,
            sessionID: "durable-chat",
            paintIdentity: "live:durable-chat",
            publishedTail: [user, assistant],
            revision: 4,
            isStreaming: true
        )
    )
    root.layoutSubtreeIfNeeded()
    #expect(table.numberOfRows == 2)
    let afterFlipUser = try #require(
        table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? TranscriptTurnRowView
    )
    #expect(afterFlipUser === userRow)
    #expect(afterFlipUser.answerViewForTesting.string == "Hello from new chat")

    assistant.text = "Hi there"
    coordinator.update(
        container: container,
        input: newChatPaintInput(
            store: store,
            sessionID: "durable-chat",
            paintIdentity: "live:durable-chat",
            publishedTail: [user, assistant],
            revision: 5,
            isStreaming: true
        )
    )
    root.layoutSubtreeIfNeeded()
    #expect(table.numberOfRows == 2)
    let afterDelta = try #require(
        table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? TranscriptTurnRowView
    )
    #expect(afterDelta.answerViewForTesting.string == "Hi there")
    #expect(afterDelta.accessibilityLabel() != "Loading transcript row")

    coordinator.dismantle(container: container)
    await store.releaseAllReads()
}

@Test("new-chat send paints when the live store is already attached")
@MainActor
func newChatSendPaintsWhenLiveStoreIsAlreadyAttached() {
    _ = NSApplication.shared
    let user = ChatMessage(
        id: .server(ServerMessageID(rawValue: 1)),
        role: .user,
        text: "First prompt"
    )
    let assistant = ChatMessage(
        id: .server(ServerMessageID(rawValue: 2)),
        role: .assistant,
        text: "Reply",
        isStreaming: true
    )
    let store = HeldTranscriptPageStore(
        page: TranscriptTurnPage(
            turns: [],
            startOrdinal: 0,
            nextOrdinal: 0,
            totalTurnCount: 0,
            hasMore: false
        )
    )
    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = attachedTranscriptRoot(container)
    let table = container.tableView

    coordinator.update(
        container: container,
        input: newChatPaintInput(
            store: store,
            sessionID: "ephemeral",
            paintIdentity: "new",
            publishedTail: [],
            revision: 0,
            isStreaming: false
        )
    )
    #expect(table.numberOfRows == 0)

    coordinator.update(
        container: container,
        input: newChatPaintInput(
            store: store,
            sessionID: "ephemeral",
            paintIdentity: "new",
            publishedTail: [user],
            revision: 1,
            isStreaming: true
        )
    )
    root.layoutSubtreeIfNeeded()
    #expect(table.numberOfRows == 1)
    let userRow = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TranscriptTurnRowView
    #expect(userRow?.answerViewForTesting.string == "First prompt")

    coordinator.update(
        container: container,
        input: newChatPaintInput(
            store: store,
            sessionID: "ephemeral",
            paintIdentity: "new",
            publishedTail: [user, assistant],
            revision: 2,
            isStreaming: true
        )
    )
    root.layoutSubtreeIfNeeded()
    #expect(table.numberOfRows == 2)
    let reply = table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? TranscriptTurnRowView
    #expect(reply?.answerViewForTesting.string == "Reply")

    coordinator.dismantle(container: container)
}

@Test("store attach does not expand table rows on the update turn")
@MainActor
func storeAttachDoesNotExpandTableRowsOnTheUpdateTurn() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "btv-page-defer-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PagedTranscriptStore(sessionID: "restored-chat", directory: directory)
    try await store.load()
    for index in 0..<80 {
        _ = try await store.append(
            WireMessageRecord(messageID: "m-\(index)", text: "row \(index)")
        )
    }
    let route = try await store.currentRoute()
    let messages = (0..<4).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "cached \(index)"
        )
    }
    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = attachedTranscriptRoot(container)
    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: nil,
            route: nil,
            summary: nil,
            revision: 0,
            isReadOnly: false,
            isStreaming: false,
            findQuery: "",
            pendingMessageID: nil,
            findMessageID: nil,
            showsMetadata: false,
            publishedTail: messages,
            onCopyCode: { _ in },
            onPaint: { _ in }
        )
    )
    root.layoutSubtreeIfNeeded()
    let table = container.tableView
    let paintedRows = table.numberOfRows
    #expect(paintedRows == 4)

    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: store,
            route: route,
            summary: TranscriptSummary(rowCount: 80, messageCount: 80),
            revision: 1,
            isReadOnly: false,
            isStreaming: false,
            findQuery: "",
            pendingMessageID: nil,
            findMessageID: nil,
            showsMetadata: false,
            publishedTail: messages,
            onCopyCode: { _ in },
            onPaint: { _ in }
        )
    )
    #expect(table.numberOfRows == paintedRows)

    var expanded = false
    for _ in 0..<200 {
        await drainMainQueueOnce()
        if table.numberOfRows == 80 {
            expanded = true
            break
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    root.layoutSubtreeIfNeeded()
    #expect(expanded)
    #expect(table.numberOfRows == 80)
    coordinator.dismantle(container: container)
}

@Test("store attach with an empty published tail expands on the next turn")
@MainActor
func storeAttachWithEmptyPublishedTailExpandsOnTheNextTurn() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "btv-empty-attach-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PagedTranscriptStore(sessionID: "restored-long", directory: directory)
    try await store.load()
    let rowCount = 240
    for index in 0..<rowCount {
        _ = try await store.append(
            WireMessageRecord(
                messageID: "m-\(index)",
                text: index == rowCount - 1 ? "restore-tail-unique" : "row \(index)"
            )
        )
    }
    let route = try await store.currentRoute()
    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = attachedTranscriptRoot(container)
    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: nil,
            route: nil,
            summary: nil,
            revision: 0,
            isReadOnly: false,
            isStreaming: false,
            findQuery: "",
            pendingMessageID: nil,
            findMessageID: nil,
            showsMetadata: false,
            publishedTail: [],
            paintIdentity: "live:restored-long",
            onCopyCode: { _ in },
            onPaint: { _ in }
        )
    )
    root.layoutSubtreeIfNeeded()
    let table = container.tableView
    #expect(table.numberOfRows == 0)

    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: store,
            route: route,
            summary: TranscriptSummary(rowCount: rowCount, messageCount: rowCount),
            revision: 1,
            isReadOnly: false,
            isStreaming: false,
            findQuery: "",
            pendingMessageID: nil,
            findMessageID: nil,
            showsMetadata: false,
            publishedTail: [],
            paintIdentity: "live:restored-long",
            onCopyCode: { _ in },
            onPaint: { _ in }
        )
    )
    #expect(table.numberOfRows == 0)

    var expanded = false
    for _ in 0..<200 {
        await drainMainQueueOnce()
        if table.numberOfRows == rowCount {
            expanded = true
            break
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    root.layoutSubtreeIfNeeded()
    table.layoutSubtreeIfNeeded()
    #expect(expanded)
    #expect(table.numberOfRows == rowCount)
    let last = try #require(
        table.view(atColumn: 0, row: rowCount - 1, makeIfNecessary: true) as? TranscriptTurnRowView
    )
    #expect(last.accessibilityLabel() != "Loading transcript row")
    coordinator.dismantle(container: container)
}

@Test("renderer maps viewport inputs through the Core policy")
func rendererMapsViewportInputsThroughCorePolicy() {
    #expect(
        TranscriptRendererTestSeam.viewportTarget(
            pendingMessageID: "explicit-message",
            findMessageID: "find-message",
            isStreaming: true,
            isNearBottom: true,
            routeChanged: true,
            currentTarget: .message(id: "older-message")
        ) == .message(id: "explicit-message")
    )
    #expect(
        TranscriptRendererTestSeam.viewportTarget(
            pendingMessageID: nil,
            findMessageID: "find-message",
            isStreaming: true,
            isNearBottom: true,
            routeChanged: true,
            currentTarget: .message(id: "older-message")
        ) == .message(id: "find-message")
    )
    #expect(
        TranscriptRendererTestSeam.viewportTarget(
            pendingMessageID: nil,
            findMessageID: nil,
            isStreaming: true,
            isNearBottom: true,
            routeChanged: false,
            currentTarget: .message(id: "older-message")
        ) == .bottom
    )
    #expect(
        TranscriptRendererTestSeam.viewportTarget(
            pendingMessageID: nil,
            findMessageID: nil,
            isStreaming: true,
            isNearBottom: false,
            routeChanged: false,
            currentTarget: .message(id: "older-message")
        ) == .message(id: "older-message")
    )
}

@Test("renderer disclosure buttons send the configured turn identity")
@MainActor
func rendererDisclosureButtonsSendConfiguredTurnIdentity() throws {
    _ = NSApplication.shared
    let row = TranscriptTurnRowView(frame: .zero)
    let turn = TranscriptTurn(
        id: "turn-42",
        speaker: .hermes,
        reasoning: TranscriptReasoning(id: "reasoning-42", text: "reasoning"),
        tools: [TranscriptToolRun(id: "tool-42", name: "tool")],
        answer: "answer"
    )
    var reasoningID: String?
    var toolsID: String?
    row.configure(
        turn: turn,
        document: nil,
        reasoningExpanded: false,
        toolsExpanded: false,
        showsMetadata: false,
        findQuery: "",
        onReasoning: { reasoningID = $0 },
        onTools: { toolsID = $0 },
        onCopyCode: { _ in }
    )

    let reasoningButton = row.reasoningButtonForTesting
    let toolsButton = row.toolsButtonForTesting
    #expect(!reasoningButton.isHidden)
    #expect(!toolsButton.isHidden)

    let reasoningAction = try #require(reasoningButton.action)
    let toolsAction = try #require(toolsButton.action)
    #expect(NSApplication.shared.sendAction(
        reasoningAction,
        to: reasoningButton.target,
        from: reasoningButton
    ))
    #expect(NSApplication.shared.sendAction(
        toolsAction,
        to: toolsButton.target,
        from: toolsButton
    ))
    #expect(reasoningID == turn.id)
    #expect(toolsID == turn.id)
}

@Test("renderer preserves inline Markdown semantics as AppKit attributes")
func rendererPreservesInlineMarkdownSemantics() throws {
    let document = MarkdownDocument.parse(
        "**strong** *emphasis* ~~strike~~ `code` [link](https://example.com/path)"
    ).document
    let rendered = TranscriptRendererTestSeam.attributedAnswer(document)
    let source = rendered.string as NSString

    func attributes(for text: String) throws -> [NSAttributedString.Key: Any] {
        let range = source.range(of: text)
        let location = try #require(range.location == NSNotFound ? nil : range.location)
        return rendered.attributes(at: location, effectiveRange: nil)
    }

    let strongFont = try #require(try attributes(for: "strong")[.font] as? NSFont)
    #expect(NSFontManager.shared.traits(of: strongFont).contains(.boldFontMask))
    let emphasisFont = try #require(try attributes(for: "emphasis")[.font] as? NSFont)
    #expect(NSFontManager.shared.traits(of: emphasisFont).contains(.italicFontMask))
    let strike = try #require(try attributes(for: "strike")[.strikethroughStyle] as? NSNumber)
    #expect(strike.intValue == NSUnderlineStyle.single.rawValue)
    let codeFont = try #require(try attributes(for: "code")[.font] as? NSFont)
    #expect(codeFont.fontName.localizedCaseInsensitiveContains("mono"))
    let link = try #require(try attributes(for: "link")[.link] as? URL)
    #expect(link == URL(string: "https://example.com/path"))
}

@Test("renderer ignores a completed locate for a stale viewport target")
func rendererIgnoresStaleLocatedMessage() {
    #expect(!TranscriptRendererTestSeam.acceptsLocatedMessage(
        "previous-find-message",
        currentTarget: .message(id: "next-find-message")
    ))
    #expect(TranscriptRendererTestSeam.acceptsLocatedMessage(
        "active-find-message",
        currentTarget: .message(id: "active-find-message")
    ))
}

@Test("renderer consumes a pending target before Find takes control")
func rendererConsumesPendingTargetBeforeFindTakesControl() {
    let pending = TranscriptRendererTestSeam.activePendingMessageID(
        pendingMessageID: "pending-message",
        consumedPendingMessageID: nil
    )
    #expect(pending == "pending-message")
    #expect(
        TranscriptRendererTestSeam.activePendingMessageID(
            pendingMessageID: "pending-message",
            consumedPendingMessageID: "pending-message"
        ) == nil
    )
    #expect(
        TranscriptRendererTestSeam.viewportTarget(
            pendingMessageID: nil,
            findMessageID: "find-message",
            isStreaming: false,
            isNearBottom: false,
            routeChanged: false,
            currentTarget: .message(id: "pending-message")
        ) == .message(id: "find-message")
    )
}

@Test("renderer preserves quote and footnote block attributes")
func rendererPreservesQuoteAndFootnoteBlockAttributes() throws {
    let rendered = TranscriptRendererTestSeam.attributedAnswer(
        MarkdownDocument.parse("> quoted\n\n[^note]: footnote").document
    )
    let source = rendered.string as NSString

    func attributes(for text: String) throws -> [NSAttributedString.Key: Any] {
        let range = source.range(of: text)
        let location = try #require(range.location == NSNotFound ? nil : range.location)
        return rendered.attributes(at: location, effectiveRange: nil)
    }

    let quote = try attributes(for: "quoted")
    let quoteColor = try #require(quote[.foregroundColor] as? NSColor)
    #expect(quoteColor.isEqual(NSColor.secondaryLabelColor))
    let quoteParagraph = try #require(quote[.paragraphStyle] as? NSParagraphStyle)
    #expect(quoteParagraph.headIndent == 10)
    #expect(quoteParagraph.firstLineHeadIndent == 10)
    let footnoteFont = try #require(try attributes(for: "footnote")[.font] as? NSFont)
    #expect(footnoteFont.pointSize == NSFont.preferredFont(forTextStyle: .footnote).pointSize)
}

@MainActor
private final class TranscriptTableLayoutFixture: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let turns = [
        TranscriptTurn(
            id: "assistant",
            speaker: .hermes,
            answer: "Assistant messages keep a readable line length when the transcript table lays out."
        ),
        TranscriptTurn(
            id: "user",
            speaker: .me,
            answer: "User messages also keep their readable trailing-aligned text width."
        )
    ]

    func numberOfRows(in tableView: NSTableView) -> Int { turns.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let view = tableView.makeView(
            withIdentifier: TranscriptTurnRowView.identifier,
            owner: self
        ) as? TranscriptTurnRowView
        else { return nil }
        view.configure(
            turn: turns[row],
            document: nil,
            reasoningExpanded: false,
            toolsExpanded: false,
            showsMetadata: false,
            findQuery: "",
            onReasoning: { _ in },
            onTools: { _ in },
            onCopyCode: { _ in }
        )
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 160 }
}

@Test("renderer rows keep document width through table layout and resize")
@MainActor
func rendererRowsKeepDocumentWidthThroughTableLayoutAndResize() throws {
    _ = NSApplication.shared
    let fixture = TranscriptTableLayoutFixture()
    let table = BlockTranscriptTableView()
    table.headerView = nil
    table.intercellSpacing = .zero
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
    table.dataSource = fixture
    table.delegate = fixture

    let container = BlockTranscriptContainerView(tableView: table)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 480))
    root.addSubview(container)
    NSLayoutConstraint.activate([
        container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        container.topAnchor.constraint(equalTo: root.topAnchor),
        container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])

    func laidOutRow(_ ordinal: Int) throws -> TranscriptTurnRowView {
        root.layoutSubtreeIfNeeded()
        container.layoutTableDocument()
        table.layoutSubtreeIfNeeded()
        let row = try #require(
            table.view(atColumn: 0, row: ordinal, makeIfNecessary: true)
                as? TranscriptTurnRowView
        )
        row.layoutSubtreeIfNeeded()
        return row
    }

    table.reloadData()
    let assistantRow = try laidOutRow(0)
    let userRow = try laidOutRow(1)
    let column = try #require(table.tableColumns.first)
    let initialTableWidth = table.bounds.width
    let initialAssistantTextWidth = assistantRow.answerViewForTesting.bounds.width

    #expect(initialTableWidth >= 700)
    #expect(abs(column.width - initialTableWidth) < 1)
    #expect(assistantRow.bounds.width >= initialTableWidth - 1)
    // A window wider than the readable measure fills the column, never the row.
    // The agent text is the column less the gutter the mark stands in.
    #expect(
        abs(
            initialAssistantTextWidth
                - (MessageTypography.contentColumn(in: initialTableWidth)
                    - MessageTypography.hermesIndent)
        ) < 1
    )
    #expect(initialAssistantTextWidth < initialTableWidth - 200)
    // An outgoing row hugs its text on first layout. The column cap is the
    // ceiling, not the first width.
    let userTurn = TranscriptTurn(
        id: "user",
        speaker: .me,
        answer: "User messages also keep their readable trailing-aligned text width."
    )
    let userCap = MessageTypography.outgoingTextMeasure(
        in: MessageTypography.contentColumn(in: initialTableWidth)
    )
    let userHug = TranscriptRendererTestSeam.measuredLayout(
        for: userTurn,
        document: MarkdownDocument.parse(userTurn.answer).document,
        width: userCap
    ).textWidth
    #expect(abs(userRow.answerViewForTesting.bounds.width - userHug) < 1)
    #expect(userRow.answerViewForTesting.bounds.width < userCap - 50)
    // One measure for both speakers: the mark's gutter and the bubble's box
    // take the same 36 and 35 points out of the same column. The assistant
    // fills that measure. The user hugs inside it.
    #expect(abs(initialAssistantTextWidth - userCap) <= 1)

    // A window narrower than the readable measure: the column is the window
    // less its two gutters, so both speakers narrow with it.
    root.frame.size.width = 360
    let resizedAssistantRow = try laidOutRow(0)
    let resizedUserRow = try laidOutRow(1)
    let resizedTableWidth = table.bounds.width
    let resizedColumn = MessageTypography.contentColumn(in: resizedTableWidth)

    #expect(resizedTableWidth < initialTableWidth - 300)
    #expect(abs(column.width - resizedTableWidth) < 1)
    #expect(resizedAssistantRow.bounds.width >= resizedTableWidth - 1)
    #expect(
        abs(
            resizedAssistantRow.answerViewForTesting.bounds.width
                - (resizedColumn - MessageTypography.hermesIndent)
        ) < 1
    )
    #expect(
        abs(
            resizedUserRow.answerViewForTesting.bounds.width
                - MessageTypography.outgoingTextMeasure(in: resizedColumn)
        ) < 1
    )
    #expect(
        resizedAssistantRow.answerViewForTesting.bounds.width
            < initialAssistantTextWidth - 100
    )
}

@Test("the width toggle gives both speakers the window and gives it back")
@MainActor
func widthToggleGivesBothSpeakersTheWindowAndGivesItBack() throws {
    _ = NSApplication.shared
    let fixture = TranscriptTableLayoutFixture()
    let table = BlockTranscriptTableView()
    table.headerView = nil
    table.intercellSpacing = .zero
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
    table.dataSource = fixture
    table.delegate = fixture

    let container = BlockTranscriptContainerView(tableView: table)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 480))
    root.addSubview(container)
    NSLayoutConstraint.activate([
        container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        container.topAnchor.constraint(equalTo: root.topAnchor),
        container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])
    defer {
        MessageTypography.widthMode = .standard
        container.stopObservingSystemChanges()
    }

    func laidOutRow(_ ordinal: Int) throws -> TranscriptTurnRowView {
        root.layoutSubtreeIfNeeded()
        container.layoutTableDocument()
        table.layoutSubtreeIfNeeded()
        let row = try #require(
            table.view(atColumn: 0, row: ordinal, makeIfNecessary: true)
                as? TranscriptTurnRowView
        )
        row.layoutSubtreeIfNeeded()
        return row
    }

    table.reloadData()
    _ = try laidOutRow(0)
    _ = try laidOutRow(1)
    let tableWidth = table.bounds.width
    #expect(tableWidth > MessageTypography.readingMeasure + 400)

    MessageTypography.widthMode = .full
    container.applyTranscriptMeasure()
    let fullAgent = try laidOutRow(0)
    let fullUser = try laidOutRow(1)
    let fullColumn = MessageTypography.contentColumn(in: tableWidth)

    // Every materialised row resolves the new measure in `layout`, so the agent
    // text is the window less its gutters and the mark's own gutter.
    #expect(
        abs(
            fullAgent.answerViewForTesting.bounds.width
                - (fullColumn - MessageTypography.hermesIndent)
        ) < 1
    )
    // The bubble's tail tip lands on the same column's trailing edge, so a
    // bubble ends exactly where the answer above it ends, in either measure.
    // Its text width waits for the next measurement, which is the same latency
    // a window resize has; the column does not.
    let fullColumnTrailing = (tableWidth + fullColumn) / 2
    #expect(
        abs(fullUser.bubbleForTesting.frame.maxX - fullColumnTrailing) < 1.5
    )
    #expect(fullColumnTrailing > (tableWidth + MessageTypography.readingMeasure) / 2)
    #expect(
        fullAgent.answerViewForTesting.bounds.width
            > MessageTypography.readingMeasure
    )

    MessageTypography.widthMode = .standard
    container.applyTranscriptMeasure()
    let backAgent = try laidOutRow(0)
    #expect(
        abs(
            backAgent.answerViewForTesting.bounds.width
                - (MessageTypography.readingMeasure - MessageTypography.hermesIndent)
        ) < 1
    )
    let standardColumnTrailing =
        (tableWidth + MessageTypography.readingMeasure) / 2
    let backUser = try laidOutRow(1)
    #expect(
        abs(backUser.bubbleForTesting.frame.maxX - standardColumnTrailing) < 1.5
    )
}

@Test("the measure a reader chooses reaches the transcript through the store")
@MainActor
func chosenMeasureReachesTheTranscriptThroughTheStore() throws {
    _ = NSApplication.shared
    let fixture = TranscriptTableLayoutFixture()
    let table = BlockTranscriptTableView()
    table.headerView = nil
    table.intercellSpacing = .zero
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
    table.dataSource = fixture
    table.delegate = fixture

    let container = BlockTranscriptContainerView(tableView: table)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 480))
    root.addSubview(container)
    NSLayoutConstraint.activate([
        container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        container.topAnchor.constraint(equalTo: root.topAnchor),
        container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])

    let suiteName = "HermternalTests.TranscriptWidthStore.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let appearance = AppearanceSettings(defaults: defaults)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        MessageTypography.widthMode = .standard
        container.stopObservingSystemChanges()
    }

    func laidOutRow(_ ordinal: Int) throws -> TranscriptTurnRowView {
        root.layoutSubtreeIfNeeded()
        container.layoutTableDocument()
        table.layoutSubtreeIfNeeded()
        let row = try #require(
            table.view(atColumn: 0, row: ordinal, makeIfNecessary: true)
                as? TranscriptTurnRowView
        )
        row.layoutSubtreeIfNeeded()
        return row
    }

    table.reloadData()
    let standardWidth = try laidOutRow(0).answerViewForTesting.bounds.width

    // The whole path, not the handler: the settings object writes the measure,
    // persists it, and posts; the container's own observer invalidates; the rows
    // resolve the new column in `layout`. All of it inside this one call, which
    // is the contract — the store's observers are main-actor and synchronous, so
    // the toolbar and the transcript can never state two different measures.
    // This test therefore never suspends, which also keeps the process-wide
    // measure it sets out of every other test's way.
    appearance.toggleTranscriptWidth()

    #expect(MessageTypography.widthMode == .full)

    // The row's own width is what decides its column, so that is what the
    // expectation is built from. Reading it off the table instead would race
    // the document resize the invalidation kicks off.
    let row = try laidOutRow(0)
    let expected = MessageTypography.contentColumn(in: row.bounds.width)
        - MessageTypography.hermesIndent
    let width = row.answerViewForTesting.bounds.width

    #expect(abs(width - expected) < 1)
    #expect(width > standardWidth + 100)
    #expect(row.bounds.width > MessageTypography.readingMeasure + 400)
}

@MainActor
private final class TranscriptDisclosureLayoutFixture:
    NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var reasoningExpanded = false
    var toolsExpanded = false

    private let turn = TranscriptTurn(
        id: "disclosed",
        speaker: .hermes,
        reasoning: TranscriptReasoning(id: "reasoning", text: "reasoning detail"),
        tools: [TranscriptToolRun(id: "tool", name: "tool")],
        answer: "The agent answer sits below both disclosure bands."
    )

    func numberOfRows(in tableView: NSTableView) -> Int { 1 }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let view = tableView.makeView(
            withIdentifier: TranscriptTurnRowView.identifier,
            owner: self
        ) as? TranscriptTurnRowView
        else { return nil }
        view.configure(
            turn: turn,
            document: nil,
            reasoningExpanded: reasoningExpanded,
            toolsExpanded: toolsExpanded,
            showsMetadata: false,
            findQuery: "",
            onReasoning: { _ in },
            onTools: { _ in },
            onCopyCode: { _ in }
        )
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 320 }
}

@Test("renderer disclosure bands draw a whole title at the row's leading edge")
@MainActor
func rendererDisclosureBandsDrawWholeTitleAtLeadingEdge() throws {
    _ = NSApplication.shared
    let fixture = TranscriptDisclosureLayoutFixture()
    let table = BlockTranscriptTableView()
    table.headerView = nil
    table.intercellSpacing = .zero
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
    table.dataSource = fixture
    table.delegate = fixture

    let container = BlockTranscriptContainerView(tableView: table)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 480))
    root.addSubview(container)
    NSLayoutConstraint.activate([
        container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        container.topAnchor.constraint(equalTo: root.topAnchor),
        container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])

    func laidOutRow() throws -> TranscriptTurnRowView {
        root.layoutSubtreeIfNeeded()
        container.layoutTableDocument()
        table.layoutSubtreeIfNeeded()
        let row = try #require(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? TranscriptTurnRowView
        )
        row.layoutSubtreeIfNeeded()
        return row
    }

    /// Checks one band against the width the row actually gave it.
    func expectWholeTitle(_ button: NSButton, _ expected: String) throws {
        let cell = try #require(button.cell as? NSButtonCell)
        let titleRect = cell.titleRect(forBounds: button.bounds)
        let naturalWidth = button.attributedTitle.size().width

        #expect(button.attributedTitle.string == expected)
        // The premise. The band spans the whole row, so a title rect centred
        // on the band lands hundreds of points from the text it labels.
        #expect(button.bounds.width >= 400)
        #expect(naturalWidth >= 20)
        // The whole title is drawn. A 13pt title rect tightens "Reasoning"
        // and clips it to two overlapping glyphs.
        #expect(titleRect.width + 0.5 >= naturalWidth)
        // The title starts beside the leading edge, not at the band's centre.
        #expect(titleRect.minX <= MessageTypography.hermesIndent)
        // The band must not outgrow the height every measured row reserves for
        // it, or every cached row height is short by the difference and the
        // last line of the answer is clipped.
        #expect(
            button.intrinsicContentSize.height
                <= MessageTypography.disclosureHeight
        )
        #expect(button.font?.pointSize == 15)
        let titleFont = button.attributedTitle.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? NSFont
        #expect(titleFont?.pointSize == 15)
        let traits = titleFont?.fontDescriptor.object(forKey: .traits)
            as? [NSFontDescriptor.TraitKey: Any]
        let weight = traits?[.weight] as? CGFloat ?? 0
        #expect(abs(weight - NSFont.Weight.semibold.rawValue) < 0.05)
        #expect(button.contentTintColor == .secondaryLabelColor)
        #expect(button.image != nil)
        // A band announces the state it is in.
        #expect(button.accessibilityLabel() == expected)
    }

    table.reloadData()
    let collapsed = try laidOutRow()
    try expectWholeTitle(collapsed.reasoningButtonForTesting, "Reasoning")
    try expectWholeTitle(collapsed.toolsButtonForTesting, "Tools")

    fixture.reasoningExpanded = true
    fixture.toolsExpanded = true
    table.reloadData()
    let expanded = try laidOutRow()
    try expectWholeTitle(expanded.reasoningButtonForTesting, "Hide reasoning")
    try expectWholeTitle(expanded.toolsButtonForTesting, "Hide tools")
}

/// A table fixture with a height for each row that a test can change.
///
/// The fixture gives one height for each row. A test changes a height and then
/// tells the table, which is the sequence the renderer performs.
@MainActor
private final class TranscriptViewportHeightFixture:
    NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var heights: [CGFloat]

    init(heights: [CGFloat]) {
        self.heights = heights
    }

    func numberOfRows(in tableView: NSTableView) -> Int { heights.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? { NSView() }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        heights[row]
    }
}

/// A real scroll view over a real transcript table.
///
/// The table owns its row rectangles and its document height. The harness reads
/// every coordinate back from the table, so the tests assume no row origin, no
/// document height, and no inset that the resolved table style adds.
///
/// `topInset` is the transcript's own top content inset. It defaults to zero,
/// which is the uninset arithmetic every other test here measures.
@MainActor
private struct TranscriptViewportHarness {
    let fixture: TranscriptViewportHeightFixture
    let table: BlockTranscriptTableView
    let scrollView: NSScrollView

    init(
        heights: [CGFloat],
        viewportHeight: CGFloat,
        width: CGFloat = 700,
        topInset: CGFloat = 0
    ) {
        fixture = TranscriptViewportHeightFixture(heights: heights)
        table = BlockTranscriptTableView()
        table.headerView = nil
        table.intercellSpacing = .zero
        table.rowSizeStyle = .custom
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: .init("transcript"))
        column.resizingMask = .autoresizingMask
        column.width = width
        table.addTableColumn(column)
        table.dataSource = fixture
        table.delegate = fixture
        table.translatesAutoresizingMaskIntoConstraints = true
        table.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: width, height: viewportHeight)
        )
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = table
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        scrollView.tile()
        table.reloadData()
        fitDocumentHeight()
    }

    var clip: NSClipView { scrollView.contentView }

    /// The document height that the table reports.
    var documentHeight: CGFloat { table.bounds.height }

    /// The top edge of one row, as the table reports it.
    func rowOrigin(_ ordinal: Int) -> CGFloat { table.rect(ofRow: ordinal).minY }

    func scroll(to origin: CGFloat) {
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: origin))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Tells the table about changed heights, as the renderer does.
    func correctHeights(_ rows: IndexSet) {
        table.noteHeightOfRows(withIndexesChanged: rows)
        fitDocumentHeight()
    }

    /// Makes the document tall enough to hold the last row.
    ///
    /// The table sets its own height when it retiles. This method keeps that
    /// height, and it supplies the height from the last row rectangle if the
    /// table did not do the work. It never removes a trailing inset.
    private func fitDocumentHeight() {
        guard !fixture.heights.isEmpty else { return }
        let bottom = table.rect(ofRow: fixture.heights.count - 1).maxY
        if table.frame.height < bottom {
            table.frame.size.height = bottom
        }
    }
}

@Test("renderer preserves the transcript anchor across a correction above the viewport")
@MainActor
func rendererPreservesTranscriptAnchorAcrossCorrectionAboveViewport() throws {
    _ = NSApplication.shared
    let harness = TranscriptViewportHarness(
        heights: Array(repeating: 100, count: 40),
        viewportHeight: 400
    )
    // A scroll test needs a document that is taller than its viewport.
    #expect(harness.documentHeight > harness.clip.bounds.height + 3000)

    // The reader stops 30 points into row 12.
    let readerOrigin = harness.rowOrigin(12) + 30
    harness.scroll(to: readerOrigin)
    #expect(abs(harness.clip.bounds.origin.y - readerOrigin) < 0.5)

    let anchor = try #require(TranscriptViewportAnchoring.anchor(in: harness.table))
    let offset = anchor.documentOrigin - anchor.rowOrigin
    #expect(anchor.ordinal == 12)
    #expect(abs(anchor.rowOrigin - harness.rowOrigin(12)) < 0.5)
    #expect(abs(anchor.documentOrigin - readerOrigin) < 0.5)
    #expect(abs(offset - 30) < 0.5)

    // Five rows above the viewport each grow by 50 points.
    let growth: CGFloat = 250
    for row in 0..<5 { harness.fixture.heights[row] += 50 }
    harness.correctHeights(IndexSet(integersIn: 0..<5))
    #expect(abs(harness.rowOrigin(12) - (anchor.rowOrigin + growth)) < 0.5)
    // The correction alone leaves the reader 250 points back in the text.
    #expect(abs(harness.clip.bounds.origin.y - readerOrigin) < 0.5)

    TranscriptViewportAnchoring.restore(anchor, in: harness.table)

    #expect(abs(harness.clip.bounds.origin.y - (readerOrigin + growth)) < 0.5)
    let restored = try #require(TranscriptViewportAnchoring.anchor(in: harness.table))
    #expect(restored.ordinal == anchor.ordinal)
    #expect(abs((restored.documentOrigin - restored.rowOrigin) - offset) < 0.5)
}

@Test("renderer pins the streaming end again after a height correction")
@MainActor
func rendererPinsStreamingEndAgainAfterHeightCorrection() {
    _ = NSApplication.shared
    let harness = TranscriptViewportHarness(
        heights: Array(repeating: 100, count: 40),
        viewportHeight: 400
    )
    #expect(harness.documentHeight > harness.clip.bounds.height + 3000)

    TranscriptViewportAnchoring.pinToBottom(harness.table)
    let pinned = harness.clip.bounds.origin.y
    let documentBefore = harness.documentHeight
    #expect(abs(pinned - (documentBefore - harness.clip.bounds.height)) < 0.5)
    #expect(abs(harness.clip.bounds.maxY - documentBefore) < 0.5)
    #expect(TranscriptViewportAnchoring.isNearBottom(harness.table))

    // The streaming tail row grows by 300 points.
    let growth: CGFloat = 300
    harness.fixture.heights[39] += growth
    harness.correctHeights(IndexSet(integer: 39))
    #expect(abs(harness.documentHeight - (documentBefore + growth)) < 0.5)
    // The correction alone leaves the reader above the new end.
    #expect(abs(harness.clip.bounds.origin.y - pinned) < 0.5)
    #expect(!TranscriptViewportAnchoring.isNearBottom(harness.table))

    TranscriptViewportAnchoring.pinToBottom(harness.table)
    #expect(abs(harness.clip.bounds.origin.y - (pinned + growth)) < 0.5)
    #expect(abs(harness.clip.bounds.maxY - harness.documentHeight) < 0.5)
    #expect(TranscriptViewportAnchoring.isNearBottom(harness.table))
}

/// The deepest ink of the window's own toolbar controls, in points down from
/// the physical window top.
///
/// Measured at true 2x on macOS 26.6.2: the New Chat and Reload group is 70pt
/// wide and 35.5pt tall, 8pt down the window, so its bottom edge is 43.5pt
/// down. It is opaque, and an outgoing bubble is trailing aligned, so the
/// bubble travels straight under it.
private let measuredToolbarControlDepth: CGFloat = 43.5

@Test("the transcript's top dissolve begins at the window's top edge")
@MainActor
func transcriptTopEdgeDissolvesFromTheWindowTop() throws {
    // The premise: the ramp crosses the whole band the system lays its
    // titlebar controls out in, and then some, so content is readable again
    // only below that band.
    #expect(ChatTranscriptTopEdge.chromeDepth >= measuredToolbarControlDepth)
    #expect(ChatTranscriptTopEdge.reach > ChatTranscriptTopEdge.chromeDepth)

    let stops = ChatTranscriptTopEdge.ramp.stops
    var previousLocation: CGFloat = 0
    var previousAlpha: CGFloat = -1
    var curve: [(location: CGFloat, alpha: CGFloat)] = []
    for stop in stops {
        let color = try #require(NSColor(stop.color).usingColorSpace(.sRGB))
        // One continuous ramp: distance and ink only ever increase, so no
        // pair of stops can invert into a band or a seam.
        #expect(stop.location >= previousLocation)
        #expect(color.alphaComponent >= previousAlpha)
        previousLocation = stop.location
        previousAlpha = color.alphaComponent
        curve.append((stop.location, color.alphaComponent))
    }

    // The ramp spans its whole view, and it ends opaque: `reach` is where a
    // row is readable again.
    #expect(stops.first?.location == 0)
    let last = try #require(stops.last)
    #expect(last.location == 1)
    let opaque = try #require(NSColor(last.color).usingColorSpace(.sRGB))
    #expect(opaque.alphaComponent == 1)

    // Exactly one stop is clear, and it is the one at the window's top edge.
    // Two zero-alpha stops cannot interpolate to anything else between them,
    // so a second one is a flat clear zone — the empty band over the titlebar
    // that reads as chrome, and the defect this ramp exists to remove.
    #expect(curve.filter { $0.alpha == 0 }.count == 1)
    #expect(curve.first?.alpha == 0)

    // Ink under the toolbar controls: present, so rows visibly continue under
    // the chrome, and far from opaque, so nothing reaches a control's own edge
    // at full strength.
    let alphaAtControls = interpolatedAlpha(
        in: curve,
        atDepth: measuredToolbarControlDepth,
        reach: ChatTranscriptTopEdge.reach
    )
    #expect(alphaAtControls > 0.2)
    #expect(alphaAtControls < 0.7)

    // The content inset places the DOCUMENT's first point at the ramp's
    // opaque end, less the empty band every row opens with. The resolved
    // table style adds a document inset of its own above row 0, so the first
    // ink rests at or below `reach` and never above it.
    #expect(
        ChatTranscriptTopEdge.contentInset + MessageTypography.turnGap / 2
            == ChatTranscriptTopEdge.reach
    )
    #expect(ChatTranscriptTopEdge.contentInset > measuredToolbarControlDepth)
}

/// The ramp's alpha at one depth, read the way Core Animation reads it:
/// linearly between the two stops that bracket the depth.
private func interpolatedAlpha(
    in curve: [(location: CGFloat, alpha: CGFloat)],
    atDepth depth: CGFloat,
    reach: CGFloat
) -> CGFloat {
    let location = depth / reach
    guard let upperIndex = curve.firstIndex(where: { $0.location >= location })
    else {
        return curve.last?.alpha ?? 0
    }
    let upper = curve[upperIndex]
    guard upperIndex > 0 else { return upper.alpha }
    let lower = curve[upperIndex - 1]
    let span = upper.location - lower.location
    guard span > 0 else { return upper.alpha }
    return lower.alpha
        + (location - lower.location) / span * (upper.alpha - lower.alpha)
}

@Test("the transcript surface installs the top edge's content inset")
@MainActor
func transcriptSurfaceInstallsTopEdgeContentInset() {
    _ = NSApplication.shared
    let table = BlockTranscriptTableView()
    table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
    let container = BlockTranscriptContainerView(tableView: table)
    let scrollView = container.scrollViewForTesting

    // The automatic insets would derive this from a safe area the hosting
    // boundary clears, and overwrite it with zero.
    #expect(!scrollView.automaticallyAdjustsContentInsets)
    #expect(scrollView.contentInsets.top == ChatTranscriptTopEdge.contentInset)
    #expect(scrollView.scrollerInsets.top == ChatTranscriptTopEdge.contentInset)
    // Only the top edge. The composer owns the bottom one.
    #expect(scrollView.contentInsets.bottom == 0)
}

@Test("the transcript surface leaves the system no top scroll edge effect")
@MainActor
func transcriptSurfaceSuppressesTheSystemScrollEdgeEffect() throws {
    _ = NSApplication.shared
    let table = BlockTranscriptTableView()
    table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
    let container = BlockTranscriptContainerView(tableView: table)
    let scrollView = container.scrollViewForTesting

    // macOS 26 gives a scroll view in the titlebar safe area a plate over the
    // whole band and dissolves content at that band's lower edge. This window
    // draws its own top edge, from the physical window top, so the system's is
    // off. On a build with no such property there is no pocket to turn off.
    guard scrollView.responds(to: NSSelectorFromString("setAllowedPocketEdges:"))
    else { return }
    let edges = try #require(scrollView.value(forKey: "allowedPocketEdges") as? Int)
    #expect(edges == 0)
}

@Test("the sidebar list leaves the system no scroll edge effect")
@MainActor
func sidebarSurfaceSuppressesTheSystemScrollEdgeEffect() async throws {
    _ = NSApplication.shared
    let hosting = NSHostingView(rootView: SidebarPocketContractHarness())
    hosting.frame = NSRect(x: 0, y: 0, width: 250, height: 704)
    let window = NSWindow(
        contentRect: hosting.frame,
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.titlebarAppearsTransparent = true
    window.toolbar = NSToolbar()
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    defer {
        window.contentView = nil
        window.close()
    }
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()
    let suppressor = try #require(firstScrollEdgeEffectSuppressor(in: hosting))
    suppressor.suppressAttachedScrollViews()
    let attached = suppressor.attachedListScrollViews()
    #expect(!attached.isEmpty)
    let scrollView = try #require(attached.first)

    // macOS 26 gives a sidebar `ListCoreScrollView` the same titlebar pocket
    // the transcript already turns off. On a build with no such property
    // there is no pocket to turn off.
    guard scrollView.responds(to: NSSelectorFromString("setAllowedPocketEdges:"))
    else { return }
    let edges = try #require(scrollView.value(forKey: "allowedPocketEdges") as? Int)
    #expect(edges == 0)
    #expect(scrollView.systemScrollPocketViews.isEmpty)
}

/// A `.sidebar` `List` with the same AppKit host the column installs.
private struct SidebarPocketContractHarness: View {
    var body: some View {
        List(0..<20, id: \.self) { index in
            Text("session \(index)")
        }
        .listStyle(.sidebar)
        .background {
            ScrollEdgeEffectSuppressor()
                .allowsHitTesting(false)
        }
    }
}

@MainActor
private func firstScrollEdgeEffectSuppressor(
    in view: NSView
) -> ScrollEdgeEffectSuppressingView? {
    if let match = view as? ScrollEdgeEffectSuppressingView { return match }
    for subview in view.subviews {
        if let found = firstScrollEdgeEffectSuppressor(in: subview) { return found }
    }
    return nil
}


@Test("insetted transcript content rests below the chrome and keeps its anchor and its end")
@MainActor
func transcriptContentInsetKeepsRestingRowsOutOfTheChrome() throws {
    _ = NSApplication.shared
    let inset = ChatTranscriptTopEdge.contentInset
    let harness = TranscriptViewportHarness(
        heights: Array(repeating: 100, count: 40),
        viewportHeight: 400,
        topInset: inset
    )
    #expect(harness.documentHeight > harness.clip.bounds.height + 3000)
    // The premise of the ramp: a content inset adds scroll RANGE, it does not
    // shorten the viewport, so rows still travel under the chrome and have
    // something to dissolve into on the way.
    #expect(abs(harness.clip.bounds.height - 400) < 0.5)

    // The top of the scrollable range is one inset ABOVE the document's first
    // point, so the first row comes to rest below the chrome, not under it.
    harness.scroll(to: -inset)
    #expect(abs(harness.clip.bounds.origin.y + inset) < 0.5)
    // The row's SCREEN depth is measured from the clip origin, not from the
    // row rectangle: `rect(ofRow:)` is in document coordinates, and the
    // resolved table style adds its own inset above row 0 — 10pt, measured on
    // the Mac. A resting row therefore sits at the content inset PLUS that
    // document inset, so it can only ever be lower than the ramp, never
    // inside it.
    let documentTopInset = harness.rowOrigin(0)
    #expect(documentTopInset >= 0)
    let restingDepth = harness.rowOrigin(0) - harness.clip.bounds.origin.y
    #expect(abs(restingDepth - (inset + documentTopInset)) < 0.5)
    #expect(restingDepth >= inset - 0.5)
    #expect(restingDepth > measuredToolbarControlDepth)
    // The first ink of that row is at or below the ramp's opaque end, so no
    // part of a resting turn is inside the dissolve.
    #expect(
        restingDepth + MessageTypography.turnGap / 2
            >= ChatTranscriptTopEdge.reach - 0.5
    )

    // A height correction while parked at the top must not slide the document
    // up under the chrome. The policy clamps at the top of the range, and the
    // adapter is what tells it where that top now is.
    let parked = try #require(TranscriptViewportAnchoring.anchor(in: harness.table))
    #expect(parked.ordinal == 0)
    harness.fixture.heights[0] += 40
    harness.correctHeights(IndexSet(integer: 0))
    TranscriptViewportAnchoring.restore(parked, in: harness.table)
    #expect(abs(harness.clip.bounds.origin.y + inset) < 0.5)

    // A reader in the middle still keeps the anchor across a correction above
    // the viewport, exactly as an uninset transcript does.
    let readerOrigin = harness.rowOrigin(12) + 30
    harness.scroll(to: readerOrigin)
    let anchor = try #require(TranscriptViewportAnchoring.anchor(in: harness.table))
    #expect(anchor.ordinal == 12)
    let growth: CGFloat = 250
    for row in 0..<5 { harness.fixture.heights[row] += 50 }
    harness.correctHeights(IndexSet(integersIn: 0..<5))
    TranscriptViewportAnchoring.restore(anchor, in: harness.table)
    #expect(abs(harness.clip.bounds.origin.y - (readerOrigin + growth)) < 0.5)

    // The streaming end is untouched: the last row lands on the bottom edge
    // of the viewport, not one inset short of it.
    TranscriptViewportAnchoring.pinToBottom(harness.table)
    #expect(abs(harness.clip.bounds.maxY - harness.documentHeight) < 0.5)
    #expect(TranscriptViewportAnchoring.isNearBottom(harness.table))

    // A row arriving from above lands in the READABLE viewport.
    // `scrollRowToVisible` would align it with the clip view's own top edge,
    // which is the physical window top. This aligns the ROW rectangle with the
    // readable top, so the depth here is the content inset exactly, with no
    // document inset above it.
    TranscriptViewportAnchoring.scrollRowIntoView(0, in: harness.table)
    #expect(abs(harness.clip.bounds.origin.y - (harness.rowOrigin(0) - inset)) < 0.5)
    #expect(abs((harness.rowOrigin(0) - harness.clip.bounds.origin.y) - inset) < 0.5)
}

@Test("a transcript shorter than its viewport rests below the chrome")
@MainActor
func shortTranscriptRestsBelowTheChrome() throws {
    _ = NSApplication.shared
    let inset = ChatTranscriptTopEdge.contentInset
    let harness = TranscriptViewportHarness(
        heights: [100, 100],
        viewportHeight: 400,
        topInset: inset
    )
    #expect(harness.documentHeight < harness.clip.bounds.height)

    // One short chat is the launch case, and a document that cannot scroll
    // must still start below the chrome rather than under it.
    TranscriptViewportAnchoring.pinToBottom(harness.table)
    #expect(abs(harness.clip.bounds.origin.y + inset) < 0.5)
    let documentTopInset = harness.rowOrigin(0)
    let restingDepth = harness.rowOrigin(0) - harness.clip.bounds.origin.y
    #expect(abs(restingDepth - (inset + documentTopInset)) < 0.5)
    #expect(restingDepth >= inset - 0.5)
    #expect(restingDepth > measuredToolbarControlDepth)
    #expect(
        restingDepth + MessageTypography.turnGap / 2
            >= ChatTranscriptTopEdge.reach - 0.5
    )
    // The anchor a correction would restore is the resting one: the first row,
    // at the clip origin the inset defines.
    let parked = try #require(TranscriptViewportAnchoring.anchor(in: harness.table))
    #expect(parked.ordinal == 0)
    #expect(abs(parked.documentOrigin + inset) < 0.5)
    #expect(TranscriptViewportAnchoring.isNearBottom(harness.table))
}

@Test("a turn taller than the readable viewport lands at the readable top")
@MainActor
func oversizedJumpTargetLandsAtTheReadableTop() {
    _ = NSApplication.shared
    let inset = ChatTranscriptTopEdge.contentInset
    let harness = TranscriptViewportHarness(
        heights: [100, 100, 100, 500] + Array(repeating: 100, count: 20),
        viewportHeight: 400,
        topInset: inset
    )
    let readable = harness.clip.bounds.height - inset
    let tall = harness.table.rect(ofRow: 3)

    // The premise: this turn cannot be brought inside the readable viewport at
    // all, and from the top of the transcript it lies BELOW the viewport,
    // which is the branch that bottom-aligns.
    #expect(tall.height > readable)
    harness.scroll(to: -inset)
    #expect(tall.minY >= harness.clip.bounds.origin.y + inset)
    #expect(tall.maxY > harness.clip.bounds.maxY)

    TranscriptViewportAnchoring.scrollRowIntoView(3, in: harness.table)

    // Its beginning lands at the readable top, below the chrome. Bottom
    // alignment would have put that beginning at a depth of
    // 400 - 500 = -100pt: a whole turn's first lines under the toolbar.
    let depth = harness.rowOrigin(3) - harness.clip.bounds.origin.y
    #expect(abs(depth - inset) < 0.5)
    #expect(depth > measuredToolbarControlDepth)
    #expect(abs(harness.clip.bounds.origin.y - (tall.minY - inset)) < 0.5)
    // The turn still runs past the bottom of the viewport, because it cannot
    // fit; that is the case, not a failure of it.
    #expect(harness.clip.bounds.maxY < tall.maxY)

    // A turn that DOES fit still bottom-aligns, so the ordinary jump is
    // unchanged.
    let fitting = harness.table.rect(ofRow: 10)
    #expect(fitting.height < readable)
    #expect(fitting.maxY > harness.clip.bounds.maxY)
    TranscriptViewportAnchoring.scrollRowIntoView(10, in: harness.table)
    #expect(abs(harness.clip.bounds.maxY - fitting.maxY) < 0.5)
    #expect(fitting.minY - harness.clip.bounds.origin.y > inset)
}

@Test("retargeting a tall turn leaves a reader in the middle of it alone")
@MainActor
func retargetedTallTurnKeepsTheReaderInPlace() {
    _ = NSApplication.shared
    let inset = ChatTranscriptTopEdge.contentInset
    let harness = TranscriptViewportHarness(
        heights: [100, 100, 100, 500] + Array(repeating: 100, count: 20),
        viewportHeight: 400,
        topInset: inset
    )
    let readable = harness.clip.bounds.height - inset
    let tall = harness.table.rect(ofRow: 3)
    #expect(tall.height > readable)

    // The reader is 200pt into the turn: its first line is above the readable
    // top, and from that edge down there is nothing but this turn.
    let midTurn = tall.minY + 200 - inset
    harness.scroll(to: midTurn)
    #expect(abs(harness.clip.bounds.origin.y - midTurn) < 0.5)
    #expect(tall.minY < harness.clip.bounds.origin.y + inset)
    #expect(tall.maxY > harness.clip.bounds.origin.y + inset)

    // The renderer re-runs the same target for every publication that keeps
    // it. A turn this tall can never be contained in the readable viewport, so
    // re-aligning it would drag the reader back to its first line.
    TranscriptViewportAnchoring.scrollRowIntoView(3, in: harness.table)
    #expect(abs(harness.clip.bounds.origin.y - midTurn) < 0.5)

    // The boundary of that no-op. One body line of the turn's ink is the least
    // that is worth staying for; a row rectangle ends with the same empty
    // half-gap it begins with, so the ink ends there, not at `maxY`.
    let inkBottom = tall.maxY - MessageTypography.turnGap / 2
    let oneLine = inkBottom - MessageTypography.bodyLineHeight - inset
    harness.scroll(to: oneLine)
    #expect(abs(harness.clip.bounds.origin.y - oneLine) < 0.5)
    TranscriptViewportAnchoring.scrollRowIntoView(3, in: harness.table)
    #expect(abs(harness.clip.bounds.origin.y - oneLine) < 0.5)

    // One point further on there is less than a line left, so the turn is
    // brought back to its beginning even though it still crosses the readable
    // top. Coverage alone would have kept the reader here, looking at a line
    // and a half of nothing.
    harness.scroll(to: oneLine + 1)
    TranscriptViewportAnchoring.scrollRowIntoView(3, in: harness.table)
    #expect(abs((harness.rowOrigin(3) - harness.clip.bounds.origin.y) - inset) < 0.5)

    // The counterexample itself: only the trailing half-gap crosses the
    // readable top, so every glyph of the turn is already above the viewport.
    let gapOnly = inkBottom + MessageTypography.turnGap / 2 / 2 - inset
    harness.scroll(to: gapOnly)
    #expect(tall.minY <= harness.clip.bounds.origin.y + inset)
    #expect(tall.maxY > harness.clip.bounds.origin.y + inset)
    TranscriptViewportAnchoring.scrollRowIntoView(3, in: harness.table)
    #expect(abs((harness.rowOrigin(3) - harness.clip.bounds.origin.y) - inset) < 0.5)

    // Back to the middle for the fitting-row contrast below.
    harness.scroll(to: midTurn)

    // The no-op belongs to the tall turn alone: a turn that fits and is only
    // PARTLY readable is still aligned into the readable viewport.
    let partly = harness.table.rect(ofRow: 4)
    #expect(partly.height < readable)
    #expect(partly.minY < harness.clip.bounds.maxY)
    #expect(partly.maxY > harness.clip.bounds.maxY)
    TranscriptViewportAnchoring.scrollRowIntoView(4, in: harness.table)
    #expect(abs(harness.clip.bounds.maxY - partly.maxY) < 0.5)
    #expect(partly.minY - harness.clip.bounds.origin.y > inset)
}

/// A page store that holds every read until a test releases it.
///
/// The store keeps one continuation for each read, in the order that the reads
/// start. A test can release a read that a later route supersedes. The store has
/// no blocking wait. A test polls `startedReads()` under a deadline, so a read
/// that never arrives fails the test instead of stopping the suite.
private actor HeldTranscriptPageStore: TranscriptTurnPageLocating {
    private let page: TranscriptTurnPage
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var startCount = 0

    init(page: TranscriptTurnPage) {
        self.page = page
    }

    func turnPage(_ request: TranscriptTurnPageRequest) async throws -> TranscriptTurnPage {
        startCount += 1
        await withCheckedContinuation { pending.append($0) }
        return page
    }

    func locateTurn(messageID: String) async throws -> TurnLocation? { nil }

    func startedReads() -> Int { startCount }

    /// Releases the read that started first.
    func releaseFirstRead() -> Bool {
        guard !pending.isEmpty else { return false }
        pending.removeFirst().resume()
        return true
    }

    /// Releases every read that is still held.
    func releaseAllReads() {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

/// Waits for `condition` on the main actor, and gives up at the deadline.
///
/// The loop suspends between the tests of the condition, so the renderer's own
/// main-actor work can run. The result is `false` when the deadline passes. A
/// caller therefore fails fast and never stops the suite.
///
/// One attempt costs about 40 milliseconds under the test main actor, so the
/// default deadline is about 8 seconds. A measured renderer completion arrives
/// on the first attempt, which gives a margin of more than 100 times.
@MainActor
private func waitForCondition(
    attempts: Int = 200,
    _ condition: () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// Waits until `count` page reads have started, under the same deadline.
@MainActor
private func waitForStartedReads(
    _ store: HeldTranscriptPageStore,
    _ count: Int
) async -> Bool {
    await drainMainQueueOnce()
    for _ in 0..<200 {
        if await store.startedReads() >= count { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await store.startedReads() >= count
}

@MainActor
private func drainMainQueueOnce() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

@MainActor
private func newChatPaintInput(
    store: (any TranscriptTurnPageLocating)? = nil,
    sessionID: String? = nil,
    paintIdentity: String,
    publishedTail: [ChatMessage],
    revision: UInt64,
    isStreaming: Bool
) -> TranscriptRendererInput {
    TranscriptRendererInput(
        store: store,
        route: sessionID.map { TranscriptRoute(sessionID: $0) },
        summary: store == nil
            ? nil
            : TranscriptSummary(rowCount: publishedTail.count, messageCount: publishedTail.count),
        revision: revision,
        isReadOnly: false,
        isStreaming: isStreaming,
        findQuery: "",
        pendingMessageID: nil,
        findMessageID: nil,
        showsMetadata: false,
        publishedTail: publishedTail,
        paintIdentity: paintIdentity,
        onCopyCode: { _ in },
        onPaint: { _ in }
    )
}

@MainActor
private func viewportRendererInput(
    store: any TranscriptTurnPageLocating,
    sessionID: String,
    rowCount: Int,
    publishedTail: [ChatMessage] = []
) -> TranscriptRendererInput {
    TranscriptRendererInput(
        store: store,
        route: TranscriptRoute(sessionID: sessionID),
        summary: TranscriptSummary(rowCount: rowCount, messageCount: rowCount),
        revision: 0,
        // A read-only transcript never follows a stream, so the only viewport
        // movement in these tests is the height correction under test.
        isReadOnly: true,
        isStreaming: false,
        findQuery: "",
        pendingMessageID: nil,
        findMessageID: nil,
        showsMetadata: false,
        publishedTail: publishedTail,
        onCopyCode: { _ in },
        onPaint: { _ in }
    )
}

@MainActor
private func attachedTranscriptRoot(
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

@Test("renderer keeps the reader's row when a page correction lands above the viewport")
@MainActor
func rendererKeepsReaderRowWhenPageCorrectionLandsAboveViewport() async throws {
    _ = NSApplication.shared
    let pageRows = TranscriptPageRequestPlanner.pageSize
    let totalRows = pageRows + 32
    let turns = (0..<pageRows).map { ordinal in
        TranscriptTurn(
            id: "turn-\(ordinal)",
            speaker: .hermes,
            answer: String(repeating: "Corrected transcript text. ", count: 8)
        )
    }
    let store = HeldTranscriptPageStore(
        page: TranscriptTurnPage(
            turns: turns,
            startOrdinal: 0,
            nextOrdinal: pageRows,
            totalTurnCount: totalRows,
            hasMore: false
        )
    )
    // First attach no longer materializes summary.rowCount on the update
    // turn. Paint the same count from the published tail so the reader
    // can sit below the page that is still held.
    let publishedTail = (0..<totalRows).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: .assistant,
            text: "Placeholder transcript row."
        )
    }
    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = attachedTranscriptRoot(container)
    let table = container.tableView
    coordinator.update(
        container: container,
        input: viewportRendererInput(
            store: store,
            sessionID: "anchor",
            rowCount: totalRows,
            publishedTail: publishedTail
        )
    )
    #expect(await waitForStartedReads(store, 1))
    root.layoutSubtreeIfNeeded()
    container.layoutTableDocument()

    let clip = try #require(table.enclosingScrollView?.contentView)
    #expect(table.numberOfRows == totalRows)
    #expect(table.bounds.height > clip.bounds.height + 1000)

    // The reader stops six rows past the page that the store still holds.
    let anchorRow = pageRows + 6
    let readerOrigin = table.rect(ofRow: anchorRow).minY + 12
    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: readerOrigin))
    table.enclosingScrollView?.reflectScrolledClipView(clip)

    let loadingRowHeight = table.rect(ofRow: 0).height
    let before = try #require(TranscriptViewportAnchoring.anchor(in: table))
    #expect(before.ordinal == anchorRow)
    // Every row that the page corrects is above the viewport.
    #expect(table.rect(ofRow: pageRows - 1).maxY <= table.visibleRect.minY + 0.5)

    #expect(await store.releaseFirstRead())
    let corrected = await waitForCondition {
        table.rect(ofRow: 0).height > loadingRowHeight + 1
    }
    #expect(corrected)

    let after = try #require(TranscriptViewportAnchoring.anchor(in: table))
    #expect(after.ordinal == before.ordinal)
    #expect(
        abs(
            (after.documentOrigin - after.rowOrigin)
                - (before.documentOrigin - before.rowOrigin)
        ) < 1
    )
    #expect(container.superview === root)
    coordinator.dismantle(container: container)
    await store.releaseAllReads()
}

@Test("renderer ignores a page completion from a superseded generation")
@MainActor
func rendererIgnoresPageCompletionFromSupersededGeneration() async throws {
    _ = NSApplication.shared
    let rowCount = 128
    let store = HeldTranscriptPageStore(
        page: TranscriptTurnPage(
            turns: [TranscriptTurn(id: "stale", speaker: .hermes, answer: "stale answer")],
            startOrdinal: 0,
            nextOrdinal: 1,
            // A different total row count makes an accepted stale page visible.
            totalTurnCount: rowCount + 1,
            hasMore: false
        )
    )
    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = attachedTranscriptRoot(container)
    let table = container.tableView

    coordinator.update(
        container: container,
        input: viewportRendererInput(store: store, sessionID: "first", rowCount: rowCount)
    )
    #expect(await waitForStartedReads(store, 1))

    // A second route supersedes the first one and raises the generation.
    coordinator.update(
        container: container,
        input: viewportRendererInput(store: store, sessionID: "second", rowCount: rowCount)
    )
    #expect(await waitForStartedReads(store, 2))

    let origin = clipOrigin(of: table)
    let loadingRowHeight = table.rect(ofRow: 0).height
    #expect(table.numberOfRows == rowCount)

    #expect(await store.releaseFirstRead())
    // Wait for the superseded completion, and confirm that nothing moved. A
    // live completion lands on the first attempt, so 20 attempts is 20 times
    // the time an accepted page needs to become visible.
    let changed = await waitForCondition(attempts: 20) {
        table.numberOfRows != rowCount
            || table.rect(ofRow: 0).height > loadingRowHeight + 1
            || clipOrigin(of: table) != origin
    }
    #expect(!changed)
    #expect(table.numberOfRows == rowCount)
    #expect(abs(table.rect(ofRow: 0).height - loadingRowHeight) < 0.5)
    #expect(clipOrigin(of: table) == origin)
    #expect(container.superview === root)
    coordinator.dismantle(container: container)
    await store.releaseAllReads()
}

@MainActor
private func clipOrigin(of table: NSTableView) -> CGFloat {
    table.enclosingScrollView?.contentView.bounds.origin.y ?? 0
}


/// Height of the glyphs a text view holds, at the width it laid out.
///
/// The layout manager is the same path the view draws. A framesetter of the
/// same string can round a different last-line ascent, so the clip contract
/// reads the used rect with an unbounded container height.
@MainActor
private func naturalTextHeight(_ view: NSTextView) -> CGFloat {
    guard let manager = view.layoutManager, let container = view.textContainer else {
        return 0
    }
    let saved = container.containerSize
    container.containerSize = NSSize(
        width: max(1, view.bounds.width),
        height: .greatestFiniteMagnitude
    )
    manager.ensureLayout(for: container)
    let height = ceil(manager.usedRect(for: container).height)
    container.containerSize = saved
    manager.ensureLayout(for: container)
    return height
}

/// Height the stack's visible bands need at the widths they laid out.
@MainActor
private func arrangedContentHeight(_ row: TranscriptTurnRowView) -> CGFloat {
    let visible = row.arrangedSubviewsForTesting.filter { view in !view.isHidden }
    var height: CGFloat = 0
    for view in visible {
        if let text = view as? NSTextView {
            height += naturalTextHeight(text)
        } else {
            height += ceil(view.intrinsicContentSize.height)
        }
    }
    if visible.count > 1 {
        height += CGFloat(visible.count - 1) * row.stackSpacingForTesting
    }
    return height
}

/// One laid-out agent row, and the superview that publishes its width.
///
/// The column guide relates the row's content to the row's own `widthAnchor`.
/// A row with no superview has no layout engine to publish that width from its
/// frame. The caller keeps the root alive for as long as it reads frames.
@MainActor
private func laidOutAgentRow(
    turn: TranscriptTurn,
    document: MarkdownDocument,
    rowWidth: CGFloat = 780,
    rowHeight: CGFloat,
    reasoningExpanded: Bool = false,
    toolsExpanded: Bool = false
) -> (root: NSView, row: TranscriptTurnRowView) {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: rowHeight + 40))
    let row = TranscriptTurnRowView(
        frame: NSRect(x: 0, y: 0, width: rowWidth, height: rowHeight)
    )
    root.addSubview(row)
    row.configure(
        turn: turn,
        document: document,
        reasoningExpanded: reasoningExpanded,
        toolsExpanded: toolsExpanded,
        showsMetadata: true,
        findQuery: "",
        onReasoning: { _ in },
        onTools: { _ in },
        onCopyCode: { _ in }
    )
    row.layoutSubtreeIfNeeded()
    return (root, row)
}

/// The measured height the renderer gives one agent turn.
@MainActor
private func measuredAgentRowHeight(
    turn: TranscriptTurn,
    document: MarkdownDocument,
    availableWidth: CGFloat = 780,
    reasoningExpanded: Bool = false,
    toolsExpanded: Bool = false
) -> CGFloat {
    TranscriptRendererTestSeam.measuredLayout(
        for: turn,
        document: document,
        width: TranscriptRendererTestSeam.effectiveWidth(
            for: turn,
            availableWidth: availableWidth
        ),
        reasoningExpanded: reasoningExpanded,
        toolsExpanded: toolsExpanded
    ).height
}

/// A row runs top down, so the top of a band is the `minY` of its frame.
@MainActor
private func bandRect(_ view: NSView, in row: TranscriptTurnRowView) -> NSRect {
    row.convert(view.bounds, from: view)
}

@Test("the mark stands beside the first line of a wrapped assistant answer")
@MainActor
func markStandsBesideTheFirstLineOfAWrappedAnswer() {
    _ = NSApplication.shared
    let answer = String(
        repeating: "A real assistant paragraph that wraps at the reading measure. ",
        count: 8
    )
    let document = MarkdownDocument.parse(answer).document
    let turn = TranscriptTurn(
        id: "wrapped",
        speaker: .hermes,
        model: "hermes-1",
        answer: answer
    )
    let height = measuredAgentRowHeight(turn: turn, document: document)
    let laidOut = laidOutAgentRow(turn: turn, document: document, rowHeight: height)
    let row = laidOut.row
    let mark = bandRect(row.markViewForTesting, in: row)
    let answerBand = bandRect(row.answerViewForTesting, in: row)
    let band = MessageTypography.turnGap / 2

    #expect(!row.markViewForTesting.isHidden)
    // The premise. The answer holds several lines, so a mark placed by the
    // band's centre would stand lines away from the first one.
    #expect(answerBand.height >= 3 * MessageTypography.bodyLineHeight)
    // The answer is the first band of the turn. The mark takes no band of its
    // own, so nothing stands between the row's top and the first line.
    #expect(abs((answerBand.minY - row.bounds.minY) - band) < 0.5)

    // The mark stands in the gutter, and the text starts one indent to its
    // right.
    #expect(abs(mark.width - mark.height) < 0.5)
    #expect(abs(mark.width - MessageTypography.markSide) < 0.5)
    #expect(
        MessageTypography.markSide + MessageTypography.markGap
            == MessageTypography.hermesIndent
    )
    #expect(mark.maxX <= answerBand.minX)
    #expect(abs((answerBand.minX - mark.minX) - MessageTypography.hermesIndent) < 0.5)

    // The mark's box is taller than one line of body text, so the centred
    // position would put it above the top of the band. The box starts at the
    // top of the first band instead, as an avatar beside a message does, and it
    // never rises out of the turn.
    let font = NSFont.preferredFont(forTextStyle: .body)
    #expect(mark.height > font.ascender - font.descender)
    #expect(abs(mark.minY - answerBand.minY) <= 1)
    #expect(mark.maxY <= row.bounds.maxY)
    #expect(mark.minY >= row.bounds.minY)

    // The mark's depth is the turn's, never the row's. A taller row holds the
    // same turn at the same depth.
    let taller = laidOutAgentRow(
        turn: turn,
        document: document,
        rowHeight: height + 240
    )
    let tallerMark = bandRect(taller.row.markViewForTesting, in: taller.row)
    #expect(
        abs((tallerMark.minY - taller.row.bounds.minY) - (mark.minY - row.bounds.minY))
            < 0.5
    )
}

@Test("the mark stands beside the first band when reasoning and tools carry height")
@MainActor
func markStandsBesideTheFirstBandOfAChannelledTurn() {
    _ = NSApplication.shared
    let answer = String(
        repeating: "The assistant answers under its reasoning and its tools. ",
        count: 8
    )
    let document = MarkdownDocument.parse(answer).document
    let turn = TranscriptTurn(
        id: "channels",
        speaker: .hermes,
        model: "hermes-1",
        reasoning: TranscriptReasoning(
            id: "reasoning",
            text: String(repeating: "a line of real reasoning\n", count: 20),
            effort: "high"
        ),
        tools: [
            TranscriptToolRun(
                id: "tool",
                name: "shell",
                input: "ls -la",
                output: String(repeating: "a line of real output\n", count: 10)
            )
        ],
        answer: answer
    )
    let height = measuredAgentRowHeight(
        turn: turn,
        document: document,
        reasoningExpanded: true,
        toolsExpanded: true
    )
    let laidOut = laidOutAgentRow(
        turn: turn,
        document: document,
        rowHeight: height,
        reasoningExpanded: true,
        toolsExpanded: true
    )
    let row = laidOut.row
    let mark = bandRect(row.markViewForTesting, in: row)
    let reasoningBand = bandRect(row.reasoningButtonForTesting, in: row)
    let answerBand = bandRect(row.answerViewForTesting, in: row)
    let band = MessageTypography.turnGap / 2

    // The premise. Two expanded channels stand between the top of the turn and
    // its answer, the row is tall, and the whole mark stands above the answer:
    // a mark placed by the answer would stand bands away from the line the turn
    // starts with.
    #expect(row.bounds.height > 300)
    #expect(answerBand.minY > mark.maxY)
    // The disclosure band is the first band of the turn, and it starts at the
    // row's top band.
    #expect(abs((reasoningBand.minY - row.bounds.minY) - band) < 0.5)

    // The mark marks that band, not the middle of the row. The box starts at
    // the top of the disclosure band. The box is taller than the band, which a
    // 15pt semibold title keeps shorter than the 28pt mark, so the mark
    // reaches past it: the mark states the speaker of the whole turn, and the
    // first band is where the turn starts.
    #expect(abs(mark.minY - reasoningBand.minY) <= 1)
    #expect(mark.height > reasoningBand.height)
    // The mark stays out of the gap between two turns.
    #expect(mark.minY >= row.bounds.minY + band - 0.5)
    #expect(
        mark.minY - row.bounds.minY
            <= band + MessageTypography.disclosureHeight
    )
    #expect(mark.midY < row.bounds.midY)

    // The mark's depth is the turn's, never the row's.
    let taller = laidOutAgentRow(
        turn: turn,
        document: document,
        rowHeight: height + 240,
        reasoningExpanded: true,
        toolsExpanded: true
    )
    let tallerMark = bandRect(taller.row.markViewForTesting, in: taller.row)
    #expect(
        abs((tallerMark.minY - taller.row.bounds.minY) - (mark.minY - row.bounds.minY))
            < 0.5
    )
}

@Test("a reused row keeps the mark at the top of the band the new turn shows")
@MainActor
func reusedRowKeepsTheMarkAtTheTopOfTheBandTheNewTurnShows() {
    _ = NSApplication.shared
    let answer = "One assistant line."
    let document = MarkdownDocument.parse(answer).document
    let channelled = TranscriptTurn(
        id: "channels",
        speaker: .hermes,
        model: "hermes-1",
        reasoning: TranscriptReasoning(id: "reasoning", text: "collapsed detail"),
        answer: answer
    )
    let plain = TranscriptTurn(
        id: "plain",
        speaker: .hermes,
        model: "hermes-1",
        answer: answer
    )
    let laidOut = laidOutAgentRow(
        turn: channelled,
        document: document,
        rowHeight: measuredAgentRowHeight(turn: channelled, document: document)
    )
    let row = laidOut.row
    let disclosureBand = bandRect(row.reasoningButtonForTesting, in: row)
    let markOnDisclosure = bandRect(row.markViewForTesting, in: row)
    // The mark stands at the top of the disclosure band it marks.
    #expect(abs(markOnDisclosure.minY - disclosureBand.minY) <= 1)

    row.configure(
        turn: plain,
        document: document,
        reasoningExpanded: false,
        toolsExpanded: false,
        showsMetadata: true,
        findQuery: "",
        onReasoning: { _ in },
        onTools: { _ in },
        onCopyCode: { _ in }
    )
    row.layoutSubtreeIfNeeded()
    let markOnAnswer = bandRect(row.markViewForTesting, in: row)
    let answerBand = bandRect(row.answerViewForTesting, in: row)

    // The reused row shows no disclosure, so the answer is now the first band
    // and the mark stands at its top, beside the first line.
    #expect(abs(markOnAnswer.minY - answerBand.minY) <= 1)
    #expect(markOnAnswer.maxY > answerBand.minY)
    // Every band starts at the top of the stack, so the mark's depth in the row
    // is one value for every turn. This is what lets the row state the whole
    // alignment in one constant and measure no band on reuse.
    #expect(abs(markOnAnswer.minY - markOnDisclosure.minY) < 0.5)

    // The user's own turn shows no mark.
    row.configure(
        turn: TranscriptTurn(id: "outgoing", speaker: .me, answer: answer),
        document: document,
        reasoningExpanded: false,
        toolsExpanded: false,
        showsMetadata: true,
        findQuery: "",
        outgoingTextWidth: 120,
        onReasoning: { _ in },
        onTools: { _ in },
        onCopyCode: { _ in }
    )
    row.layoutSubtreeIfNeeded()
    #expect(row.markViewForTesting.isHidden)
}

@Test("an agent row measures no role band and a system row keeps one")
func agentRowMeasuresNoRoleBand() {
    let answer = String(repeating: "a measured assistant paragraph. ", count: 20)
    let document = MarkdownDocument.parse(answer).document
    let agent = TranscriptTurn(id: "agent", speaker: .hermes, answer: answer)
    let system = TranscriptTurn(id: "system", speaker: .system, answer: answer)
    let width: CGFloat = 340
    let agentHeight = TranscriptRendererTestSeam.measuredLayout(
        for: agent,
        document: document,
        width: width
    ).height
    let systemHeight = TranscriptRendererTestSeam.measuredLayout(
        for: system,
        document: document,
        width: width
    ).height

    // The floor must not answer for the chain.
    #expect(agentHeight > MessageTypography.minimumTurnHeight)
    // Only the system row shows a role label, so only the system row measures
    // the band. Both rows measure the same attributed answer. The two rows are
    // measured at one width, because the agent width holds the gutter the mark
    // stands in and the system width does not.
    #expect(
        systemHeight - agentHeight
            == MessageTypography.roleLabelHeight
                + MessageTypography.internalBlockGap
    )
}

@Test("expanded reasoning pushes a long answer without clipping")
@MainActor
func expandedReasoningPushesALongAnswerWithoutClipping() {
    _ = NSApplication.shared
    let paragraph = String(
        repeating: "The assistant writes a complete paragraph that wraps at the reading measure. ",
        count: 6
    )
    let answer = Array(repeating: paragraph, count: 6).joined(separator: "\n\n")
    let reasoning = Array(
        repeating: "A line of expanded reasoning that also wraps at the column.",
        count: 12
    ).joined(separator: "\n")
    let document = MarkdownDocument.parse(answer).document
    let turn = TranscriptTurn(
        id: "expanded-clip",
        speaker: .hermes,
        model: "hermes-1",
        reasoning: TranscriptReasoning(id: "reasoning", text: reasoning, effort: "high"),
        answer: answer
    )
    let height = measuredAgentRowHeight(
        turn: turn,
        document: document,
        reasoningExpanded: true
    )
    let laidOut = laidOutAgentRow(
        turn: turn,
        document: document,
        rowHeight: height,
        reasoningExpanded: true
    )
    let row = laidOut.row
    let contentHeight = arrangedContentHeight(row)

    // The premise. Several paragraphs and an expanded reasoning band make a
    // tall turn. A height from the raw source in Helvetica 13 is shorter than
    // the rendered bands, and the last lines of the answer then clip.
    #expect(contentHeight > MessageTypography.minimumTurnHeight)
    #expect(row.answerViewForTesting.bounds.height > 3 * MessageTypography.bodyLineHeight)
    // The applied row height is the table height. It must fit every visible
    // band at the width the row laid out, with the turn gap around the stack.
    #expect(contentHeight + MessageTypography.turnGap <= height + 1)
    #expect(
        naturalTextHeight(row.answerViewForTesting)
            <= row.answerViewForTesting.bounds.height + 1
    )
    #expect(
        naturalTextHeight(row.reasoningViewForTesting)
            <= row.reasoningViewForTesting.bounds.height + 1
    )
    for view in row.arrangedSubviewsForTesting where !view.isHidden {
        guard let text = view as? NSTextView else { continue }
        #expect(naturalTextHeight(text) <= text.bounds.height + 1)
    }
}

@Test("hovering a row counts enter exit without redrawing the answer")
@MainActor
func hoveringARowCountsEnterExitWithoutRedrawingTheAnswer() {
    _ = NSApplication.shared
    let answer = "A short assistant answer for the hover probe."
    let document = MarkdownDocument.parse(answer).document
    let turn = TranscriptTurn(
        id: "hover",
        speaker: .hermes,
        model: "hermes-1",
        reasoning: TranscriptReasoning(id: "reasoning", text: "detail", effort: "high"),
        answer: answer
    )
    let height = measuredAgentRowHeight(turn: turn, document: document)
    let laidOut = laidOutAgentRow(
        turn: turn,
        document: document,
        rowHeight: height
    )
    laidOut.row.configure(
        turn: turn,
        document: document,
        reasoningExpanded: false,
        toolsExpanded: false,
        showsMetadata: false,
        findQuery: "",
        onReasoning: { _ in },
        onTools: { _ in },
        onCopyCode: { _ in }
    )
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 780, height: height + 80),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = laidOut.root
    window.makeKeyAndOrderFront(nil)
    laidOut.row.layoutSubtreeIfNeeded()
    let row = laidOut.row
    let answerView = row.answerViewForTesting
    answerView.needsDisplay = false

    let enter = NSEvent.enterExitEvent(
        with: .mouseEntered,
        location: NSPoint(x: 40, y: height / 2),
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        trackingNumber: 0,
        userData: nil
    )!
    #expect(row.metadataStackForTesting.wantsLayer)
    let rebuilds = row.trackingAreaRebuildCountForTesting
    row.mouseEntered(with: enter)
    for _ in 0..<8 {
        row.updateTrackingAreas()
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    #expect(row.trackingAreaRebuildCountForTesting == rebuilds)

    let exit = NSEvent.enterExitEvent(
        with: .mouseExited,
        location: NSPoint(x: -40, y: height / 2),
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 2,
        trackingNumber: 0,
        userData: nil
    )!
    row.mouseExited(with: exit)
    window.orderOut(nil)

    // One enter and one exit. Rebuilding the tracking area during the
    // reveal must not start more animator transactions.
    #expect(row.mouseEnterCountForTesting == 1)
    #expect(row.mouseExitCountForTesting == 1)
    #expect(row.metadataAnimatorCountForTesting == 2)
    #expect(!answerView.needsDisplay)
}

@Test("a reasoning disclosure changes the row in place and travels to the measured height")
@MainActor
func reasoningDisclosureChangesTheRowInPlace() async throws {
    _ = NSApplication.shared
    let reasoning = String(
        repeating: "A real line of model reasoning that wraps at the measure. ",
        count: 12
    )
    let answer = String(
        repeating: "The assistant answer stands under the disclosure band. ",
        count: 8
    )
    let messages = [
        ChatMessage(
            id: .server(ServerMessageID(rawValue: 1)),
            role: .assistant,
            text: answer,
            reasoning: reasoning
        )
    ]
    // The turn the renderer projects from the same tail, so the heights below
    // are the renderer's own numbers.
    let turn = try #require(
        CachedTranscript(
            version: HistoryCache.version,
            messages: messages,
            snapshot: nil
        ).turns.first
    )
    #expect(turn.reasoning != nil)

    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = attachedTranscriptRoot(container)
    coordinator.update(
        container: container,
        input: TranscriptRendererInput(
            store: nil,
            route: nil,
            summary: nil,
            revision: 0,
            isReadOnly: true,
            isStreaming: false,
            findQuery: "",
            pendingMessageID: nil,
            findMessageID: nil,
            showsMetadata: false,
            publishedTail: messages,
            onCopyCode: { _ in },
            onPaint: { _ in }
        )
    )
    root.layoutSubtreeIfNeeded()
    container.layoutTableDocument()
    let table = container.tableView
    #expect(table.numberOfRows == 1)

    let document = MarkdownDocument.parse(turn.answer).document
    let width = TranscriptRendererTestSeam.effectiveWidth(
        for: turn,
        availableWidth: table.bounds.width
    )
    let collapsedHeight = TranscriptRendererTestSeam.measuredLayout(
        for: turn,
        document: document,
        width: width
    ).height
    let expandedHeight = TranscriptRendererTestSeam.measuredLayout(
        for: turn,
        document: document,
        width: width,
        reasoningExpanded: true
    ).height
    #expect(expandedHeight > collapsedHeight + MessageTypography.bodyLineHeight)
    let landed = await waitForCondition {
        abs(table.rect(ofRow: 0).height - collapsedHeight) < 1
    }
    #expect(landed)

    root.layoutSubtreeIfNeeded()
    let row = try #require(
        table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TranscriptTurnRowView
    )
    row.layoutSubtreeIfNeeded()
    // The row runs top down, so a band holds its place while the row height
    // travels under it.
    #expect(row.isFlipped)
    #expect(!row.reasoningButtonForTesting.isHidden)
    #expect(row.reasoningViewForTesting.isHidden)

    // The reader's own selection, and the text the row already carries. A
    // reload drops both.
    let answerView = row.answerViewForTesting
    answerView.setSelectedRange(NSRange(location: 0, length: 12))
    let storage = try #require(answerView.textStorage)
    let text = storage.string
    let disclosures = row.disclosureCountForTesting
    let rowTop = table.rect(ofRow: 0).minY
    let clipOrigin = container.scrollViewForTesting.contentView.bounds.origin.y

    row.reasoningButtonForTesting.performClick(nil)

    // In place: the same view, the same text storage, the same selection.
    #expect(
        table.view(atColumn: 0, row: 0, makeIfNecessary: false) === row
    )
    #expect(row.disclosureCountForTesting == disclosures + 1)
    #expect(answerView.textStorage === storage)
    #expect(storage.string == text)
    #expect(answerView.selectedRange() == NSRange(location: 0, length: 12))
    #expect(!row.reasoningViewForTesting.isHidden)
    #expect(row.reasoningButtonForTesting.attributedTitle.string == "Hide reasoning")

    // One travel, to the height the measurement gives. The estimate the row
    // would have used without the synchronous measurement is a different
    // height altogether, and it would have to be corrected afterwards.
    #expect(abs(table.rect(ofRow: 0).height - expandedHeight) < 1)
    let estimate = TranscriptRendererTestSeam.provisionalHeight(
        for: turn,
        availableWidth: table.bounds.width,
        reasoningExpanded: true,
        toolsExpanded: false
    )
    #expect(estimate > expandedHeight + MessageTypography.bodyLineHeight)

    // The reader's place is unchanged: a row grows downwards, so the top edge
    // the reader clicked stays where it was, and nothing scrolls.
    #expect(abs(table.rect(ofRow: 0).minY - rowTop) < 0.5)
    #expect(
        abs(container.scrollViewForTesting.contentView.bounds.origin.y - clipOrigin)
            < 0.5
    )

    // The band closes the same way.
    row.reasoningButtonForTesting.performClick(nil)
    #expect(row.reasoningViewForTesting.isHidden)
    #expect(row.reasoningButtonForTesting.attributedTitle.string == "Reasoning")
    #expect(abs(table.rect(ofRow: 0).height - collapsedHeight) < 1)
    #expect(answerView.textStorage === storage)

    coordinator.dismantle(container: container)
}

@Test("the disclosure travel is dropped for a reader who asked for less motion")
@MainActor
func disclosureTravelIsDroppedForReducedMotion() {
    #expect(TranscriptMotion.disclosureResponse > 0)
    #expect(
        TranscriptMotion.duration(reducesMotion: false)
            == TranscriptMotion.disclosureResponse
    )
    #expect(TranscriptMotion.duration(reducesMotion: true) == 0)
}

@Test("a row height change runs inside one animation grouping")
@MainActor
func rowHeightChangeRunsInsideOneAnimationGrouping() {
    _ = NSApplication.shared
    var duration: TimeInterval = -1
    var implicit = false
    var ran = false
    TranscriptMotion.runRowHeightChange {
        ran = true
        duration = NSAnimationContext.current.duration
        implicit = NSAnimationContext.current.allowsImplicitAnimation
    }

    #expect(ran)
    // The grouping states the policy's answer for this reader, and implicit
    // animation is on for exactly the reader who takes the travel.
    #expect(
        duration == TranscriptMotion.duration(
            reducesMotion: TranscriptMotion.reducesMotion
        )
    )
    #expect(implicit == !TranscriptMotion.reducesMotion)
}

@Test("a landed measurement writes the outgoing hug width without rebuilding the answer")
@MainActor
func landedMeasurementWritesHugWidthInPlace() throws {
    _ = NSApplication.shared
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 400))
    let row = TranscriptTurnRowView(frame: NSRect(x: 0, y: 0, width: 780, height: 140))
    root.addSubview(row)
    row.configure(
        turn: TranscriptTurn(id: "outgoing", speaker: .me, answer: "a prompt"),
        document: nil,
        reasoningExpanded: false,
        toolsExpanded: false,
        showsMetadata: false,
        findQuery: "",
        outgoingTextWidth: 320,
        onReasoning: { _ in },
        onTools: { _ in },
        onCopyCode: { _ in }
    )
    row.layoutSubtreeIfNeeded()
    let answerView = row.answerViewForTesting
    let storage = try #require(answerView.textStorage)
    #expect(abs(answerView.bounds.width - 320) < 1)

    row.applyOutgoingTextWidth(180)
    row.layoutSubtreeIfNeeded()

    // The measured width reached the bubble, and the answer was not built
    // again for it.
    #expect(abs(answerView.bounds.width - 180) < 1)
    #expect(answerView.textStorage === storage)
    #expect(answerView.string == "a prompt")
}
