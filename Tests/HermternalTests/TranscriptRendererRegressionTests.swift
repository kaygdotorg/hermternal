import AppKit
import HermternalCore
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
    #expect(initialAssistantTextWidth >= 600)
    // An outgoing row is no longer a full-measure column. It is capped at the
    // bubble's text measure and, with no measurement yet, it renders at the cap.
    #expect(
        abs(
            userRow.answerViewForTesting.bounds.width
                - MessageTypography.outgoingTextMeasure
        ) < 1
    )

    root.frame.size.width = 520
    let resizedAssistantRow = try laidOutRow(0)
    let resizedUserRow = try laidOutRow(1)
    let resizedTableWidth = table.bounds.width

    #expect(resizedTableWidth < initialTableWidth - 100)
    #expect(abs(column.width - resizedTableWidth) < 1)
    #expect(resizedAssistantRow.bounds.width >= resizedTableWidth - 1)
    #expect(resizedAssistantRow.answerViewForTesting.bounds.width >= 400)
    #expect(
        abs(
            resizedUserRow.answerViewForTesting.bounds.width
                - MessageTypography.outgoingTextMeasure
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
@MainActor
private struct TranscriptViewportHarness {
    let fixture: TranscriptViewportHeightFixture
    let table: BlockTranscriptTableView
    let scrollView: NSScrollView

    init(heights: [CGFloat], viewportHeight: CGFloat, width: CGFloat = 700) {
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
