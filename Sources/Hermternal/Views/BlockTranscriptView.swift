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

        struct MeasuredDocumentCache {
            struct DisclosureState: Hashable, Sendable {
                let reasoningExpanded: Bool
                let toolsExpanded: Bool

                init(reasoningExpanded: Bool = false, toolsExpanded: Bool = false) {
                    self.reasoningExpanded = reasoningExpanded
                    self.toolsExpanded = toolsExpanded
                }
            }

            private struct Document {
                let turn: TranscriptTurn
                let document: MarkdownDocument
            }

            private struct Measurement {
                let turn: TranscriptTurn
                let effectiveWidth: CGFloat
                let disclosure: DisclosureState
                let layout: TranscriptTurnLayout
            }

            static let widthTolerance: CGFloat = 0.5

            private var documents: [String: Document] = [:]
            private var measurements: [Int: Measurement] = [:]

            var documentCount: Int { documents.count }
            var measurementCount: Int { measurements.count }

            static func matchesWidth(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
                abs(lhs - rhs) <= widthTolerance
            }

            func document(for turn: TranscriptTurn) -> MarkdownDocument? {
                guard let cached = documents[turn.id], cached.turn == turn else { return nil }
                return cached.document
            }

            func document(for turnID: String) -> MarkdownDocument? {
                documents[turnID]?.document
            }

            /// The measured width and height for one row.
            ///
            /// Both come from a single measurement at a single effective width,
            /// so the width the view lays out at is the width the height was
            /// computed at.
            func layout(
                for ordinal: Int,
                turn: TranscriptTurn,
                effectiveWidth: CGFloat,
                disclosure: DisclosureState
            ) -> TranscriptTurnLayout? {
                guard let measurement = measurements[ordinal],
                      measurement.turn == turn,
                      measurement.disclosure == disclosure,
                      Self.matchesWidth(measurement.effectiveWidth, effectiveWidth)
                else { return nil }
                return measurement.layout
            }

            func height(
                for ordinal: Int,
                turn: TranscriptTurn,
                effectiveWidth: CGFloat,
                disclosure: DisclosureState
            ) -> CGFloat? {
                layout(
                    for: ordinal,
                    turn: turn,
                    effectiveWidth: effectiveWidth,
                    disclosure: disclosure
                )?.height
            }

            func height(for ordinal: Int, turnID: String, width: CGFloat) -> CGFloat? {
                guard let measurement = measurements[ordinal],
                      measurement.turn.id == turnID,
                      Self.matchesWidth(measurement.effectiveWidth, width)
                else { return nil }
                return measurement.layout.height
            }

            @discardableResult
            mutating func accept(
                document: MarkdownDocument,
                for turn: TranscriptTurn,
                ordinal: Int,
                width: CGFloat,
                disclosure: DisclosureState = .init(),
                measure: (TranscriptTurn, MarkdownDocument, CGFloat) -> CGFloat
            ) -> Bool {
                if self.document(for: turn) != nil,
                   height(
                        for: ordinal,
                        turn: turn,
                        effectiveWidth: width,
                        disclosure: disclosure
                   ) != nil {
                    return false
                }
                if let previous = measurements[ordinal], previous.turn != turn,
                   documents[previous.turn.id]?.turn == previous.turn {
                    documents.removeValue(forKey: previous.turn.id)
                }
                store(document: document, for: turn)
                store(
                    height: measure(turn, document, width),
                    for: turn,
                    ordinal: ordinal,
                    effectiveWidth: width,
                    disclosure: disclosure
                )
                return true
            }

            @discardableResult
            mutating func store(document: MarkdownDocument, for turn: TranscriptTurn) -> Bool {
                guard documents[turn.id]?.turn != turn else { return false }
                documents[turn.id] = Document(turn: turn, document: document)
                return true
            }

            mutating func store(
                layout: TranscriptTurnLayout,
                for turn: TranscriptTurn,
                ordinal: Int,
                effectiveWidth: CGFloat,
                disclosure: DisclosureState
            ) {
                measurements[ordinal] = Measurement(
                    turn: turn,
                    effectiveWidth: effectiveWidth,
                    disclosure: disclosure,
                    layout: layout
                )
            }

            /// Stores a height alone, for a caller that has no width to record.
            /// The effective width stands in, which is the widest the text can
            /// be at this key.
            mutating func store(
                height: CGFloat,
                for turn: TranscriptTurn,
                ordinal: Int,
                effectiveWidth: CGFloat,
                disclosure: DisclosureState
            ) {
                store(
                    layout: TranscriptTurnLayout(
                        textWidth: effectiveWidth,
                        height: height
                    ),
                    for: turn,
                    ordinal: ordinal,
                    effectiveWidth: effectiveWidth,
                    disclosure: disclosure
                )
            }

            @discardableResult
            mutating func remeasureIfNeeded(
                turn: TranscriptTurn,
                ordinal: Int,
                width: CGFloat,
                disclosure: DisclosureState = .init(),
                measure: (TranscriptTurn, MarkdownDocument, CGFloat) -> CGFloat
            ) -> Bool {
                guard let document = document(for: turn),
                      height(
                        for: ordinal,
                        turn: turn,
                        effectiveWidth: width,
                        disclosure: disclosure
                      ) == nil
                else { return false }
                store(
                    height: measure(turn, document, width),
                    for: turn,
                    ordinal: ordinal,
                    effectiveWidth: width,
                    disclosure: disclosure
                )
                return true
            }

            @discardableResult
            mutating func remeasure(
                turn: TranscriptTurn,
                ordinal: Int,
                width: CGFloat,
                disclosure: DisclosureState = .init(),
                measure: (TranscriptTurn, MarkdownDocument, CGFloat) -> CGFloat
            ) -> Bool {
                guard let document = document(for: turn) else { return false }
                store(
                    height: measure(turn, document, width),
                    for: turn,
                    ordinal: ordinal,
                    effectiveWidth: width,
                    disclosure: disclosure
                )
                return true
            }

            mutating func remove(turn: TranscriptTurn, ordinal: Int) {
                if documents[turn.id]?.turn == turn {
                    documents.removeValue(forKey: turn.id)
                }
                if measurements[ordinal]?.turn == turn {
                    measurements.removeValue(forKey: ordinal)
                }
            }

            mutating func remove(turnID: String, ordinal: Int) {
                documents.removeValue(forKey: turnID)
                measurements.removeValue(forKey: ordinal)
            }

            mutating func removeAll(keepingCapacity: Bool = false) {
                documents.removeAll(keepingCapacity: keepingCapacity)
                measurements.removeAll(keepingCapacity: keepingCapacity)
            }
        }


        private struct ParseRequest: Hashable, Sendable {
            let ordinal: Int
            let turn: TranscriptTurn
        }

        private struct ParseBatch: Sendable {
            let id: UUID
            let generation: Int
            let revision: UInt64
            let requests: [ParseRequest]
        }

        private struct MeasurementRequest: Hashable, Sendable {
            let ordinal: Int
            let turn: TranscriptTurn
            let effectiveWidth: CGFloat
            let disclosure: MeasuredDocumentCache.DisclosureState
        }

        private struct MeasurementWorkItem: Sendable {
            let request: MeasurementRequest
            let document: MarkdownDocument
        }

        private struct MeasurementBatch: Sendable {
            let id: UUID
            let generation: Int
            let revision: UInt64
            let workItems: [MeasurementWorkItem]
        }

        private struct CacheWork {
            var documentPreparationTask: Task<Void, Never>?
            var documentPreparationBatch: ParseBatch?
            var measurementTask: Task<Void, Never>?
            var measurementBatch: MeasurementBatch?
            var measurementBatchState = MeasurementBatchState()

        }

        struct MeasurementBatchState {
            private(set) var activeID: UUID?
            private(set) var reschedulePending = false

            mutating func begin() -> (id: UUID, replaced: UUID?) {
                let id = UUID()
                let replaced = activeID
                activeID = id
                return (id, replaced)
            }

            func accepts(_ id: UUID) -> Bool { activeID == id }

            mutating func queueReschedule() { reschedulePending = true }

            mutating func takeReschedule() -> Bool {
                let pending = reschedulePending
                reschedulePending = false
                return pending
            }

            @discardableResult
            mutating func finish(_ id: UUID) -> Bool {
                guard activeID == id else { return false }
                activeID = nil
                return true
            }

            mutating func reset() {
                activeID = nil
                reschedulePending = false
            }
        }


        private let table = BlockTranscriptTableView()
        private weak var container: BlockTranscriptContainerView?
        private var store: (any TranscriptTurnPageLocating)?
        private var route: TranscriptRoute?
        private var summary: TranscriptSummary?
        private var loadedTurns: [Int: LoadedTurn] = [:]
        private var loadedOrder: [Int] = []
        private var measuredDocuments = MeasuredDocumentCache()

        private var cacheWork = CacheWork()

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
            let transcriptColumn = NSTableColumn(identifier: .init("transcript"))
            transcriptColumn.resizingMask = .autoresizingMask
            table.addTableColumn(transcriptColumn)

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
                    self.scheduleVisibleMeasurements(at: self.table.bounds.width)
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
                measuredDocuments.removeAll(keepingCapacity: true)
                cacheWork.documentPreparationTask?.cancel()
                cacheWork.measurementTask?.cancel()
                cacheWork.measurementBatchState.reset()
                totalTurnCount = nil

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
                cacheWork.documentPreparationTask?.cancel()
                cacheWork.measurementTask?.cancel()
                cacheWork.measurementBatchState.reset()

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
            scheduleVisibleMeasurements(at: table.bounds.width)
            position(routeChanged: routeChanged)
        }

        func dismantle(container: BlockTranscriptContainerView) {
            generation &+= 1
            pageTasks.values.forEach { $0.cancel() }
            pageTasks.removeAll()
            locateTask?.cancel()
            locateTask = nil
            cacheWork.documentPreparationTask?.cancel()
            cacheWork.measurementTask?.cancel()
            cacheWork.measurementBatchState.reset()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            container.stopObservingSystemPalette()
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
            let document = measuredDocuments.document(for: loaded.turn)
            let disclosure = MeasuredDocumentCache.DisclosureState(
                reasoningExpanded: expandedReasoning.contains(loaded.turn.id),
                toolsExpanded: expandedTools.contains(loaded.turn.id)
            )
            // The measured fitting width, so a short outgoing bubble hugs its
            // text. It is `nil` until the measurement lands, and the bubble
            // then renders at its cap.
            let outgoingTextWidth = measuredDocuments.layout(
                for: row,
                turn: loaded.turn,
                effectiveWidth: TranscriptTurnTextRenderer.effectiveWidth(
                    for: loaded.turn,
                    availableWidth: tableView.bounds.width
                ),
                disclosure: disclosure
            )?.textWidth
            view.configure(
                turn: loaded.turn,
                document: document,
                reasoningExpanded: disclosure.reasoningExpanded,
                toolsExpanded: disclosure.toolsExpanded,
                showsMetadata: showsMetadata,
                findQuery: findQuery,
                outgoingTextWidth: outgoingTextWidth,
                onReasoning: { [weak self] id in self?.toggleReasoning(id) },
                onTools: { [weak self] id in self?.toggleTools(id) },
                onCopyCode: onCopyCode
            )
            return view
        }

        /// Height is a pure cache lookup. It never asks AppKit to create a row.
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard let loaded = loadedTurns[row] else {
                return estimatedHeight(for: nil, width: tableView.bounds.width)
            }
            let turn = loaded.turn
            let effectiveWidth = TranscriptTurnTextRenderer.effectiveWidth(
                for: turn,
                availableWidth: tableView.bounds.width
            )
            let disclosure = MeasuredDocumentCache.DisclosureState(
                reasoningExpanded: expandedReasoning.contains(turn.id),
                toolsExpanded: expandedTools.contains(turn.id)
            )
            return measuredDocuments.height(
                for: row,
                turn: turn,
                effectiveWidth: effectiveWidth,
                disclosure: disclosure
            ) ?? estimatedHeight(for: turn, width: tableView.bounds.width)
        }


        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        private func estimatedHeight(for turn: TranscriptTurn?, width: CGFloat) -> CGFloat {
            guard let turn else { return MessageTypography.loadingRowHeight }
            return TranscriptTurnTextRenderer.provisionalHeight(
                turn: turn,
                availableWidth: width,
                reasoningExpanded: expandedReasoning.contains(turn.id),
                toolsExpanded: expandedTools.contains(turn.id)
            )
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
                if let previous = loadedTurns[ordinal], previous.turn != turn {
                    measuredDocuments.remove(turn: previous.turn, ordinal: ordinal)
                }
                loadedTurns[ordinal] = LoadedTurn(ordinal: ordinal, turn: turn)
                loadedOrder.removeAll { value in value == ordinal }
                loadedOrder.append(ordinal)
            }
            while loadedOrder.count > 256 {
                let old = loadedOrder.removeFirst()
                if let evicted = loadedTurns.removeValue(forKey: old) {
                    measuredDocuments.remove(turn: evicted.turn, ordinal: old)
                }
            }
            if rowCount != previousCount {
                table.noteNumberOfRowsChanged()
            }
            if page.hasMore, page.nextOrdinal > page.startOrdinal {
                requestPage(start: page.nextOrdinal)
            }
            let indexes = IndexSet(page.turns.indices.map { index in page.startOrdinal + index })
                .intersection(IndexSet(integersIn: 0..<rowCount))
            guard !indexes.isEmpty else { return }
            correctingHeights {
                table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
                table.noteHeightOfRows(withIndexesChanged: indexes)
                container?.layoutTableDocument()
            }
            prepareVisibleTurns()
            position(routeChanged: false)
        }


        private func visibleRange() -> Range<Int> {
            let visible = table.rows(in: table.visibleRect)
            if visible.location == NSNotFound || visible.length == 0 {
                return 0..<min(rowCount, TranscriptPageRequestPlanner.pageSize)
            }
            return max(0, visible.location - overdrawRows)..<min(
                rowCount,
                visible.location + visible.length + overdrawRows
            )
        }

        private func visibleMeasuredTurns() -> [(Int, TranscriptTurn, MarkdownDocument)] {
            visibleRange().compactMap { ordinal in
                guard let turn = loadedTurns[ordinal]?.turn,
                      let document = measuredDocuments.document(for: turn)
                else { return nil }
                return (ordinal, turn, document)
            }
        }


        private func prepareVisibleTurns() {
            let requests = visibleRange().compactMap { ordinal -> ParseRequest? in
                guard let turn = loadedTurns[ordinal]?.turn,
                      measuredDocuments.document(for: turn) == nil
                else { return nil }
                return ParseRequest(ordinal: ordinal, turn: turn)
            }
            guard !requests.isEmpty else {
                cacheWork.documentPreparationTask?.cancel()
                return
            }
            let current = generation
            let currentRevision = revision
            let desired = ParseBatch(
                id: UUID(),
                generation: current,
                revision: currentRevision,
                requests: requests
            )
            guard let active = cacheWork.documentPreparationBatch else {
                startDocumentPreparation(desired)
                return
            }
            if active.generation == current,
               active.revision == currentRevision,
               Set(requests).isSubset(of: Set(active.requests)),
               cacheWork.documentPreparationTask?.isCancelled != true {
                return
            }
            cacheWork.documentPreparationTask?.cancel()
        }

        private func startDocumentPreparation(_ batch: ParseBatch) {
            cacheWork.documentPreparationBatch = batch
            cacheWork.documentPreparationTask = Task { [weak self] in
                let parser = Task.detached(priority: .userInitiated) { () -> [(ParseRequest, MarkdownDocument)] in
                    var prepared: [(ParseRequest, MarkdownDocument)] = []
                    for request in batch.requests {
                        guard !Task.isCancelled else { return [] }
                        prepared.append((request, MarkdownDocument.parse(request.turn.answer).document))
                        guard !Task.isCancelled else { return [] }
                    }
                    return prepared
                }
                let prepared: [(ParseRequest, MarkdownDocument)] = await withTaskCancellationHandler(
                    operation: { await parser.value },
                    onCancel: { parser.cancel() }
                )
                guard let self,
                      self.cacheWork.documentPreparationBatch?.id == batch.id
                else { return }
                self.cacheWork.documentPreparationTask = nil
                self.cacheWork.documentPreparationBatch = nil
                if !Task.isCancelled,
                   self.generation == batch.generation,
                   self.revision == batch.revision {
                    let indexes = IndexSet(prepared.compactMap { item in
                        let (request, document) = item
                        guard let loaded = self.loadedTurns[request.ordinal],
                              loaded.turn == request.turn
                        else { return nil }
                        self.measuredDocuments.store(document: document, for: request.turn)
                        return request.ordinal
                    })
                    if !indexes.isEmpty {
                        self.correctingHeights {
                            self.table.reloadData(
                                forRowIndexes: indexes,
                                columnIndexes: IndexSet(integer: 0)
                            )
                            self.table.noteHeightOfRows(withIndexesChanged: indexes)
                            self.container?.layoutTableDocument()
                        }
                    }
                }
                self.scheduleVisibleMeasurements(at: self.table.bounds.width)
                self.prepareVisibleTurns()
            }
        }


        private func scheduleVisibleMeasurements(at width: CGFloat) {
            let current = generation
            let currentRevision = revision
            let workItems = visibleMeasuredTurns().compactMap { ordinal, turn, document -> MeasurementWorkItem? in
                let effectiveWidth = TranscriptTurnTextRenderer.effectiveWidth(
                    for: turn,
                    availableWidth: width
                )
                let disclosure = MeasuredDocumentCache.DisclosureState(
                    reasoningExpanded: expandedReasoning.contains(turn.id),
                    toolsExpanded: expandedTools.contains(turn.id)
                )
                guard measuredDocuments.height(
                    for: ordinal,
                    turn: turn,
                    effectiveWidth: effectiveWidth,
                    disclosure: disclosure
                ) == nil else { return nil }
                return MeasurementWorkItem(
                    request: MeasurementRequest(
                        ordinal: ordinal,
                        turn: turn,
                        effectiveWidth: effectiveWidth,
                        disclosure: disclosure
                    ),
                    document: document
                )
            }
            guard !workItems.isEmpty else {
                cacheWork.measurementTask?.cancel()
                cacheWork.measurementBatchState.reset()
                return
            }
            guard let active = cacheWork.measurementBatch else {
                startMeasurement(
                    workItems,
                    generation: current,
                    revision: currentRevision
                )
                return
            }
            if active.generation == current,
               active.revision == currentRevision,
               Set(workItems.map(\.request)).isSubset(of: Set(active.workItems.map(\.request))),
               cacheWork.measurementTask?.isCancelled != true {
                return
            }
            cacheWork.measurementBatchState.queueReschedule()
            cacheWork.measurementTask?.cancel()
        }

        private func startMeasurement(
            _ workItems: [MeasurementWorkItem],
            generation: Int,
            revision: UInt64
        ) {
            let transition = cacheWork.measurementBatchState.begin()
            let batch = MeasurementBatch(
                id: transition.id,
                generation: generation,
                revision: revision,
                workItems: workItems
            )
            cacheWork.measurementBatch = batch
            cacheWork.measurementTask = Task { [weak self] in
                let measurer = Task.detached(priority: .userInitiated) { () -> [(MeasurementRequest, TranscriptTurnLayout)] in
                    var measured: [(MeasurementRequest, TranscriptTurnLayout)] = []
                    for workItem in batch.workItems {
                        guard !Task.isCancelled else { return [] }
                        let request = workItem.request
                        measured.append((
                            request,
                            TranscriptTurnTextRenderer.measuredLayout(
                                turn: request.turn,
                                document: workItem.document,
                                width: request.effectiveWidth,
                                reasoningExpanded: request.disclosure.reasoningExpanded,
                                toolsExpanded: request.disclosure.toolsExpanded
                            )
                        ))
                        guard !Task.isCancelled else { return [] }
                    }
                    return measured
                }
                let measured: [(MeasurementRequest, TranscriptTurnLayout)] = await withTaskCancellationHandler(
                    operation: { await measurer.value },
                    onCancel: { measurer.cancel() }
                )
                guard let self,
                      self.cacheWork.measurementBatch?.id == batch.id
                else { return }
                self.cacheWork.measurementTask = nil
                self.cacheWork.measurementBatch = nil
                let accepted = self.cacheWork.measurementBatchState.finish(batch.id)
                let reschedule = self.cacheWork.measurementBatchState.takeReschedule()
                if !Task.isCancelled,
                   accepted,
                   self.generation == batch.generation,
                   self.revision == batch.revision {
                    let currentWidth = self.table.bounds.width
                    var indexes = IndexSet()
                    for item in measured {
                        let (request, layout) = item
                        guard let loaded = self.loadedTurns[request.ordinal],
                              loaded.turn == request.turn
                        else { continue }
                        let disclosure = MeasuredDocumentCache.DisclosureState(
                            reasoningExpanded: self.expandedReasoning.contains(request.turn.id),
                            toolsExpanded: self.expandedTools.contains(request.turn.id)
                        )
                        let effectiveWidth = TranscriptTurnTextRenderer.effectiveWidth(
                            for: request.turn,
                            availableWidth: currentWidth
                        )
                        guard disclosure == request.disclosure,
                              MeasuredDocumentCache.matchesWidth(effectiveWidth, request.effectiveWidth)
                        else { continue }
                        self.measuredDocuments.store(
                            layout: layout,
                            for: request.turn,
                            ordinal: request.ordinal,
                            effectiveWidth: request.effectiveWidth,
                            disclosure: request.disclosure
                        )
                        indexes.insert(request.ordinal)
                    }
                    if !indexes.isEmpty {
                        self.correctingHeights {
                            self.table.reloadData(
                                forRowIndexes: indexes,
                                columnIndexes: IndexSet(integer: 0)
                            )
                            self.table.noteHeightOfRows(withIndexesChanged: indexes)
                            self.container?.layoutTableDocument()
                        }
                    }
                }
                if reschedule || !Task.isCancelled {
                    self.scheduleVisibleMeasurements(at: self.table.bounds.width)
                }
                self.prepareVisibleTurns()
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
            guard let ordinal = loadedTurns.first(where: { entry in entry.value.turn.id == id })?.key else { return }
            let indexes = IndexSet(integer: ordinal)
            table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
            table.noteHeightOfRows(withIndexesChanged: indexes)
            container?.layoutTableDocument()
            scheduleVisibleMeasurements(at: table.bounds.width)
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
                    TranscriptViewportAnchoring.scrollRowIntoView(target, in: self.table)
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
            TranscriptViewportAnchoring.isNearBottom(table)
        }

        private func scrollToBottom() {
            TranscriptViewportAnchoring.pinToBottom(table)
        }

        /// True when the viewport follows the streaming end of the transcript.
        ///
        /// The property uses the same policy as `position(routeChanged:)`. A
        /// deep-link target and a Find target keep precedence over the stream.
        /// The property does not change `viewportTarget`.
        private var followsStreamingBottom: Bool {
            guard !isReadOnly, isStreaming, followsStreaming else { return false }
            return TranscriptRendererTestSeam.viewportTarget(
                pendingMessageID: TranscriptRendererTestSeam.activePendingMessageID(
                    pendingMessageID: pendingMessageID,
                    consumedPendingMessageID: consumedPendingMessageID
                ),
                findMessageID: findMessageID,
                isStreaming: isStreaming,
                isNearBottom: followsStreaming,
                routeChanged: false,
                currentTarget: viewportTarget
            ) == .bottom
        }

        /// Applies one row-height correction and holds the reader in place.
        ///
        /// A corrected row above the viewport moves each later row origin. The
        /// anchor holds the first visible row and its intra-row offset, so the
        /// same text stays in front of the reader. When the viewport follows the
        /// streaming end, the renderer pins the end again, because a taller tail
        /// moves the end down. The renderer never scrolls a reader who moved
        /// away from the end.
        ///
        /// The three callers are asynchronous completions. Each one already
        /// tested its generation and its revision, so a superseded completion
        /// does not get here.
        private func correctingHeights(_ correct: () -> Void) {
            let followsBottom = followsStreamingBottom
            let anchor = followsBottom
                ? nil
                : TranscriptViewportAnchoring.anchor(in: table)
            correct()
            if followsBottom {
                TranscriptViewportAnchoring.pinToBottom(table)
            } else if let anchor {
                TranscriptViewportAnchoring.restore(anchor, in: table)
            }
        }
        private func invalidateHeights() {
            scheduleVisibleMeasurements(at: table.bounds.width)
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

    static func effectiveWidth(for turn: TranscriptTurn, availableWidth: CGFloat) -> CGFloat {
        TranscriptTurnTextRenderer.effectiveWidth(for: turn, availableWidth: availableWidth)
    }

    static func provisionalHeight(
        for turn: TranscriptTurn,
        availableWidth: CGFloat,
        reasoningExpanded: Bool,
        toolsExpanded: Bool
    ) -> CGFloat {
        TranscriptTurnTextRenderer.provisionalHeight(
            turn: turn,
            availableWidth: availableWidth,
            reasoningExpanded: reasoningExpanded,
            toolsExpanded: toolsExpanded
        )
    }

    static func measuredLayout(
        for turn: TranscriptTurn,
        document: MarkdownDocument,
        width: CGFloat,
        reasoningExpanded: Bool = false,
        toolsExpanded: Bool = false
    ) -> TranscriptTurnLayout {
        TranscriptTurnTextRenderer.measuredLayout(
            turn: turn,
            document: document,
            width: width,
            reasoningExpanded: reasoningExpanded,
            toolsExpanded: toolsExpanded
        )
    }

    static func outgoingRowHeight(textHeight: CGFloat) -> CGFloat {
        TranscriptTurnTextRenderer.outgoingRowHeight(textHeight: textHeight)
    }
}

/// The scroll arithmetic for the transcript viewport.
///
/// One type owns the clip-view mathematics for the transcript. The renderer
/// takes an anchor before a row-height correction. The renderer restores the
/// anchor after the correction. The correction rule is in
/// `TranscriptViewportPolicy`, so Core keeps the rule and this adapter keeps
/// only the AppKit access.
@MainActor
enum TranscriptViewportAnchoring {
    /// The place that a reader holds in the document.
    ///
    /// `ordinal` is the first row in the viewport. `rowOrigin` is the top edge
    /// of that row. `documentOrigin` is the top edge of the viewport. The
    /// difference of the last two values is the intra-row offset.
    struct Anchor {
        let ordinal: Int
        let rowOrigin: CGFloat
        let documentOrigin: CGFloat
    }

    /// True when the viewport is at the end of the document.
    ///
    /// The band is 48 points, or 15 percent of a tall viewport.
    static func isNearBottom(_ table: NSTableView) -> Bool {
        guard let clip = table.enclosingScrollView?.contentView else { return true }
        let distance = max(0, table.bounds.height - clip.bounds.maxY)
        return distance <= max(48, clip.bounds.height * 0.15)
    }

    /// The place that the reader holds now.
    ///
    /// The result is `nil` when the table has no scroll view, or when no row is
    /// in the viewport. A correction then moves nothing.
    ///
    /// `documentOrigin` comes from the clip view, because `restore` writes a
    /// clip origin. The row lookup uses the table's own visible rectangle. A
    /// table style can add a vertical inset to the row rectangles, and the two
    /// coordinate spaces must not be mixed in the value that gets written back.
    static func anchor(in table: NSTableView) -> Anchor? {
        guard let clip = table.enclosingScrollView?.contentView else { return nil }
        let viewport = table.visibleRect
        guard viewport.height > 0 else { return nil }
        let rows = table.rows(in: viewport)
        guard rows.location != NSNotFound,
              rows.length > 0,
              rows.location < table.numberOfRows
        else { return nil }
        return Anchor(
            ordinal: rows.location,
            rowOrigin: table.rect(ofRow: rows.location).minY,
            documentOrigin: clip.bounds.origin.y
        )
    }

    /// Moves the viewport, so the anchor row keeps its intra-row offset.
    ///
    /// A corrected row above the anchor row moves the anchor row down. The Core
    /// policy changes that movement into the new viewport origin. A row count
    /// that no longer holds the anchor row moves nothing.
    static func restore(_ anchor: Anchor, in table: NSTableView) {
        guard anchor.ordinal >= 0, anchor.ordinal < table.numberOfRows else { return }
        // The policy holds its origin at or below the top of the scrollable
        // range, which it takes to be zero. A top content inset puts that top
        // at a NEGATIVE clip origin, so the adapter hands the policy a
        // distance measured from the inset top and puts the answer back into
        // clip coordinates. The correction itself is a difference, so it is
        // unchanged by the translation.
        let inset = table.enclosingScrollView?.contentInsets.top ?? 0
        let origin = TranscriptViewportPolicy.preservedScrollOrigin(
            currentOrigin: Double(anchor.documentOrigin + inset),
            oldAnchorOrigin: Double(anchor.rowOrigin),
            newAnchorOrigin: Double(table.rect(ofRow: anchor.ordinal).minY)
        )
        scroll(table, to: CGFloat(origin) - inset)
    }

    /// Moves the viewport to the end of the document.
    ///
    /// `scroll` owns the scrollable range, so this asks for a point past the
    /// end and lets the clamp resolve it. The end moves with a content inset;
    /// the request does not.
    static func pinToBottom(_ table: NSTableView) {
        scroll(table, to: table.bounds.height)
    }

    /// Brings one row into the READABLE viewport.
    ///
    /// `NSTableView.scrollRowToVisible` measures against the clip view's own
    /// bounds, and this clip view runs to the physical window top, so a row
    /// arriving from above would come to rest under the window's toolbar
    /// controls and inside the transcript's top ramp. The readable viewport
    /// starts one content inset lower, which is where a row scrolled to the
    /// top comes to rest, so Find and a message deep link land a row exactly
    /// where a reader can leave one.
    ///
    /// A turn too tall to fit in that viewport is handled on its own terms: it
    /// is top-aligned from either direction, because its beginning is the part
    /// a jump is aiming at, and it is left alone only while the reader still
    /// has a readable line of it.
    static func scrollRowIntoView(_ ordinal: Int, in table: NSTableView) {
        guard ordinal >= 0,
              ordinal < table.numberOfRows,
              let scrollView = table.enclosingScrollView
        else { return }
        let clip = scrollView.contentView
        let inset = scrollView.contentInsets.top
        let readableTop = clip.bounds.origin.y + inset
        let row = table.rect(ofRow: ordinal)
        if row.height > clip.bounds.height - inset {
            // A turn taller than the readable viewport can never be contained
            // in it, so containment is the wrong question here. The question is
            // whether the reader still has this turn to read, which needs two
            // things: the turn has to cover the readable top edge, so that
            // everything from there down is this turn, and what remains below
            // that edge has to be worth reading. The renderer re-runs the same
            // target for every publication that keeps it, so aligning in that
            // state would drag a reader who scrolled into a long turn back to
            // its first line.
            //
            // Both halves are load-bearing. Plain coverage is too weak at the
            // tail: a row rectangle ends with the same empty half-gap it
            // begins with, so a single point of it can cross the edge while
            // every glyph is already above the viewport. Plain intersection is
            // too weak at the head: a turn arriving from below can show a
            // point of itself at the bottom edge and still be unread.
            //
            // One body line is the smallest remainder that is worth anything
            // to a reader, and it is the same line height the rows are laid
            // out on, so the test needs no measurement of its own.
            let readableInk = row.maxY - MessageTypography.turnGap / 2 - readableTop
            let readerIsInside = row.minY <= readableTop
                && readableInk >= MessageTypography.bodyLineHeight
            guard !readerIsInside else { return }
            // Top-aligned from either direction. Bottom aligning a turn this
            // tall would put its beginning above the readable top and under
            // the chrome, which is the occlusion this edge exists to prevent.
            scroll(table, to: row.minY - inset)
        } else if row.minY < readableTop {
            scroll(table, to: row.minY - inset)
        } else if row.maxY > clip.bounds.maxY {
            scroll(table, to: row.maxY - clip.bounds.height)
        }
    }

    /// Writes one viewport origin, and only when the origin changes.
    ///
    /// The method holds the target inside the scrollable range. A repeated write
    /// of the same origin makes the scroll view redraw for no reason.
    private static func scroll(_ table: NSTableView, to origin: CGFloat) {
        guard let scrollView = table.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        // The scrollable range with a content inset. The clip view keeps its
        // full height, so the inset does not shorten the viewport; it adds
        // range above the document's first point, at a negative origin.
        // Without that floor the transcript could never come to rest below the
        // window chrome, and a document shorter than the viewport would sit
        // under it. Both limits collapse to the old arithmetic when the insets
        // are zero.
        let first = -insets.top
        let last = max(first, table.bounds.height + insets.bottom - clip.bounds.height)
        let target = min(max(first, origin), last)
        guard abs(target - clip.bounds.origin.y) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
    }
}

@MainActor
final class BlockTranscriptContainerView: NSView {
    let tableView: NSTableView
    private let scrollView = NSScrollView()
    private var lastWidth: CGFloat = 0
    var onWidthChange: (() -> Void)?
    var onPaint: ((UInt64) -> Void)?

    /// Observers for the outgoing bubble's colour inputs.
    ///
    /// They are registered once here, never per row: rows are recycled and
    /// dozens are live, so a per-row observer is exactly the allocation to
    /// avoid.
    private var colorObservers: [NSObjectProtocol] = []
    private var accessibilityObservers: [NSObjectProtocol] = []
    private var didPaint = false

    init(tableView: NSTableView) {
        self.tableView = tableView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        // The transcript's frame runs to the physical window top, so rows
        // travel under the toolbar and dissolve into `ChatTranscriptTopEdge`
        // on the way. The scroll CONTENT stops short of that ramp, so the
        // first turn comes to rest below it and stays readable.
        //
        // `contentInsets` is the primitive that does this without moving the
        // view: it extends the scrollable range, and the clip view keeps its
        // full height and its full-bleed frame, so no row geometry, no
        // document height, and no bottom edge moves. The automatic insets
        // would derive this from a safe area the hosting boundary has already
        // cleared, and overwrite it with zero. `scrollerInsets` follows the
        // content, which is what the automatic path would also have done: the
        // scroller belongs beside the content, not under the chrome.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: ChatTranscriptTopEdge.contentInset,
            left: 0,
            bottom: 0,
            right: 0
        )
        scrollView.scrollerInsets = NSEdgeInsets(
            top: ChatTranscriptTopEdge.contentInset,
            left: 0,
            bottom: 0,
            right: 0
        )
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
        observeSystemPalette()
    }
    func resetPaint() { didPaint = false }

    var scrollViewForTesting: NSScrollView { scrollView }

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

    /// A system accent, appearance, or contrast change alters the bubble's fill
    /// and its text colour. `viewDidChangeEffectiveAppearance` covers the
    /// appearance, and the two notifications cover the other two inputs.
    private func observeSystemPalette() {
        colorObservers.append(NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reloadOutgoingPalette() }
        })
        accessibilityObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reloadOutgoingPalette() }
            }
        )
    }

    /// Removes the palette observers. The renderer calls this when it takes the
    /// container down.
    func stopObservingSystemPalette() {
        for observer in colorObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in accessibilityObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        colorObservers.removeAll()
        accessibilityObservers.removeAll()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reloadOutgoingPalette()
    }

    /// Invalidates only the rows the table has materialised, so the cost is
    /// bounded by the viewport. A row scrolled in afterwards is configured
    /// fresh and resolves its colours then.
    func reloadOutgoingPalette() {
        tableView.enumerateAvailableRowViews { rowView, _ in
            for case let cell as TranscriptTurnRowView in rowView.subviews {
                cell.reloadOutgoingPalette()
            }
        }
    }

    func layoutTableDocument() {
        let width = max(1, scrollView.contentView.bounds.width)
        let changed = abs(width - lastWidth) > BlockTranscriptView.Coordinator.MeasuredDocumentCache.widthTolerance
        lastWidth = width
        tableView.frame.size.width = width
        if let column = tableView.tableColumns.first,
           abs(column.width - width) > BlockTranscriptView.Coordinator.MeasuredDocumentCache.widthTolerance {
            column.width = width
        }
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
final class BlockTranscriptTableView: NSTableView {
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
    /// The product mark, in the gutter beside the first line of the turn.
    ///
    /// The mark is a subview of the row, like the bubble. It is not a band of
    /// the stack. No band of the turn can therefore push the mark away from
    /// the line it marks.
    private let markView = NSImageView()
    private let roleLabel = NSTextField(labelWithString: "")
    private let answerView = NSTextView()
    private let reasoningButton = NSButton()
    var answerViewForTesting: NSTextView { answerView }
    var reasoningButtonForTesting: NSButton { reasoningButton }
    var markViewForTesting: NSView { markView }
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
    private var measureWidthConstraint: NSLayoutConstraint!
    private var stackTopConstraint: NSLayoutConstraint!
    private var stackBottomConstraint: NSLayoutConstraint!
    private var markTopConstraint: NSLayoutConstraint!
    private var userTrailingConstraint: NSLayoutConstraint!
    private var userMaxWidthConstraint: NSLayoutConstraint!
    private var userTextWidthConstraint: NSLayoutConstraint!
    private var tracking: NSTrackingArea?
    private var metadataAlwaysVisible = false

    /// The outgoing bubble's fill, behind the answer text.
    private let bubble = OutgoingBubbleView(frame: .zero)

    /// Whether the configured turn is the user's own.
    private var isOutgoing = false

    /// The active Find query, so a palette change can re-mark the matches
    /// without parsing the answer again.
    private var outgoingFindQuery = ""

    var bubbleForTesting: NSView { bubble }
    var isOutgoingForTesting: Bool { isOutgoing }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        translatesAutoresizingMaskIntoConstraints = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        measureWidthConstraint = stack.widthAnchor.constraint(
            equalTo: widthAnchor,
            constant: -2 * MessageTypography.transcriptInset
        )
        measureWidthConstraint.priority = NSLayoutConstraint.Priority(999)
        centeredConstraint = stack.centerXAnchor.constraint(equalTo: centerXAnchor)
        // The tail tip, not the text, lands on the transcript gutter. The
        // gutter, the tail, and the bubble's padding all sit outside the stack.
        userTrailingConstraint = stack.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -(MessageTypography.transcriptInset
                + OutgoingBubbleGeometry.tailWidth
                + MessageTypography.outgoingBubblePaddingH)
        )
        userTrailingConstraint.isActive = false
        userMaxWidthConstraint = stack.widthAnchor.constraint(
            lessThanOrEqualToConstant: MessageTypography.outgoingTextMeasure
        )
        userMaxWidthConstraint.isActive = false
        // The measured fitting width, so a short bubble hugs its text.
        //
        // 999, not `defaultHigh`. The answer view is an `NSTextView` whose
        // horizontal compression resistance is `defaultHigh`, so at 750 this
        // equality only tied with the text view's own intrinsic width and the
        // engine was free to satisfy either one. The stack then kept a width
        // the measurement never asked for. 999 beats every optional constraint
        // the text view raises and still loses to the required leading inset,
        // so a window too narrow for the measured width shrinks the stack
        // instead of breaking the layout.
        userTextWidthConstraint = stack.widthAnchor.constraint(
            equalToConstant: MessageTypography.outgoingTextMeasure
        )
        userTextWidthConstraint.priority = NSLayoutConstraint.Priority(999)
        userTextWidthConstraint.isActive = false
        stackTopConstraint = stack.topAnchor.constraint(
            equalTo: topAnchor,
            constant: MessageTypography.turnGap / 2
        )
        stackBottomConstraint = stack.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -MessageTypography.turnGap / 2
        )
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: MessageTypography.transcriptInset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MessageTypography.transcriptInset),
            centeredConstraint,
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: MessageTypography.readingMeasure),
            stackTopConstraint,
            measureWidthConstraint,
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
            stackBottomConstraint
        ])
        // The bubble is a sibling below the text, never its superview, so it
        // cannot clip a glyph. These four constraints stay active for every
        // speaker and `configure` only hides the view: a hidden view with
        // constant constraints costs no drawing, while activating and
        // deactivating them on every row reuse dirties the layout engine on
        // every scroll step.
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble, positioned: .below, relativeTo: stack)
        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(
                equalTo: stack.leadingAnchor,
                constant: -MessageTypography.outgoingBubblePaddingH
            ),
            bubble.trailingAnchor.constraint(
                equalTo: stack.trailingAnchor,
                constant: MessageTypography.outgoingBubblePaddingH
                    + OutgoingBubbleGeometry.tailWidth
            ),
            bubble.topAnchor.constraint(
                equalTo: stack.topAnchor,
                constant: -MessageTypography.outgoingBubblePaddingV
            ),
            bubble.bottomAnchor.constraint(
                equalTo: stack.bottomAnchor,
                constant: MessageTypography.outgoingBubblePaddingV
            )
        ])
        // The mark stands in the gutter that `hermesIndent` opens, beside the
        // first line of the turn. A band of its own would stand above the
        // answer, and every band under it would then move it further from the
        // line it marks.
        markView.imageScaling = .scaleProportionallyUpOrDown
        markView.setAccessibilityElement(false)
        markView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(markView)
        markTopConstraint = markView.topAnchor.constraint(
            equalTo: stack.topAnchor,
            constant: MarkGeometry.topInset(
                lineCenter: MarkGeometry.textLineCenter(
                    font: NSFont.preferredFont(forTextStyle: .body)
                )
            )
        )
        NSLayoutConstraint.activate([
            markView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            markView.widthAnchor.constraint(equalToConstant: MarkGeometry.side),
            markView.heightAnchor.constraint(equalToConstant: MarkGeometry.side),
            markTopConstraint
        ])
        roleLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        roleLabel.textColor = .secondaryLabelColor
        roleLabel.translatesAutoresizingMaskIntoConstraints = false
        // The role band is the label itself. A hidden arranged subview leaves
        // the stack, so a row with no role label has no empty band and no
        // extra gap. A nested stack with one hidden view keeps both.
        stack.addArrangedSubview(roleLabel)
        copyButton.title = "Copy code"
        copyButton.bezelStyle = .texturedRounded
        copyButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        copyButton.target = self
        copyButton.action = #selector(copyCodeAction)
        copyButton.setAccessibilityLabel("Copy code")
        stack.addArrangedSubview(copyButton)
        configureTextView(answerView)
        stack.addArrangedSubview(answerView)
        configureDisclosure(reasoningButton, title: DisclosureBand.reasoning)
        configureDisclosure(toolsButton, title: DisclosureBand.tools)
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
        resetOutgoing()
        setAccessibilityLabel("Loading transcript row")
    }

    /// Returns every outgoing-only property to its agent-row value.
    ///
    /// A recycled row must carry nothing from the turn before it: not the
    /// bubble, not the trailing alignment, not the measured width, and not the
    /// selection and link colours that only an accent fill needs.
    private func resetOutgoing() {
        isOutgoing = false
        outgoingFindQuery = ""
        bubble.isHidden = true
        centeredConstraint.isActive = true
        userTrailingConstraint.isActive = false
        userMaxWidthConstraint.isActive = false
        userTextWidthConstraint.isActive = false
        measureWidthConstraint.isActive = true
        stackTopConstraint.constant = MessageTypography.turnGap / 2
        stackBottomConstraint.constant = -MessageTypography.turnGap / 2
        roleLabel.isHidden = true
        answerView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor
        ]
        answerView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
    }

    func configure(
        turn: TranscriptTurn,
        document: MarkdownDocument?,
        reasoningExpanded: Bool,
        toolsExpanded: Bool,
        showsMetadata: Bool,
        findQuery: String,
        outgoingTextWidth: CGFloat? = nil,
        onReasoning: @escaping (String) -> Void,
        onTools: @escaping (String) -> Void,
        onCopyCode: @escaping (String) -> Void
    ) {
        turnID = turn.id
        self.onReasoning = onReasoning
        self.onTools = onTools
        self.onCopyCode = onCopyCode
        let isHermes = turn.speaker == .hermes
        let isUser = turn.speaker == .me
        if !isUser { resetOutgoing() }
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
        isOutgoing = isUser
        outgoingFindQuery = isUser ? findQuery : ""
        centeredConstraint.isActive = !isUser
        userTrailingConstraint.isActive = isUser
        userMaxWidthConstraint.isActive = isUser
        // A full-row width equality at priority 999 holds an outgoing stack at
        // its cap on any wide window, so a one-word bubble could never shrink.
        measureWidthConstraint.isActive = !isUser
        userTextWidthConstraint.isActive = isUser
        userTextWidthConstraint.constant = outgoingTextWidth
            ?? MessageTypography.outgoingTextMeasure
        // The bubble's padding sits inside the same row band an agent row uses,
        // so both speakers keep one turn rhythm and consecutive bubbles stay
        // exactly `turnGap` apart.
        let band = MessageTypography.turnGap / 2
            + (isUser ? MessageTypography.outgoingBubblePaddingV : 0)
        stackTopConstraint.constant = band
        stackBottomConstraint.constant = -band
        let indent = isHermes ? MessageTypography.hermesIndent : 0
        for constraint in bodyLeadingConstraints {
            constraint.constant = indent
        }
        // One resolution for the whole row. The bubble's fill and the text's
        // colour come out of the same value, so they cannot state two accents.
        let outgoing: OutgoingBubbleColors? = isUser ? outgoingColors() : nil
        let policy: TranscriptTurnTextRenderer.ForegroundPolicy
        if let outgoing { policy = .uniform(outgoing.foreground) } else { policy = .semantic }
        if let renderedDocument = document {
            answerView.textStorage?.setAttributedString(
                TranscriptTurnTextRenderer.attributedAnswer(
                    renderedDocument,
                    findQuery: findQuery,
                    foreground: policy
                )
            )
            // An outgoing row shows no copy button, so it must not walk the
            // document's blocks and join their code only to discard the result.
            codeToCopy = isUser
                ? ""
                : TranscriptTurnTextRenderer.codeText(renderedDocument)
        } else {
            answerView.textStorage?.setAttributedString(
                TranscriptTurnTextRenderer.plainAnswer(
                    turn.answer,
                    foreground: policy
                )
            )
            codeToCopy = ""
        }
        answerView.isHidden = turn.answer.isEmpty
        // `outgoing` is non-nil for exactly the turns `isUser` is true for.
        if let outgoing {
            applyOutgoingTextAttributes()
            // The user's own text needs no copy button, no disclosures, and no
            // metadata. Every one of those bands is dropped from the outgoing
            // measurement, so none of them may appear in the view.
            copyButton.isHidden = true
            copyButton.toolTip = nil
            reasoningButton.isHidden = true
            reasoningView.isHidden = true
            reasoningView.string = ""
            toolsButton.isHidden = true
            toolsView.isHidden = true
            toolsView.string = ""
            modelLabel.stringValue = ""
            modelLabel.isHidden = true
            reasoningLabel.stringValue = ""
            reasoningLabel.isHidden = true
            metadataAlwaysVisible = false
            metadataStack.isHidden = true
            metadataStack.alphaValue = 0
            bubble.isHidden = turn.answer.isEmpty
            bubble.apply(outgoing)
        } else {
            copyButton.isHidden = codeToCopy.isEmpty
            copyButton.toolTip = codeToCopy.isEmpty ? nil : "Copy code"
            reasoningButton.isHidden = turn.reasoning == nil
            reasoningView.isHidden = turn.reasoning == nil || !reasoningExpanded
            reasoningView.string = turn.reasoning?.text ?? ""
            applyDisclosure(
                title: reasoningExpanded
                    ? DisclosureBand.hideReasoning
                    : DisclosureBand.reasoning,
                to: reasoningButton,
                expanded: reasoningExpanded
            )
            toolsButton.isHidden = turn.tools.isEmpty
            toolsView.isHidden = turn.tools.isEmpty || !toolsExpanded
            toolsView.string = TranscriptTurnTextRenderer.toolText(turn.tools)
            applyDisclosure(
                title: toolsExpanded
                    ? DisclosureBand.hideTools
                    : DisclosureBand.tools,
                to: toolsButton,
                expanded: toolsExpanded
            )
            modelLabel.stringValue = turn.model ?? ""
            modelLabel.isHidden = turn.model == nil || turn.model?.isEmpty == true
            reasoningLabel.stringValue = turn.reasoning?.label ?? ""
            reasoningLabel.isHidden = turn.reasoning == nil
            metadataAlwaysVisible = showsMetadata
            metadataStack.isHidden = modelLabel.isHidden && reasoningLabel.isHidden
            metadataStack.alphaValue = metadataAlwaysVisible ? 1 : 0
        }
        // The mark follows the bands, so the row aligns it after it sets which
        // bands it shows.
        if isHermes { alignMark() }
        // A row recycled from `configureLoading` keeps announcing "Loading
        // transcript row" until a configured row replaces the label.
        setAccessibilityLabel(turn.speaker.label)
        needsLayout = true
    }

    /// Puts the mark beside the first line of the turn's first band.
    ///
    /// The stack pins its own top to the row, and the first band the row shows
    /// stands at that top. One constant therefore states the whole alignment.
    /// A turn with reasoning or tools shows a disclosure band first. An answer
    /// with code shows the copy band first. Every other turn shows the answer
    /// band first. A constant costs one layout pass. A separate anchor for each
    /// band would need constraint activation on every reuse.
    private func alignMark() {
        let lineCenter: CGFloat
        if !reasoningButton.isHidden {
            lineCenter = MarkGeometry.controlLineCenter(of: reasoningButton)
        } else if !toolsButton.isHidden {
            lineCenter = MarkGeometry.controlLineCenter(of: toolsButton)
        } else if !copyButton.isHidden {
            lineCenter = MarkGeometry.controlLineCenter(of: copyButton)
        } else {
            lineCenter = MarkGeometry.textLineCenter(font: firstAnswerFont())
        }
        let inset = MarkGeometry.topInset(lineCenter: lineCenter)
        // A write to a constant invalidates the layout, and a row is
        // reconfigured on every reuse during a scroll. Most rows resolve to the
        // same inset, so the row writes only a changed value.
        guard markTopConstraint.constant != inset else { return }
        markTopConstraint.constant = inset
    }

    /// The font of the answer's first character.
    ///
    /// A turn can start with a heading, and a heading line is taller than a
    /// body line. The attributed answer already carries the font, so the row
    /// reads it instead of assuming the body font.
    private func firstAnswerFont() -> NSFont {
        let body = NSFont.preferredFont(forTextStyle: .body)
        guard let storage = answerView.textStorage, storage.length > 0 else {
            return body
        }
        return storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            ?? body
    }

    /// The mark's box beside one line of text.
    ///
    /// The mark is a drawing, so it carries no text baseline. A square drawing
    /// looks aligned when its box holds the cap height of the line beside it in
    /// the centre. The capital letters are the ink that states where the line
    /// is. The row finds the centre of that ink. The row then puts the centre
    /// of the mark on it. Every value comes from the current text metrics, so
    /// the mark follows a text-size change with no new number.
    @MainActor
    private enum MarkGeometry {
        /// The mark's side, in points.
        ///
        /// The side plus a 6pt gap fills `hermesIndent` exactly, so the mark
        /// stands in the gutter and never under the text of the turn. The
        /// gutter is a fixed width, so the side is a fixed width as well. A
        /// larger text size moves the mark's centre, not its size, and the
        /// mark keeps the gutter it was drawn for.
        static let side: CGFloat = 14

        /// The distance from the top of a text band to the centre of the cap
        /// height of its first line.
        static func textLineCenter(font: NSFont) -> CGFloat {
            font.ascender - font.capHeight / 2
        }

        /// The distance from the top of a control band to the centre of its
        /// title.
        ///
        /// A disclosure band and a copy band hold one line each, so the centre
        /// of the title is half the height the control asks for.
        static func controlLineCenter(of control: NSControl) -> CGFloat {
            control.intrinsicContentSize.height / 2
        }

        /// The mark's top inset, measured down from the top of the first band.
        static func topInset(lineCenter: CGFloat) -> CGFloat {
            max(0, (lineCenter - side / 2).rounded())
        }
    }

    /// Re-resolves the bubble's colours after a system colour, appearance, or
    /// contrast change.
    ///
    /// The answer is not parsed again. One attribute run covers the whole text,
    /// and the Find matches are re-marked from the stored query.
    func reloadOutgoingPalette() {
        guard isOutgoing else { return }
        let colors = outgoingColors()
        bubble.apply(colors)
        guard let storage = answerView.textStorage, storage.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: colors.foreground, range: whole)
        TranscriptTurnTextRenderer.markOutgoingFindMatches(
            in: storage,
            query: outgoingFindQuery
        )
        storage.endEditing()
    }

    /// The bubble's colours in this row's appearance.
    ///
    /// This row's effective appearance is the one the bubble is seen in, and the
    /// bubble reads the same appearance through its own superview chain, so both
    /// callers of the palette land on one answer.
    private func outgoingColors() -> OutgoingBubbleColors {
        OutgoingBubblePalette.colors(for: effectiveAppearance)
    }

    /// Selection and link treatment for text on an accent fill.
    private func applyOutgoingTextAttributes() {
        // The default selection background is an accent tint, which is
        // invisible on an accent fill. The text-surface pair is the standard
        // one, follows appearance and contrast, and lifts the selection out of
        // the bubble.
        answerView.selectedTextAttributes = [
            .backgroundColor: NSColor.textBackgroundColor,
            .foregroundColor: NSColor.textColor
        ]
        // No foreground here. The attributed string already carries the row's
        // uniform colour on every run, and a Find match carries black. A
        // foreground in `linkTextAttributes` would override both.
        answerView.linkTextAttributes = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
    }

    private func configureTextView(_ view: NSTextView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainer?.lineFragmentPadding = 0
        // The first line starts at the top edge of the band. The mark takes its
        // position from that edge. The measured row height counts the bands
        // only. Neither may pay for an inset the band does not need.
        view.textContainerInset = .zero
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.font = NSFont.preferredFont(forTextStyle: .body)
    }

    /// The disclosure bands' fixed presentation, resolved once.
    ///
    /// A row is reconfigured on every reuse during a scroll, so neither an
    /// attributed title nor a symbol image may be built per row. The titles
    /// hold the dynamic `NSColor`, not a resolved one, so a band still follows
    /// an appearance change with no rebuild.
    @MainActor
    private enum DisclosureBand {
        static let font = NSFont.preferredFont(forTextStyle: .footnote)
        static let reasoning = title("Reasoning")
        static let hideReasoning = title("Hide reasoning")
        static let tools = title("Tools")
        static let hideTools = title("Hide tools")

        /// `chevron.forward` mirrors itself in a right-to-left layout.
        /// `chevron.right` does not.
        static let collapsedChevron = chevron("chevron.forward")
        static let expandedChevron = chevron("chevron.down")

        private static func title(_ value: String) -> NSAttributedString {
            NSAttributedString(
                string: value,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        }

        private static func chevron(_ name: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(textStyle: .footnote)
                )
        }
    }

    private func configureDisclosure(_ button: NSButton, title: NSAttributedString) {
        // Not `.disclosure`. That bezel is the bare system triangle: it has a
        // fixed 13x13pt intrinsic size, and its title rect is 13pt wide and
        // centred on the frame whatever `alignment` names. A band pinned across
        // the row therefore tightened "Reasoning" and clipped it to two
        // overlapping glyphs in the middle of the row. A borderless button
        // carries a title, and the system chevron states the disclosure.
        button.bezelStyle = .push
        button.isBordered = false
        button.alignment = .left
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = DisclosureBand.font
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        applyDisclosure(title: title, to: button, expanded: false)
    }

    /// Sets one band's title, chevron, and announcement together.
    ///
    /// `contentTintColor` reaches the symbol but not the title, so the title
    /// carries its own colour. One call site for all three values means an
    /// expanded band cannot keep a collapsed chevron or announce "show".
    private func applyDisclosure(
        title: NSAttributedString,
        to button: NSButton,
        expanded: Bool
    ) {
        // Both writes below invalidate the button's layout, and a row is
        // reconfigured on every reuse during a scroll. The title differs
        // between the two states, so this one compare covers the chevron and
        // the announcement as well.
        guard button.attributedTitle.string != title.string else { return }
        button.attributedTitle = title
        button.image = expanded
            ? DisclosureBand.expandedChevron
            : DisclosureBand.collapsedChevron
        button.setAccessibilityLabel(title.string)
    }

    @objc private func reasoningAction() { onReasoning(turnID) }
    @objc private func toolsAction() { onTools(turnID) }
    @objc private func copyCodeAction() {
        guard !codeToCopy.isEmpty else { return }
        onCopyCode(codeToCopy)
    }
}

/// A measured transcript row: the text's fitting width and the row height.
///
/// Width and height come from one measurement at one effective width, under one
/// cache key, so the width the view lays out at is the width the height was
/// computed at.
struct TranscriptTurnLayout: Hashable, Sendable {
    /// The tightest width the text fits in, never wider than the effective
    /// width it was measured against.
    let textWidth: CGFloat

    /// The whole row height, bands included.
    let height: CGFloat
}

private enum TranscriptTurnTextRenderer {
    /// How an attributed answer carries colour.
    enum ForegroundPolicy {
        /// Semantic label colours, for a row on the window background.
        case semantic

        /// One colour for every run, for a row on a filled bubble.
        case uniform(NSColor)

        /// No colour attributes at all, for the off-main measurement pass.
        ///
        /// Text metrics depend on font, paragraph style, and tracking, never on
        /// colour. Resolving a dynamic `NSColor` off the main thread is not
        /// safe, so the measurement pass names no colour.
        case unstyled

        /// Whether the row sits on a filled bubble.
        var isUniform: Bool {
            if case .uniform = self { true } else { false }
        }
    }

    static func plainAnswer(
        _ text: String,
        foreground: ForegroundPolicy = .semantic
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = MessageTypography.bodyLineSpacing
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .paragraphStyle: paragraph
        ]
        switch foreground {
        case .semantic: attributes[.foregroundColor] = NSColor.labelColor
        case .uniform(let color): attributes[.foregroundColor] = color
        case .unstyled: break
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    static func attributedAnswer(
        _ document: MarkdownDocument,
        findQuery: String = "",
        foreground: ForegroundPolicy = .semantic
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n\n")) }
            append(block, source: document, to: output, foreground: foreground)
        }
        markFindMatches(in: output, query: findQuery, onFill: foreground.isUniform)
        return output
    }

    /// Re-marks the Find matches on a filled row.
    ///
    /// A palette change must not parse the answer again, so the row re-marks
    /// the text it already holds.
    static func markOutgoingFindMatches(
        in output: NSMutableAttributedString,
        query: String
    ) {
        markFindMatches(in: output, query: query, onFill: true)
    }

    private static func markFindMatches(
        in output: NSMutableAttributedString,
        query: String,
        onFill: Bool
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
            if onFill {
                // A 22% accent tint is invisible on an accent fill.
                // `findHighlightColor` is the documented system find indicator
                // and is a bright yellow in both appearances. Black is the only
                // foreground that clears 4.5:1 on it. `textColor` would resolve
                // to white in dark mode and fail.
                output.addAttribute(
                    .backgroundColor,
                    value: NSColor.findHighlightColor,
                    range: found
                )
                output.addAttribute(
                    .foregroundColor,
                    value: NSColor.black,
                    range: found
                )
            } else {
                output.addAttribute(
                    .backgroundColor,
                    value: NSColor.controlAccentColor.withAlphaComponent(0.22),
                    range: found
                )
            }
            let next = found.location + max(1, found.length)
            search = NSRange(
                location: next,
                length: max(0, source.length - next)
            )
        }
    }

    static func effectiveWidth(
        for turn: TranscriptTurn,
        availableWidth: CGFloat
    ) -> CGFloat {
        let outer = max(1, min(MessageTypography.readingMeasure, availableWidth - 40))
        switch turn.speaker {
        case .me:
            // The tail and both bubble paddings come off the width before the
            // text gets any. `outer` already removed both transcript insets, so
            // the tail and the padding are all that remains to remove.
            return max(1, min(
                outer
                    - 2 * MessageTypography.outgoingBubblePaddingH
                    - OutgoingBubbleGeometry.tailWidth,
                MessageTypography.outgoingTextMeasure
            ))
        case .hermes:
            return max(1, outer - MessageTypography.hermesIndent)
        case .system:
            return outer
        }
    }

    /// The outgoing row height for a measured or an estimated text height.
    ///
    /// This is the constraint chain exactly: a 12pt band, 10pt of padding, the
    /// text, 10pt of padding, and a 12pt band. An outgoing row shows no role
    /// band, no disclosure band, no metadata band, and no copy band, so none of
    /// them is measured. The last point is the tolerance between the CoreText
    /// measurement and the text view's own layout rounding.
    static func outgoingRowHeight(textHeight: CGFloat) -> CGFloat {
        max(
            MessageTypography.outgoingMinimumTurnHeight,
            ceil(textHeight)
                + 2 * MessageTypography.outgoingBubblePaddingV
                + MessageTypography.turnGap
                + MessageTypography.outgoingMeasurementSlack
        )
    }

    static func provisionalHeight(
        turn: TranscriptTurn,
        availableWidth: CGFloat,
        reasoningExpanded: Bool,
        toolsExpanded: Bool
    ) -> CGFloat {
        let textWidth = effectiveWidth(for: turn, availableWidth: availableWidth)
        if turn.speaker == .me {
            return outgoingProvisionalHeight(turn: turn, textWidth: textWidth)
        }
        let charactersPerLine = max(1, Int(textWidth / 24))
        func hardLineCount(in value: String) -> Int {
            1 + value.utf8.reduce(into: 0) { count, byte in
                if byte == 10 { count += 1 }
            }
        }
        func wrappedLineCount(characters: Int, hardLines: Int) -> Int {
            max(hardLines, (max(1, characters) + charactersPerLine - 1) / charactersPerLine)
        }

        var lineCount = wrappedLineCount(
            characters: turn.answer.utf16.count,
            hardLines: hardLineCount(in: turn.answer)
        )
        if reasoningExpanded, let reasoning = turn.reasoning?.text {
            lineCount += wrappedLineCount(
                characters: reasoning.utf16.count,
                hardLines: hardLineCount(in: reasoning)
            )
        }
        if toolsExpanded {
            for (index, tool) in turn.tools.enumerated() {
                if index > 0 { lineCount += 1 }
                var characters = tool.name.utf16.count + tool.state.rawValue.utf16.count + 3
                var hardLines = hardLineCount(in: tool.name)
                    + hardLineCount(in: tool.state.rawValue)
                if let input = tool.input, !input.isEmpty {
                    characters += input.utf16.count + 8
                    hardLines += hardLineCount(in: input)
                }
                if let output = tool.output, !output.isEmpty {
                    characters += output.utf16.count + 9
                    hardLines += hardLineCount(in: output)
                }
                lineCount += wrappedLineCount(
                    characters: characters,
                    hardLines: hardLines
                )
            }
        }
        let channels = (turn.reasoning == nil ? 0 : 1) + (turn.tools.isEmpty ? 0 : 1)
        // An agent row has no role band. The mark stands in the gutter, beside
        // the first line of the turn, and takes no band of its own. A system
        // row shows a role label, so a system row keeps the band.
        let roleBand = turn.speaker == .system
            ? MessageTypography.roleLabelHeight
            : 0
        let fixedHeight = roleBand
            + MessageTypography.agentMeasurementReserve
            + CGFloat(channels) * MessageTypography.disclosureHeight
            + MessageTypography.metadataFooterHeight
            + CGFloat(channels + 1) * MessageTypography.internalBlockGap
            + MessageTypography.turnGap
        return max(
            MessageTypography.minimumTurnHeight,
            fixedHeight + CGFloat(lineCount) * max(MessageTypography.bodyLineHeight, 24)
        )
    }

    /// The outgoing height before the real measurement lands.
    ///
    /// The per-character advance is half the body point size, the standard
    /// approximation of a mean Latin lowercase advance. The agent branch's 24pt
    /// figure is about 3.7 times the real value, which would collapse the
    /// bubble visibly the moment the real measurement arrives.
    private static func outgoingProvisionalHeight(
        turn: TranscriptTurn,
        textWidth: CGFloat
    ) -> CGFloat {
        let advance = max(1, NSFont.preferredFont(forTextStyle: .body).pointSize / 2)
        let charactersPerLine = max(1, Int(textWidth / advance))
        // One pass gives both counts. A line feed is unit 10 in UTF-16 exactly
        // as it is byte 10 in UTF-8, so the hard-line count is unchanged.
        var characters = 0
        var lineFeeds = 0
        for unit in turn.answer.utf16 {
            characters += 1
            if unit == 10 { lineFeeds += 1 }
        }
        let lineCount = max(
            1 + lineFeeds,
            (max(1, characters) + charactersPerLine - 1) / charactersPerLine
        )
        return outgoingRowHeight(
            textHeight: CGFloat(lineCount)
                * (MessageTypography.bodyLineHeight + MessageTypography.bodyLineSpacing)
        )
    }

    /// Measures one row off the main thread.
    ///
    /// The outgoing branch keeps the framesetter's fitting width, which the
    /// agent branch has no use for. That width is what lets a short bubble hug
    /// its text with no main-thread text layout.
    static func measuredLayout(
        turn: TranscriptTurn,
        document: MarkdownDocument,
        width: CGFloat,
        reasoningExpanded: Bool,
        toolsExpanded: Bool
    ) -> TranscriptTurnLayout {
        let contentWidth = max(1, width)
        switch turn.speaker {
        case .me:
            return outgoingLayout(document: document, width: contentWidth)
        case .hermes, .system:
            return agentLayout(
                turn: turn,
                document: document,
                width: contentWidth,
                reasoningExpanded: reasoningExpanded,
                toolsExpanded: toolsExpanded
            )
        }
    }

    private static func outgoingLayout(
        document: MarkdownDocument,
        width: CGFloat
    ) -> TranscriptTurnLayout {
        // The display string, without its colours. The agent branch measures
        // raw Markdown source in a substitute font, which a height with slack
        // survives but a width does not: a wrong width wraps differently from
        // the view, and the cached height is then wrong for the width the view
        // lays out at, which is clipped text.
        let value = attributedAnswer(document, foreground: .unstyled)
        let framesetter = CTFramesetterCreateWithAttributedString(value)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: value.length),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        return TranscriptTurnLayout(
            textWidth: min(width, ceil(size.width)),
            height: outgoingRowHeight(textHeight: size.height)
        )
    }

    private static func agentLayout(
        turn: TranscriptTurn,
        document: MarkdownDocument,
        width: CGFloat,
        reasoningExpanded: Bool,
        toolsExpanded: Bool
    ) -> TranscriptTurnLayout {
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
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        let channels = (turn.reasoning == nil ? 0 : 1) + (turn.tools.isEmpty ? 0 : 1)
        // The role band belongs to a system row only. See `provisionalHeight`.
        let roleBand = turn.speaker == .system
            ? MessageTypography.roleLabelHeight
            : 0
        let height = max(
            MessageTypography.minimumTurnHeight,
            ceil(size.height)
                + roleBand
                + MessageTypography.agentMeasurementReserve
                + CGFloat(channels) * MessageTypography.disclosureHeight
                + MessageTypography.metadataFooterHeight
                + CGFloat(channels + 1) * MessageTypography.internalBlockGap
                + MessageTypography.turnGap
        )
        return TranscriptTurnLayout(textWidth: width, height: height)
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

    private static func append(
        _ block: MarkdownBlock,
        source: MarkdownDocument,
        to output: NSMutableAttributedString,
        foreground policy: ForegroundPolicy
    ) {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = MessageTypography.bodyLineSpacing
        paragraph.paragraphSpacing = MessageTypography.paragraphGap
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]
        switch policy {
        case .semantic: attributes[.foregroundColor] = NSColor.labelColor
        case .uniform(let color): attributes[.foregroundColor] = color
        case .unstyled: break
        }
        switch block {
        case .paragraph(_, _, let inlines): output.append(attributedInline(inlines, attributes: attributes))
        case .heading(_, _, let level, let inlines):
            var heading = attributes; heading[.font] = headingFont(level, bodyFont: font)
            output.append(attributedInline(inlines, attributes: heading))
        case .quote(_, _, let inlines):
            var quoteAttributes = attributes
            // A uniform foreground stays uniform. A secondary label colour on
            // an accent fill is unreadable.
            if case .semantic = policy {
                quoteAttributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
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
            // The 42% window-background tint reads as a code block only on the
            // window background. On an accent fill it dims the fill under the
            // text and eats the contrast the foreground was chosen for, so an
            // outgoing row keeps the monospaced typography and drops the tint.
            if case .semantic = policy {
                codeAttributes[.backgroundColor] = NSColor.controlBackgroundColor.withAlphaComponent(0.42)
            }
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
                // The inherited attributes already carry the row's foreground,
                // so a link on an accent fill stays legible. The text view's
                // `linkTextAttributes` supplies the underline.
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
