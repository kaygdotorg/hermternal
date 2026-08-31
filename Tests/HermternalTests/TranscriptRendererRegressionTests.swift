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
    // An outgoing row is no longer a full-measure column. It is capped at the
    // bubble's share of the column and, with no measurement yet, it renders at
    // that cap.
    #expect(
        abs(
            userRow.answerViewForTesting.bounds.width
                - MessageTypography.widestOutgoingText
        ) < 1
    )

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
    for _ in 0..<200 {
        if await store.startedReads() >= count { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await store.startedReads() >= count
}

@MainActor
private func viewportRendererInput(
    store: any TranscriptTurnPageLocating,
    sessionID: String,
    rowCount: Int
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
    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = attachedTranscriptRoot(container)
    let table = container.tableView
    coordinator.update(
        container: container,
        input: viewportRendererInput(store: store, sessionID: "anchor", rowCount: totalRows)
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

/// A row is not flipped, so the top of a band is the `maxY` of its frame.
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
    #expect(abs((row.bounds.maxY - answerBand.maxY) - band) < 0.5)

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
    #expect(abs(mark.maxY - answerBand.maxY) <= 1)
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
        abs((taller.row.bounds.maxY - tallerMark.maxY) - (row.bounds.maxY - mark.maxY))
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
    #expect(answerBand.maxY < mark.minY)
    // The disclosure band is the first band of the turn, and it starts at the
    // row's top band.
    #expect(abs((row.bounds.maxY - reasoningBand.maxY) - band) < 0.5)

    // The mark marks that band, not the middle of the row. The box starts at
    // the top of the disclosure band. The box is taller than the band, which a
    // borderless footnote button keeps to 13pt, so it reaches past it: the mark
    // states the speaker of the whole turn, and the first band is where the
    // turn starts.
    #expect(abs(mark.maxY - reasoningBand.maxY) <= 1)
    #expect(mark.height > reasoningBand.height)
    // The mark stays out of the gap between two turns.
    #expect(mark.maxY <= row.bounds.maxY - band + 0.5)
    #expect(
        row.bounds.maxY - mark.maxY
            <= band + MessageTypography.disclosureHeight
    )
    #expect(mark.midY > row.bounds.midY)

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
        abs((taller.row.bounds.maxY - tallerMark.maxY) - (row.bounds.maxY - mark.maxY))
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
    #expect(abs(markOnDisclosure.maxY - disclosureBand.maxY) <= 1)

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
    #expect(abs(markOnAnswer.maxY - answerBand.maxY) <= 1)
    #expect(markOnAnswer.minY < answerBand.maxY)
    // Every band starts at the top of the stack, so the mark's depth in the row
    // is one value for every turn. This is what lets the row state the whole
    // alignment in one constant and measure no band on reuse.
    #expect(abs(markOnAnswer.maxY - markOnDisclosure.maxY) < 0.5)

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
    // the band. Both rows keep the reserve between the measurement and the
    // rendered text. The two rows are measured at one width, because the agent
    // width holds the gutter the mark stands in and the system width does not.
    #expect(systemHeight - agentHeight == MessageTypography.roleLabelHeight)
}
