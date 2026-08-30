import AppKit
import CoreText
import HermternalCore
import SwiftUI

/// A full-width, centred transcript adapter for AppKit.
///
/// Core owns turns, paging, and Markdown values. This adapter owns only rows,
/// native disclosures, text selection, and the AppKit scroll surface.
struct BlockTranscriptView: NSViewRepresentable {
    let input: TranscriptRendererInput

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    func makeNSView(context: Context) -> BlockTranscriptContainerView {
        context.coordinator.makeContainer()
    }

    @MainActor
    func updateNSView(_ nsView: BlockTranscriptContainerView, context: Context) {
        context.coordinator.update(container: nsView, input: input)
    }

    static func dismantleNSView(
        _ nsView: BlockTranscriptContainerView,
        coordinator: Coordinator
    ) {
        coordinator.dismantle(container: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private struct LoadedTurn {
            let ordinal: Int
            let turn: TranscriptTurn
        }

        private let table = BlockTranscriptTableView()
        private weak var container: BlockTranscriptContainerView?
        private var store: (any TranscriptTurnPageLocating)?
        private var route: TranscriptRoute?
        private var summary: TranscriptSummary?
        private var loadedTurns: [Int: LoadedTurn] = [:]
        private var loadedOrder: [Int] = []
        private var parsedDocuments: [String: MarkdownDocument] = [:]
        private var heightByOrdinal: [Int: CGFloat] = [:]
        private var totalTurnCount: Int?
        private var loadingStarts = Set<Int>()
        private var pageTasks: [Int: Task<Void, Never>] = [:]
        private var locateTask: Task<Void, Never>?
        private var generation = 0
        private var routeKey = "none"
        private var revision: UInt64 = 0
        private var isReadOnly = false
        private var isStreaming = false
        private var findQuery = ""
        private var pendingMessageID: String?
        private var consumedPendingMessageID: String?
        private var findMessageID: String?
        private var targetOrdinal: Int?
        private var viewportTarget: TranscriptRendererTestSeam.ViewportTarget?
        private var followsStreaming = false
        private var expandedReasoning = Set<String>()
        private var expandedTools = Set<String>()
        private var onCopyCode: (String) -> Void = { _ in }
        private let overdrawRows = 8
        private var observers: [NSObjectProtocol] = []
        private var showsMetadata = false

        func makeContainer() -> BlockTranscriptContainerView {
            table.delegate = self
            table.dataSource = self
            table.headerView = nil
            table.intercellSpacing = .zero
            table.selectionHighlightStyle = .none
            table.allowsEmptySelection = true
            table.allowsMultipleSelection = false
            table.rowSizeStyle = .custom
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.backgroundColor = .clear
            table.setAccessibilityElement(false)
            table.addTableColumn(NSTableColumn(identifier: .init("transcript")))

            let result = BlockTranscriptContainerView(tableView: table)
            result.onWidthChange = { [weak self] in self?.invalidateHeights() }
            container = result
            let boundsToken = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: table.enclosingScrollView?.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.followsStreaming = self.isStreaming && self.isNearBottom()
                    self.requestVisiblePages()
                    self.prepareVisibleTurns()
                }
            }
            observers.append(boundsToken)
            return result
        }

        func update(container: BlockTranscriptContainerView, input: TranscriptRendererInput) {
            let findChanged = findQuery != input.findQuery
            let findTargetChanged = findMessageID != input.findMessageID
            let wasNearBottom = isNearBottom()
            container.onPaint = input.onPaint
            container.resetPaint()
            self.store = input.store
            self.route = input.route
            self.summary = input.summary
            self.isReadOnly = input.isReadOnly
            self.findQuery = input.findQuery
            self.findMessageID = input.findMessageID
            self.isStreaming = input.isStreaming
            self.followsStreaming = input.isStreaming && wasNearBottom
            self.onCopyCode = input.onCopyCode
            self.showsMetadata = input.showsMetadata

            let nextRouteKey = input.route.map {
                "\($0.sessionID):\($0.generation)"
            } ?? "none"
            let routeChanged = nextRouteKey != routeKey
            let revisionChanged = revision != input.revision
            if routeChanged {
                generation &+= 1
                pageTasks.values.forEach { $0.cancel() }
                pageTasks.removeAll(keepingCapacity: true)
                locateTask?.cancel()
                locateTask = nil
                loadingStarts.removeAll(keepingCapacity: true)
                loadedTurns.removeAll(keepingCapacity: true)
                loadedOrder.removeAll(keepingCapacity: true)
                parsedDocuments.removeAll(keepingCapacity: true)
                totalTurnCount = nil
                heightByOrdinal.removeAll(keepingCapacity: true)
                targetOrdinal = nil
                consumedPendingMessageID = nil
                viewportTarget = nil
                expandedReasoning.removeAll(keepingCapacity: true)
                expandedTools.removeAll(keepingCapacity: true)
                table.noteNumberOfRowsChanged()
            }
            routeKey = nextRouteKey
            revision = input.revision
            if pendingMessageID != input.pendingMessageID || findTargetChanged {
                targetOrdinal = nil
            }
            if pendingMessageID != input.pendingMessageID {
                consumedPendingMessageID = nil
            }
            pendingMessageID = input.pendingMessageID
            if revisionChanged, !routeChanged {
                parsedDocuments.removeAll(keepingCapacity: true)
                heightByOrdinal.removeAll(keepingCapacity: true)
                loadingStarts.removeAll(keepingCapacity: true)
            }

            let count = rowCount
            if routeChanged {
                table.noteNumberOfRowsChanged()
            }
            if findChanged {
                let visible = table.rows(in: table.visibleRect)
                if visible.location != NSNotFound, visible.length > 0 {
                    let indexes = IndexSet(integersIn: visible.location..<min(rowCount, visible.location + visible.length))
                    table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
                }
            }
            if count == 0 {
                table.reloadData()
                return
            }
            requestVisiblePages()
            prepareVisibleTurns()
            position(routeChanged: routeChanged)
        }

        func dismantle(container: BlockTranscriptContainerView) {
            generation &+= 1
            pageTasks.values.forEach { $0.cancel() }
            pageTasks.removeAll()
            locateTask?.cancel()
            locateTask = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            container.onPaint = nil
            table.delegate = nil
            table.dataSource = nil
            if self.container === container { self.container = nil }
        }

        private var rowCount: Int {
            totalTurnCount ?? summary?.rowCount ?? 0
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row >= 0, row < rowCount,
                  let view = tableView.makeView(
                    withIdentifier: TranscriptTurnRowView.identifier,
                    owner: self
                  ) as? TranscriptTurnRowView
            else { return nil }
            guard let loaded = loadedTurns[row] else {
                view.configureLoading(showText: row.isMultiple(of: TranscriptPageRequestPlanner.pageSize))
                requestPage(containing: row)
                return view
            }
            let document = parsedDocuments[loaded.turn.id]
            view.configure(
                turn: loaded.turn,
                document: document,
                reasoningExpanded: expandedReasoning.contains(loaded.turn.id),
                toolsExpanded: expandedTools.contains(loaded.turn.id),
                showsMetadata: showsMetadata,
                findQuery: findQuery,
                onReasoning: { [weak self] id in self?.toggleReasoning(id) },
                onTools: { [weak self] id in self?.toggleTools(id) },
                onCopyCode: onCopyCode
            )
            return view
        }

        /// Height is a pure cache lookup. It never asks AppKit to create a row.
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            heightByOrdinal[row] ?? estimatedHeight(for: loadedTurns[row]?.turn, width: tableView.bounds.width)
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        private func estimatedHeight(for turn: TranscriptTurn?, width: CGFloat) -> CGFloat {
            guard let turn else { return MessageTypography.loadingRowHeight }
            let measure = max(1, min(MessageTypography.readingMeasure, width - 40))
            let answerLines = max(1, Int(ceil(CGFloat(turn.answer.utf16.count) / max(32, measure / 7))))
            let reasoning = turn.reasoning == nil ? 0 : MessageTypography.disclosureHeight
            let tools = turn.tools.isEmpty ? 0 : MessageTypography.disclosureHeight
            return MessageTypography.roleLabelHeight
                + CGFloat(answerLines) * MessageTypography.bodyLineHeight
                + reasoning + tools
                + MessageTypography.turnGap
                + MessageTypography.metadataFooterHeight
        }

        private func requestVisiblePages() {
            let visible = table.rows(in: table.visibleRect)
            if visible.location == NSNotFound || visible.length == 0 {
                requestRows(0..<min(rowCount, TranscriptPageRequestPlanner.pageSize))
                return
            }
            let lower = max(0, visible.location - overdrawRows)
            let upper = min(rowCount, visible.location + visible.length + overdrawRows)
            requestRows(lower..<upper)
        }

        private func requestRows(_ range: Range<Int>) {
            guard rowCount > 0 else { return }
            for start in TranscriptPageRequestPlanner.alignedStarts(
                for: range,
                totalRows: rowCount
            ) {
                requestPage(start: start)
            }
        }

        private func requestPage(containing row: Int) {
            requestRows(row..<min(rowCount, row + 1))
        }

        private func requestPage(start: Int) {
            guard let store, let route,
                  start < rowCount,
                  loadingStarts.insert(start).inserted
            else { return }
            let requestGeneration = generation
            let request = TranscriptTurnPageRequest(
                startOrdinal: start,
                maximumRows: TranscriptPageRequestPlanner.pageSize,
                maximumBytes: 512 * 1024,
                expectedGeneration: route.generation,
                expectedEpoch: route.epoch
            )
            let task = Task { [weak self, store] in
                do {
                    let page = try await store.turnPage(request)
                    await MainActor.run {
                        guard let self, self.generation == requestGeneration else { return }
                        self.loadingStarts.remove(start)
                        self.pageTasks.removeValue(forKey: start)
                        self.accept(page)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.loadingStarts.remove(start)
                        self?.pageTasks.removeValue(forKey: start)
                    }
                }
            }
            pageTasks[start] = task
        }

        private func accept(_ page: TranscriptTurnPage) {
            let previousCount = rowCount
            totalTurnCount = page.totalTurnCount
            for (offset, turn) in page.turns.enumerated() {
                let ordinal = page.startOrdinal + offset
                loadedTurns[ordinal] = LoadedTurn(ordinal: ordinal, turn: turn)
                loadedOrder.removeAll { $0 == ordinal }
                loadedOrder.append(ordinal)
                heightByOrdinal[ordinal] = estimatedHeight(for: turn, width: table.bounds.width)
            }
            while loadedOrder.count > 256 {
                let old = loadedOrder.removeFirst()
                loadedTurns.removeValue(forKey: old)
                heightByOrdinal.removeValue(forKey: old)
            }
            if rowCount != previousCount {
                table.noteNumberOfRowsChanged()
            }
            if page.hasMore, page.nextOrdinal > page.startOrdinal {
                requestPage(start: page.nextOrdinal)
            }
            let indexes = IndexSet(page.turns.indices.map { page.startOrdinal + $0 })
                .intersection(IndexSet(integersIn: 0..<rowCount))
            guard !indexes.isEmpty else { return }
            table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
            table.noteHeightOfRows(withIndexesChanged: indexes)
            container?.layoutTableDocument()
            prepareVisibleTurns()
            position(routeChanged: false)
        }

        private func prepareVisibleTurns() {
            let visible = table.rows(in: table.visibleRect)
            let range: Range<Int>
            if visible.location == NSNotFound || visible.length == 0 {
                range = 0..<min(rowCount, TranscriptPageRequestPlanner.pageSize)
            } else {
                range = max(0, visible.location - overdrawRows)..<min(
                    rowCount,
                    visible.location + visible.length + overdrawRows
                )
            }
            let candidates = range.compactMap { loadedTurns[$0]?.turn }
                .filter { parsedDocuments[$0.id] == nil }
            guard !candidates.isEmpty else { return }
            let current = generation
            let width = table.bounds.width
            let expandedReasoning = self.expandedReasoning
            let expandedTools = self.expandedTools
            Task { [weak self] in
                let prepared = await Task.detached(priority: .userInitiated) {
                    candidates.map { turn in
                        let document = MarkdownDocument.parse(turn.answer).document
                        let height = TranscriptTurnTextRenderer.measuredHeight(
                            turn: turn,
                            document: document,
                            width: width,
                            reasoningExpanded: expandedReasoning.contains(turn.id),
                            toolsExpanded: expandedTools.contains(turn.id)
                        )
                        return (turn.id, document, height)
                    }
                }.value
                guard let self, self.generation == current else { return }
                for (id, document, height) in prepared {
                    self.parsedDocuments[id] = document
                    if let ordinal = self.loadedTurns.first(where: { $0.value.turn.id == id })?.key {
                        self.heightByOrdinal[ordinal] = height
                    }
                }
                let indexes = IndexSet(prepared.compactMap { item in
                    self.loadedTurns.first(where: { $0.value.turn.id == item.0 })?.key
                })
                if !indexes.isEmpty {
                    self.table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
                    self.table.noteHeightOfRows(withIndexesChanged: indexes)
                    self.container?.layoutTableDocument()
                }
            }

        }

        private func toggleReasoning(_ id: String) {
            if expandedReasoning.contains(id) { expandedReasoning.remove(id) }
            else { expandedReasoning.insert(id) }
            reloadTurn(id)
        }

        private func toggleTools(_ id: String) {
            if expandedTools.contains(id) { expandedTools.remove(id) }
            else { expandedTools.insert(id) }
            reloadTurn(id)
        }

        private func reloadTurn(_ id: String) {
            guard let ordinal = loadedTurns.first(where: { $0.value.turn.id == id })?.key else { return }
            heightByOrdinal[ordinal] = estimatedHeight(
                for: loadedTurns[ordinal]!.turn,
                width: table.bounds.width
            )
            let indexes = IndexSet(integer: ordinal)
            table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
            table.noteHeightOfRows(withIndexesChanged: indexes)
            container?.layoutTableDocument()
        }

        private func position(routeChanged: Bool) {
            let current = generation
            let target = TranscriptRendererTestSeam.viewportTarget(
                pendingMessageID: TranscriptRendererTestSeam.activePendingMessageID(
                    pendingMessageID: pendingMessageID,
                    consumedPendingMessageID: consumedPendingMessageID
                ),
                findMessageID: findMessageID,
                isStreaming: isStreaming,
                isNearBottom: followsStreaming,
                routeChanged: routeChanged,
                currentTarget: viewportTarget
            )
            let targetChanged = target != viewportTarget
            viewportTarget = target
            switch target {
            case .message(let messageID):
                if targetChanged {
                    locateTask?.cancel()
                    locateTask = nil
                    targetOrdinal = nil
                }
                if targetOrdinal == nil, locateTask == nil, let store {
                    locateTask = Task { [weak self, store] in
                        let location = try? await store.locateTurn(messageID: messageID)
                        await MainActor.run {
                            guard let self, self.generation == current else { return }
                            self.locateTask = nil
                            guard TranscriptRendererTestSeam.acceptsLocatedMessage(
                                messageID,
                                currentTarget: self.viewportTarget
                            ), let location else { return }
                            self.targetOrdinal = location.ordinal
                            self.requestPage(containing: location.ordinal)
                            self.position(routeChanged: false)
                        }
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == current,
                          let target = self.targetOrdinal, target < self.rowCount
                    else { return }
                    self.table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
                    self.table.scrollRowToVisible(target)
                    if self.pendingMessageID == messageID,
                       self.consumedPendingMessageID != messageID {
                        self.consumedPendingMessageID = messageID
                        self.position(routeChanged: false)
                    }
                }
            case .bottom:
                guard !isReadOnly, routeChanged || (isStreaming && followsStreaming) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.scrollToBottom()
                }
            }
        }

        private func isNearBottom() -> Bool {
            guard let clip = table.enclosingScrollView?.contentView else { return true }
            let distance = max(0, table.bounds.height - clip.bounds.maxY)
            return distance <= max(48, clip.bounds.height * 0.15)
        }

        private func scrollToBottom() {
            guard let clip = table.enclosingScrollView?.contentView else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, table.bounds.height - clip.bounds.height)))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        private func invalidateHeights() {
            heightByOrdinal.removeAll(keepingCapacity: true)
            for (ordinal, loaded) in loadedTurns {
                heightByOrdinal[ordinal] = estimatedHeight(
                    for: loaded.turn,
                    width: table.bounds.width
                )
            }
        }

    }
}

enum TranscriptRendererTestSeam {
    enum ViewportTarget: Equatable { case bottom; case message(id: String) }
    private static let explicitMarker = MessageIdentity.server(ServerMessageID(rawValue: -1))
    private static let findMarker = MessageIdentity.server(ServerMessageID(rawValue: -2))
    private static let retainedMarker = MessageIdentity.server(ServerMessageID(rawValue: -3))

    static func viewportTarget(pendingMessageID: String?, findMessageID: String?, isStreaming: Bool, isNearBottom: Bool, routeChanged: Bool, currentTarget: ViewportTarget?) -> ViewportTarget {
        let current: TranscriptViewportTarget?
        switch currentTarget {
        case .bottom: current = .bottom
        case .message: current = .message(id: retainedMarker)
        case nil: current = nil
        }
        switch TranscriptViewportPolicy.resolveTarget(explicitMessageID: pendingMessageID == nil ? nil : explicitMarker, findMessageID: findMessageID == nil ? nil : findMarker, isStreaming: isStreaming, isNearBottom: isNearBottom, routeChanged: routeChanged, currentTarget: current) {
        case .bottom: return .bottom
        case .message(let marker) where marker == explicitMarker: return .message(id: pendingMessageID!)
        case .message(let marker) where marker == findMarker: return .message(id: findMessageID!)
        case .message: return currentTarget ?? .bottom
        }
    }

    static func acceptsLocatedMessage(_ messageID: String, currentTarget: ViewportTarget?) -> Bool {
        currentTarget == .message(id: messageID)
    }

    static func activePendingMessageID(
        pendingMessageID: String?,
        consumedPendingMessageID: String?
    ) -> String? {
        pendingMessageID == consumedPendingMessageID ? nil : pendingMessageID
    }

    static func attributedAnswer(_ document: MarkdownDocument) -> NSAttributedString { TranscriptTurnTextRenderer.attributedAnswer(document) }
}

@MainActor
final class BlockTranscriptContainerView: NSView {
    let tableView: NSTableView
    private let scrollView = NSScrollView()
    private var lastWidth: CGFloat = 0
    var onWidthChange: (() -> Void)?
    var onPaint: ((UInt64) -> Void)?
    private var didPaint = false

    init(tableView: NSTableView) {
        self.tableView = tableView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        tableView.translatesAutoresizingMaskIntoConstraints = true
        tableView.autoresizingMask = [.width]
        tableView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    func resetPaint() { didPaint = false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !didPaint, tableView.numberOfRows > 0 else { return }
        didPaint = true
        let timestamp = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in self?.onPaint?(timestamp) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layoutTableDocument()
    }

    func layoutTableDocument() {
        let width = max(1, scrollView.contentView.bounds.width)
        let changed = abs(width - lastWidth) > 0.5
        lastWidth = width
        tableView.frame.size.width = width
        if changed {
            onWidthChange?()
        }
        if changed, tableView.numberOfRows > 0 {
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows)
            )
        }
        tableView.frame.size.height = max(1, tableView.fittingSize.height)
    }
}

@MainActor
private final class BlockTranscriptTableView: NSTableView {
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        if let view = super.makeView(withIdentifier: identifier, owner: owner) { return view }
        guard identifier == TranscriptTurnRowView.identifier else { return nil }
        return TranscriptTurnRowView()
    }
}

@MainActor
final class TranscriptTurnRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TranscriptTurnRow")

    private let stack = NSStackView()
    private let roleHeader = NSStackView()
    private let markView = NSImageView()
    private let roleLabel = NSTextField(labelWithString: "")
    private let answerView = NSTextView()
    private let reasoningButton = NSButton()
    var reasoningButtonForTesting: NSButton { reasoningButton }
    private let reasoningView = NSTextView()
    private let toolsButton = NSButton()
    var toolsButtonForTesting: NSButton { toolsButton }
    private let copyButton = NSButton()
    private let toolsView = NSTextView()
    private let metadataStack = NSStackView()
    private let modelLabel = NSTextField(labelWithString: "")
    private let reasoningLabel = NSTextField(labelWithString: "")
    private var turnID = ""
    private var onReasoning: (String) -> Void = { _ in }
    private var onTools: (String) -> Void = { _ in }
    private var codeToCopy = ""
    private var onCopyCode: (String) -> Void = { _ in }
    private var bodyLeadingConstraints: [NSLayoutConstraint] = []
    private var bodyTrailingConstraints: [NSLayoutConstraint] = []
    private var centeredConstraint: NSLayoutConstraint!
    private var userTrailingConstraint: NSLayoutConstraint!
    private var userMaxWidthConstraint: NSLayoutConstraint!
    private var tracking: NSTrackingArea?
    private var metadataAlwaysVisible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let measureWidth = stack.widthAnchor.constraint(
            equalTo: widthAnchor,
            constant: -2 * MessageTypography.transcriptInset
        )
        measureWidth.priority = .defaultHigh
        centeredConstraint = stack.centerXAnchor.constraint(equalTo: centerXAnchor)
        userTrailingConstraint = stack.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -MessageTypography.transcriptInset
        )
        userTrailingConstraint.isActive = false
        userMaxWidthConstraint = stack.widthAnchor.constraint(
            lessThanOrEqualToConstant: MessageTypography.readingMeasure * 0.72
        )
        userMaxWidthConstraint.isActive = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: MessageTypography.transcriptInset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MessageTypography.transcriptInset),
            centeredConstraint,
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: MessageTypography.readingMeasure),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: MessageTypography.turnGap / 2),
            measureWidth,
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MessageTypography.turnGap / 2)
        ])
        roleHeader.orientation = .horizontal
        roleHeader.alignment = .top
        roleHeader.spacing = 6
        roleHeader.translatesAutoresizingMaskIntoConstraints = false
        markView.imageScaling = .scaleProportionallyUpOrDown
        markView.setAccessibilityElement(false)
        markView.translatesAutoresizingMaskIntoConstraints = false
        roleHeader.addArrangedSubview(markView)
        roleLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        roleLabel.textColor = .secondaryLabelColor
        roleLabel.translatesAutoresizingMaskIntoConstraints = false
        roleHeader.addArrangedSubview(roleLabel)
        stack.addArrangedSubview(roleHeader)
        NSLayoutConstraint.activate([
            markView.widthAnchor.constraint(equalToConstant: 14),
            markView.heightAnchor.constraint(equalToConstant: 14),
            markView.topAnchor.constraint(equalTo: roleHeader.topAnchor)
        ])
        copyButton.title = "Copy code"
        copyButton.bezelStyle = .texturedRounded
        copyButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        copyButton.target = self
        copyButton.action = #selector(copyCodeAction)
        copyButton.setAccessibilityLabel("Copy code")
        stack.addArrangedSubview(copyButton)
        configureTextView(answerView)
        stack.addArrangedSubview(answerView)
        configureDisclosure(reasoningButton, title: "Reasoning")
        configureDisclosure(toolsButton, title: "Tools")
        stack.insertArrangedSubview(reasoningButton, at: 1)
        stack.insertArrangedSubview(reasoningView, at: 2)
        stack.insertArrangedSubview(toolsButton, at: 3)
        stack.insertArrangedSubview(toolsView, at: 4)
        configureTextView(reasoningView)
        configureTextView(toolsView)
        reasoningButton.target = self
        reasoningButton.action = #selector(reasoningAction)
        toolsButton.target = self
        toolsButton.action = #selector(toolsAction)
        metadataStack.orientation = .horizontal
        metadataStack.spacing = MessageTypography.metadataGap
        metadataStack.addArrangedSubview(modelLabel)
        metadataStack.addArrangedSubview(reasoningLabel)
        metadataStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(metadataStack)
        let bodyViews: [NSView] = [
            reasoningButton, reasoningView, toolsButton, toolsView,
            copyButton, answerView, metadataStack
        ]
        for view in bodyViews {
            let leading = view.leadingAnchor.constraint(equalTo: stack.leadingAnchor)
            let trailing = view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            bodyLeadingConstraints.append(leading)
            bodyTrailingConstraints.append(trailing)
        }
        NSLayoutConstraint.activate(bodyLeadingConstraints + bodyTrailingConstraints)
        modelLabel.font = NSFont.preferredFont(forTextStyle: .caption1)
        reasoningLabel.font = NSFont.preferredFont(forTextStyle: .caption1)
        modelLabel.textColor = .tertiaryLabelColor
        reasoningLabel.textColor = .tertiaryLabelColor
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !metadataAlwaysVisible else { return }
        metadataStack.animator().alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard !metadataAlwaysVisible else { return }
        metadataStack.animator().alphaValue = 0
    }
    func configureLoading(showText: Bool) {
        turnID = ""
        codeToCopy = ""
        roleLabel.stringValue = ""
        answerView.string = showText ? "Loading…" : ""
        reasoningButton.isHidden = true
        reasoningView.isHidden = true
        reasoningView.string = ""
        toolsButton.isHidden = true
        toolsView.isHidden = true
        toolsView.string = ""
        copyButton.isHidden = true
        markView.isHidden = true
        modelLabel.stringValue = ""
        modelLabel.isHidden = true
        reasoningLabel.stringValue = ""
        reasoningLabel.isHidden = true
        metadataStack.isHidden = true
        metadataStack.alphaValue = 0
        setAccessibilityLabel("Loading transcript row")
    }

    func configure(
        turn: TranscriptTurn,
        document: MarkdownDocument?,
        reasoningExpanded: Bool,
        toolsExpanded: Bool,
        showsMetadata: Bool,
        findQuery: String,
        onReasoning: @escaping (String) -> Void,
        onTools: @escaping (String) -> Void,
        onCopyCode: @escaping (String) -> Void
    ) {
        turnID = turn.id
        self.onReasoning = onReasoning
        self.onTools = onTools
        self.onCopyCode = onCopyCode
        let isHermes = turn.speaker == .hermes
        markView.isHidden = !isHermes
        if isHermes {
            let isDark = NSApp.effectiveAppearance.bestMatch(
                from: [.aqua, .darkAqua]
            ) == .darkAqua
            markView.image = HermternalMark.image(for: isDark ? .dark : .light)
        } else {
            markView.image = nil
        }
        roleLabel.isHidden = turn.speaker != .system
        let isUser = turn.speaker == .me
        centeredConstraint.isActive = !isUser
        userTrailingConstraint.isActive = isUser
        userMaxWidthConstraint.isActive = isUser
        let indent = isHermes ? MessageTypography.hermesIndent : 0
        for constraint in bodyLeadingConstraints {
            constraint.constant = indent
        }
        if let renderedDocument = document {
            answerView.textStorage?.setAttributedString(
                TranscriptTurnTextRenderer.attributedAnswer(
                    renderedDocument,
                    findQuery: findQuery
                )
            )
            codeToCopy = TranscriptTurnTextRenderer.codeText(renderedDocument)
        } else {
            answerView.textStorage?.setAttributedString(
                TranscriptTurnTextRenderer.plainAnswer(turn.answer)
            )
            codeToCopy = ""
        }
        copyButton.isHidden = codeToCopy.isEmpty
        copyButton.toolTip = codeToCopy.isEmpty ? nil : "Copy code"
        answerView.isHidden = turn.answer.isEmpty
        reasoningButton.isHidden = turn.reasoning == nil
        reasoningView.isHidden = turn.reasoning == nil || !reasoningExpanded
        reasoningView.string = turn.reasoning?.text ?? ""
        reasoningButton.title = reasoningExpanded ? "Hide reasoning" : "Reasoning"
        toolsButton.isHidden = turn.tools.isEmpty
        toolsView.isHidden = turn.tools.isEmpty || !toolsExpanded
        toolsView.string = TranscriptTurnTextRenderer.toolText(turn.tools)
        toolsButton.title = toolsExpanded ? "Hide tools" : "Tools"
        modelLabel.stringValue = turn.model ?? ""
        modelLabel.isHidden = turn.model == nil || turn.model?.isEmpty == true
        reasoningLabel.stringValue = turn.reasoning?.label ?? ""
        reasoningLabel.isHidden = turn.reasoning == nil
        metadataAlwaysVisible = showsMetadata
        metadataStack.isHidden = modelLabel.isHidden && reasoningLabel.isHidden
        metadataStack.alphaValue = metadataAlwaysVisible ? 1 : 0
        needsLayout = true
    }

    private func configureTextView(_ view: NSTextView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.font = NSFont.preferredFont(forTextStyle: .body)
    }

    private func configureDisclosure(_ button: NSButton, title: String) {
        button.title = title
        button.bezelStyle = .disclosure
        button.alignment = .left
        button.font = NSFont.preferredFont(forTextStyle: .footnote)
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel("Show \(title.lowercased())")
    }

    @objc private func reasoningAction() { onReasoning(turnID) }
    @objc private func toolsAction() { onTools(turnID) }
    @objc private func copyCodeAction() {
        guard !codeToCopy.isEmpty else { return }
        onCopyCode(codeToCopy)
    }
}

private enum TranscriptTurnTextRenderer {
    static func plainAnswer(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = MessageTypography.bodyLineSpacing
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.preferredFont(forTextStyle: .body),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
    }
    static func attributedAnswer(
        _ document: MarkdownDocument,
        findQuery: String = ""
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n\n")) }
            append(block, source: document, to: output)
        }
        markFindMatches(in: output, query: findQuery)
        return output
    }

    private static func markFindMatches(
        in output: NSMutableAttributedString,
        query: String
    ) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        let source = output.string as NSString
        var search = NSRange(location: 0, length: source.length)
        while search.length > 0 {
            let found = source.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: search
            )
            guard found.location != NSNotFound else { break }
            output.addAttribute(
                .backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(0.22),
                range: found
            )
            let next = found.location + max(1, found.length)
            search = NSRange(
                location: next,
                length: max(0, source.length - next)
            )
        }
    }

    static func measuredHeight(
        turn: TranscriptTurn,
        document: MarkdownDocument,
        width: CGFloat,
        reasoningExpanded: Bool,
        toolsExpanded: Bool
    ) -> CGFloat {
        let outer = max(1, min(MessageTypography.readingMeasure, width - 40))
        let contentWidth = turn.speaker == .me
            ? min(outer, MessageTypography.readingMeasure * 0.72)
            : max(1, outer - (turn.speaker == .hermes ? MessageTypography.hermesIndent : 0))
        let body = document.source
            + (reasoningExpanded ? "\n" + (turn.reasoning?.text ?? "") : "")
            + (toolsExpanded ? "\n" + toolText(turn.tools) : "")
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        let value = NSAttributedString(
            string: body,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(value)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: value.length),
            nil,
            CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            nil
        )
        let channels = (turn.reasoning == nil ? 0 : 1) + (turn.tools.isEmpty ? 0 : 1)
        return max(
            MessageTypography.minimumTurnHeight,
            ceil(size.height)
                + MessageTypography.roleLabelHeight
                + CGFloat(channels) * MessageTypography.disclosureHeight
                + MessageTypography.metadataFooterHeight
                + CGFloat(channels + 1) * MessageTypography.internalBlockGap
                + MessageTypography.turnGap
        )
    }

    static func copyText(for turns: [TranscriptTurn]) -> String {
        guard turns.count > 1 else { return turns.first?.answer ?? "" }
        return turns.map { "\($0.speaker.label)\n\($0.answer)" }.joined(separator: "\n\n")
    }

    static func codeText(_ document: MarkdownDocument) -> String {
        document.blocks.compactMap { block in
            if case .code(_, _, _, let body) = block { return body }
            return nil
        }.joined(separator: "\n\n")
    }

    static func toolText(_ tools: [TranscriptToolRun]) -> String {
        tools.map { tool in
            var lines = [tool.name + " (" + tool.state.rawValue + ")"]
            if let input = tool.input, !input.isEmpty { lines.append("Input: " + input) }
            if let output = tool.output, !output.isEmpty { lines.append("Output: " + output) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func append(_ block: MarkdownBlock, source: MarkdownDocument, to output: NSMutableAttributedString) {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = MessageTypography.bodyLineSpacing
        paragraph.paragraphSpacing = MessageTypography.paragraphGap
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        switch block {
        case .paragraph(_, _, let inlines): output.append(attributedInline(inlines, attributes: attributes))
        case .heading(_, _, let level, let inlines):
            var heading = attributes; heading[.font] = headingFont(level, bodyFont: font)
            output.append(attributedInline(inlines, attributes: heading))
        case .quote(_, _, let inlines):
            var quoteAttributes = attributes
            quoteAttributes[.foregroundColor] = NSColor.secondaryLabelColor
            let quoteParagraph = (paragraph.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            quoteParagraph.headIndent = 10
            quoteParagraph.firstLineHeadIndent = 10
            quoteAttributes[.paragraphStyle] = quoteParagraph
            output.append(NSAttributedString(string: "│ ", attributes: quoteAttributes))
            output.append(attributedInline(inlines, attributes: quoteAttributes))
        case .list(_, _, let items), .taskList(_, _, let items):
            for (index, item) in items.enumerated() {
                if index > 0 { output.append(NSAttributedString(string: "\n", attributes: attributes)) }
                let marker = item.taskState.map { $0 == .checked ? "☑" : "☐" } ?? (item.number.map(String.init) ?? "•")
                output.append(NSAttributedString(string: String(repeating: "  ", count: item.depth) + marker + " ", attributes: attributes))
                output.append(attributedInline(item.inlines, attributes: attributes))
            }
        case .code(_, _, let language, let code):
            var codeAttributes = attributes
            codeAttributes[.font] = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
            let codeParagraph = NSMutableParagraphStyle()
            codeParagraph.lineSpacing = MessageTypography.bodyLineSpacing
            codeParagraph.headIndent = MessageTypography.codePadding
            codeParagraph.firstLineHeadIndent = MessageTypography.codePadding
            codeParagraph.tailIndent = -MessageTypography.codePadding
            codeAttributes[.paragraphStyle] = codeParagraph
            codeAttributes[.backgroundColor] = NSColor.controlBackgroundColor.withAlphaComponent(0.42)
            output.append(NSAttributedString(string: (language.isEmpty ? "" : language + "\n") + code, attributes: codeAttributes))
        case .table(_, _, let headers, let rows):
            let tableRows = [headers] + rows.map(\.cells)
            for (rowIndex, cells) in tableRows.enumerated() {
                if rowIndex > 0 { output.append(NSAttributedString(string: "\n", attributes: attributes)) }
                for (cellIndex, cell) in cells.enumerated() {
                    if cellIndex > 0 { output.append(NSAttributedString(string: "\t", attributes: attributes)) }
                    output.append(attributedInline(cell, attributes: attributes))
                }
            }
        case .footnote(_, _, let label, let inlines):
            var footnoteAttributes = attributes
            footnoteAttributes[.font] = NSFont.preferredFont(forTextStyle: .footnote)
            output.append(NSAttributedString(string: "[^\(label)]: ", attributes: footnoteAttributes))
            output.append(attributedInline(inlines, attributes: footnoteAttributes))
        case .source(_, _): output.append(NSAttributedString(string: source.sourceText(for: block), attributes: attributes))
        }
    }

    private static func attributedInline(_ values: [MarkdownInline], attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for value in values {
            switch value.kind {
            case .text(let text): output.append(NSAttributedString(string: text, attributes: attributes))
            case .emphasis(let children): output.append(attributedInline(children, attributes: fontTraits(.italicFontMask, attributes)))
            case .strong(let children): output.append(attributedInline(children, attributes: fontTraits(.boldFontMask, attributes)))
            case .strikethrough(let children):
                var struck = attributes; struck[.strikethroughStyle] = NSNumber(value: NSUnderlineStyle.single.rawValue)
                output.append(attributedInline(children, attributes: struck))
            case .inlineCode(let text):
                var code = attributes; code[.font] = NSFont.monospacedSystemFont(ofSize: (attributes[.font] as? NSFont)?.pointSize ?? NSFont.systemFontSize, weight: .regular)
                output.append(NSAttributedString(string: text, attributes: code))
            case .link(let destination, _, let children):
                var link = attributes; link[.link] = URL(string: destination) ?? destination
                output.append(attributedInline(children, attributes: link))
            }
        }
        return output
    }

    private static func fontTraits(_ traits: NSFontTraitMask, _ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = attributes
        let font = (attributes[.font] as? NSFont) ?? NSFont.preferredFont(forTextStyle: .body)
        let symbolicTraits = font.fontDescriptor.symbolicTraits.union(
            NSFontDescriptor.SymbolicTraits(rawValue: UInt32(truncatingIfNeeded: traits.rawValue))
        )
        let descriptor = font.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.symbolic: symbolicTraits.rawValue]
        ])
        result[.font] = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        return result
    }
    private static func headingFont(_ level: Int, bodyFont: NSFont) -> NSFont {
        switch level {
        case 1: return NSFont.preferredFont(forTextStyle: .title2)
        case 2: return NSFont.preferredFont(forTextStyle: .title3)
        case 3: return NSFont.preferredFont(forTextStyle: .headline)
        case 4: return NSFont.systemFont(ofSize: bodyFont.pointSize, weight: .semibold)
        default: return NSFont.preferredFont(forTextStyle: .subheadline)
        }
    }

    private static func inlineText(_ values: [MarkdownInline]) -> String {
        values.map { value in
            switch value.kind {
            case .text(let text): return text
            case .emphasis(let children), .strong(let children), .strikethrough(let children): return inlineText(children)
            case .inlineCode(let text): return text
            case .link(_, _, let children): return inlineText(children)
            }
        }.joined()
    }
}
