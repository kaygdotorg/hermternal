import AppKit
import CoreText
import HermternalCore
import SwiftUI

/// A block-oriented AppKit transcript. The table owns only visible row views;
/// source text remains in `TranscriptRendererInput.messages` and is sliced by
/// each block's UTF-16 range.
struct BlockTranscriptView: NSViewRepresentable {
    let input: TranscriptRendererInput

    init(input: TranscriptRendererInput) {
        self.input = input
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

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
        private struct Row {
            let block: TranscriptBlock
            let message: ChatMessage
            let messageIndex: Int
            let text: String
        }

        /// Immutable value data prepared away from the main actor. The row
        /// consumes this value without parsing Markdown or measuring text.
        fileprivate struct Prepared: Sendable {
            let key: BlockLayoutKey
            let text: String
            let attributed: AttributedString?
            let measuredHeight: CGFloat
            let code: Bool
        }

        private let preparation = BlockPreparationCoordinator(laneCount: 4)
        private let layoutCache = BlockLayoutCache()
        private let selection = BlockSelectionCoordinator()
        private var prepared: [BlockLayoutKey: Prepared] = [:]
        private var rows: [Row] = []
        private var blocks: [TranscriptBlock] = []
        private var messages: [ChatMessage] = []
        private var messageTextByID: [String: String] = [:]
        private var messageIndexByID: [String: Int] = [:]
        private var routeIdentity = ""
        private var isReadOnly = false
        private var isStreaming = false
        private var findQuery = ""
        private var findMatches: [TranscriptMatch] = []
        private var activeFindIndex: Int?
        private var pendingMessageID: MessageIdentity?
        private var hasMoreOlderMessages = false
        private var onRequestOlder: () -> Void = {}
        private var onCopyCode: (String) -> Void = { _ in }
        private weak var container: BlockTranscriptContainerView?
        private weak var tableView: NSTableView?
        private var scrollObserver: NSObjectProtocol?
        private var generation = 0
        /// Eight rows keeps a small amount of rich content ready during a
        /// wheel tick without shaping blocks outside the visible neighborhood.
        private let overdrawRows = 8

        func makeContainer() -> BlockTranscriptContainerView {
            let table = BlockTranscriptTableView()
            table.delegate = self
            table.dataSource = self
            table.headerView = nil
            table.intercellSpacing = .zero
            table.selectionHighlightStyle = .none
            table.allowsEmptySelection = true
            table.allowsMultipleSelection = false
            table.rowSizeStyle = .custom
            table.setAccessibilityElement(false)
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.backgroundColor = .clear
            table.addTableColumn(NSTableColumn(identifier: .init("block-transcript")))

            let result = BlockTranscriptContainerView(tableView: table)
            container = result
            tableView = table
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: table.enclosingScrollView?.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.prepareVisibleBlocks()
                self.requestOlderIfNeeded()
            }
            return result
        }

        func update(container: BlockTranscriptContainerView, input: TranscriptRendererInput) {
            let routeChanged = routeIdentity != input.routeIdentity
            if routeChanged {
                generation &+= 1
                preparation.cancel()
                prepared.removeAll(keepingCapacity: true)
                layoutCacheResetForRoute()
                selection.clear()
            }
            let oldRows = rows
            let oldBlocks = blocks
            let oldMessages = messages

            container.onPaint = input.onPaint
            self.container = container
            self.tableView = container.tableView
            self.routeIdentity = input.routeIdentity
            self.isReadOnly = input.isReadOnly
            self.isStreaming = input.isStreaming
            self.findQuery = input.findQuery
            self.findMatches = input.findMatches
            self.activeFindIndex = input.activeFindIndex
            self.hasMoreOlderMessages = input.window.hasMoreOlderMessages
            self.onRequestOlder = input.onRequestOlder
            self.onCopyCode = input.onCopyCode
            self.messages = input.messages
            self.messageTextByID = Dictionary(uniqueKeysWithValues: input.messages.map {
                (messageID(for: $0), $0.text)
            })
            self.messageIndexByID = Dictionary(uniqueKeysWithValues: input.messages.enumerated().map {
                (messageID(for: $0.element), $0.offset)
            })

            let incomingBlocks = input.blocks.isEmpty
                ? input.messages.flatMap { TranscriptBlockSegmenter.blocks(for: $0) }
                : input.blocks
            let nextBlocks = reconciledBlocks(
                oldBlocks: oldBlocks,
                oldMessages: oldMessages,
                newBlocks: incomingBlocks,
                newMessages: input.messages
            )
            self.blocks = nextBlocks
            self.rows = makeRows(from: nextBlocks, messages: input.messages)
            updateAccessibility(in: container)

            let changed = changedRowIndexes(oldRows: oldRows, newRows: rows)
            container.tableView.isHidden = rows.isEmpty
            if routeChanged || oldRows.isEmpty && !rows.isEmpty {
                container.tableView.noteNumberOfRowsChanged()
                container.layoutTableDocument()
            } else if !changed.isEmpty {
                container.tableView.noteNumberOfRowsChanged()
                container.tableView.reloadData(
                    forRowIndexes: changed,
                    columnIndexes: IndexSet(integer: 0)
                )
                container.layoutTableDocument()
            }
            prepareVisibleBlocks()
            schedulePositioning(routeChanged: routeChanged)
        }

        func dismantle(container: BlockTranscriptContainerView) {
            generation &+= 1
            preparation.cancel()
            container.tableView.delegate = nil
            container.tableView.dataSource = nil
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
                self.scrollObserver = nil
            }
            if self.container === container {
                self.container = nil
                tableView = nil
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard rows.indices.contains(row),
                  let view = tableView.makeView(
                    withIdentifier: BlockTranscriptRowView.identifier,
                    owner: self
                  ) as? BlockTranscriptRowView
            else { return nil }
            let value = rows[row]
            let key = layoutKey(for: value.block, tableView: tableView)
            let preparedValue = prepared[key]
            let messageStart = row == 0 || rows[row - 1].message.id != value.message.id
            let messageEnd = row == rows.count - 1 || rows[row + 1].message.id != value.message.id
            let sourceMatches = findQuery.isEmpty ? [] : findMatches
                .filter { $0.messageIndex == value.messageIndex }
                .map(\.range)
            let active = activeFindIndex.map {
                findMatches.indices.contains($0)
                    && findMatches[$0].messageIndex == value.messageIndex
            } ?? false
            view.configure(
                block: value.block,
                message: value.message,
                sourceText: value.text,
                prepared: preparedValue,
                isFirstInMessage: messageStart,
                isLastInMessage: messageEnd,
                findRanges: sourceMatches,
                isFindActive: active,
                selection: selection,
                allBlocks: blocks,
                messageText: { [weak self] id in self?.messageTextByID[id] },
                onCopyCode: onCopyCode
            )
            return view
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 24 }
            let value = rows[row]
            let key = layoutKey(for: value.block, tableView: tableView)
            if let cached = layoutCache.value(for: key) {
                return cached.measuredHeight
            }
            return BlockHeightEstimator.estimatedHeight(for: value.block, width: contentWidth(for: value.message, in: tableView))
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false
        }

        private func reconciledBlocks(
            oldBlocks: [TranscriptBlock],
            oldMessages: [ChatMessage],
            newBlocks: [TranscriptBlock],
            newMessages: [ChatMessage]
        ) -> [TranscriptBlock] {
            guard let oldMessage = oldMessages.last,
                  let newMessage = newMessages.last,
                  oldMessage.id == newMessage.id,
                  oldMessage.text != newMessage.text,
                  newMessage.text.utf16.starts(with: oldMessage.text.utf16),
                  !oldBlocks.isEmpty
            else { return newBlocks }
            // Only the final logical block is re-segmented. The caller's blocks
            // remain authoritative, while this path preserves the segmenter's
            // unchanged prefix and gives us the precise changed suffix.
            let previous = oldBlocks.filter { $0.messageID == messageID(for: oldMessage) }
            let result = TranscriptBlockSegmenter.resegment(
                previous: previous,
                previousMessage: oldMessage,
                message: newMessage
            )
            let prefix = oldBlocks.prefix(while: {
                $0.messageID != messageID(for: oldMessage)
            })
            return Array(prefix) + result.blocks
        }

        private func makeRows(from blocks: [TranscriptBlock], messages: [ChatMessage]) -> [Row] {
            var byID: [String: ChatMessage] = [:]
            var indices: [String: Int] = [:]
            for (index, message) in messages.enumerated() {
                byID[messageID(for: message)] = message
                indices[messageID(for: message)] = index
            }
            return blocks.compactMap { block in
                guard let message = byID[block.messageID], let index = indices[block.messageID] else { return nil }
                return Row(
                    block: block,
                    message: message,
                    messageIndex: index,
                    text: Self.slice(message.text, range: block.sourceRange)
                )
            }
        }

        private func changedRowIndexes(oldRows: [Row], newRows: [Row]) -> IndexSet {
            var result = IndexSet()
            let count = max(oldRows.count, newRows.count)
            for index in 0..<count {
                guard newRows.indices.contains(index) else { continue }
                guard !oldRows.indices.contains(index)
                    || oldRows[index].block != newRows[index].block
                    || oldRows[index].message.role != newRows[index].message.role
                    || oldRows[index].message.isStreaming != newRows[index].message.isStreaming
                else { continue }
                result.insert(index)
            }
            return result
        }

        private func layoutKey(for block: TranscriptBlock, tableView: NSTableView) -> BlockLayoutKey {
            BlockLayoutKey(
                contentHash: block.contentHash,
                width: contentWidth(for: rowMessage(for: block), in: tableView),
                fontSignature: "system-\(NSFont.systemFontSize)",
                displayScaleBits: Double(displayScale(for: tableView)).bitPattern,
                appearanceMode: appearanceMode(for: tableView),
                localeIdentifier: Locale.current.identifier,
                rendererVersion: 1
            )
        }

        private func rowMessage(for block: TranscriptBlock) -> ChatMessage {
            rows.first(where: { $0.block.id == block.id })?.message
                ?? messages.first(where: { messageID(for: $0) == block.messageID })
                ?? ChatMessage(role: .system, text: "")
        }

        private func prepareVisibleBlocks() {
            guard let tableView, !rows.isEmpty else { return }
            let visible = tableView.rows(in: visibleRect(for: tableView))
            guard visible.location != NSNotFound else { return }
            let lower = max(0, visible.location - overdrawRows)
            let upper = min(rows.count, visible.location + visible.length + overdrawRows)
            let candidates = rows[lower..<upper].filter {
                let key = layoutKey(for: $0.block, tableView: tableView)
                return prepared[key] == nil
            }
            guard !candidates.isEmpty else { return }
            let requestGeneration = generation
            let displayScale = self.displayScale(for: tableView)
            let appearance = appearanceMode(for: tableView)
            let locale = Locale.current.identifier
            let candidatesArray = Array(candidates)
            let keys = candidatesArray.map { row in
                BlockLayoutKey(
                    contentHash: row.block.contentHash,
                    width: contentWidth(for: row.message, in: tableView),
                    fontSignature: "system-\(NSFont.systemFontSize)",
                    displayScaleBits: Double(displayScale).bitPattern,
                    appearanceMode: appearance,
                    localeIdentifier: locale,
                    rendererVersion: 1
                )
            }
            let keyByID = Dictionary(uniqueKeysWithValues: zip(candidatesArray, keys).map {
                ($0.0.block.id, $0.1)
            })
            Task { [weak self] in
                guard let self else { return }
                await self.preparation.prepare(
                    candidatesArray.map(\.block),
                    preparation: { [messageTextByID, keyByID] (block: TranscriptBlock) -> Prepared? in
                        guard !Task.isCancelled,
                              let source = messageTextByID[block.messageID],
                              let key = keyByID[block.id]
                        else { return nil }
                        let text = Self.slice(source, range: block.sourceRange)
                        let rich = Self.richContent(for: block.kind, source: text)
                        let measured = Self.measuredHeight(
                            for: block.kind,
                            text: text,
                            width: key.representativeWidth
                        )
                        return Prepared(
                            key: key,
                            text: text,
                            attributed: rich,
                            measuredHeight: measured,
                            code: block.kind == .code
                        )
                    },
                    onResult: { [weak self] (result: Prepared) in
                        await MainActor.run {
                            guard let self, self.generation == requestGeneration else { return }
                            self.accept(result)
                        }
                    }
                )
            }
        }

        private func accept(_ result: Prepared) {
            let oldHeight = layoutCache.value(for: result.key)?.measuredHeight
            prepared[result.key] = result
            layoutCache.insert(
                preparedContent: result.text,
                measuredHeight: result.measuredHeight,
                for: result.key
            )
            guard let tableView,
                  let row = rows.firstIndex(where: { layoutKey(for: $0.block, tableView: tableView) == result.key })
            else { return }
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            guard oldHeight != result.measuredHeight else { return }
            let visible = visibleRect(for: tableView)
            let boundary = tableView.rows(in: visible).location
            // The boundary is sampled from the clip view at correction time,
            // never cached from an earlier update. Rows above it are left alone
            // so the cursor does not jump while a rich layout arrives.
            guard boundary != NSNotFound, row >= boundary else { return }
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            container?.layoutTableDocument()
        }

        private func visibleRect(for tableView: NSTableView) -> NSRect {
            guard let clip = tableView.enclosingScrollView?.contentView else { return tableView.bounds }
            return tableView.convert(clip.bounds, from: clip)
        }

        private func contentWidth(for message: ChatMessage, in tableView: NSTableView) -> CGFloat {
            let tableWidth = tableView.enclosingScrollView?.contentView.bounds.width ?? tableView.bounds.width
            let outer = max(1, tableWidth - 44)
            switch message.role {
            case .assistant:
                return min(outer - MessageTypography.bubblePadding * 2, MessageTypography.readingMeasure)
            case .user:
                return min(outer - MessageTypography.bubblePadding * 2, MessageTypography.userBubbleMeasure - MessageTypography.bubblePadding * 2)
            case .system:
                return outer
            }
        }

        private func displayScale(for tableView: NSTableView) -> CGFloat {
            tableView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        }

        private func appearanceMode(for tableView: NSTableView) -> String {
            tableView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "aqua"
        }

        private func requestOlderIfNeeded() {
            guard hasMoreOlderMessages,
                  let tableView,
                  let scroll = tableView.enclosingScrollView,
                  scroll.contentView.bounds.origin.y <= 1
            else { return }
            onRequestOlder()
        }

        private func schedulePositioning(routeChanged: Bool) {
            let current = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current, let tableView else { return }
                tableView.layoutSubtreeIfNeeded()
                if let pending = pendingMessageID,
                   let index = rows.firstIndex(where: { $0.message.id == pending }) {
                    tableView.scrollRowToVisible(index)
                } else if routeChanged || isStreaming, !isReadOnly, !rows.isEmpty {
                    let clip = tableView.enclosingScrollView?.contentView
                    clip?.scroll(to: NSPoint(x: 0, y: max(0, tableView.bounds.height - (clip?.bounds.height ?? 0))))
                    if let clip { tableView.enclosingScrollView?.reflectScrolledClipView(clip) }
                }
            }
        }

        private func updateAccessibility(in container: BlockTranscriptContainerView) {
            container.messageElements = Dictionary(grouping: rows, by: { $0.message.id }).values.map {
                BlockMessageAccessibilityElement(
                    label: $0.first?.message.text ?? "",
                    blocks: $0.map { BlockAccessibilityElement(label: $0.text) }
                )
            }
        }


        private func layoutCacheResetForRoute() {
            // Cache keys include content, route-independent layout inputs, and
            // therefore remain safe across routes. Prepared AppKit values do not.
        }

        nonisolated private static func richContent(for kind: TranscriptBlock.Kind, source: String) -> AttributedString? {
            switch kind {
            case .code:
                return nil
            default:
                guard let first = MarkdownSegment.parse(source).first else {
                    return AttributedString(source)
                }
                switch first {
                case .prose(_, let value), .heading(_, _, let value), .bullet(_, _, _, let value), .numbered(_, _, _, _, let value):
                    return value
                case .code(_, _, let body):
                    return AttributedString(body)
                }
            }
        }
        /// Core Text shaping is immutable and thread-safe for this read-only
        /// operation. TextKit layout managers are intentionally not used here.
        nonisolated private static func measuredHeight(
            for kind: TranscriptBlock.Kind,
            text: String,
            width: CGFloat
        ) -> CGFloat {
            let fontName = kind == .code ? "Menlo" : "SF Pro Text"
            let size: CGFloat = kind == .heading ? 16 : 13
            let font = CTFontCreateWithName(fontName as CFString, size, nil)
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let proposed = CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: attributed.length),
                nil,
                proposed,
                nil
            ).height
            return max(1, ceil(measured) + (kind == .code ? 12 : 8))
        }

        nonisolated private static func slice(_ text: String, range: Range<Int>) -> String {
            let ns = text as NSString
            let lower = max(0, min(ns.length, range.lowerBound))
            let upper = max(lower, min(ns.length, range.upperBound))
            return ns.substring(with: NSRange(location: lower, length: upper - lower))
        }

        private func messageID(for message: ChatMessage) -> String {
            Self.messageID(for: message)
        }

        private static func messageID(for message: ChatMessage) -> String {
            switch message.id {
            case .server(let id): return String(id.rawValue)
            case .provisional(let id): return id.uuidString
            }
        }
    }
}

@MainActor
private final class BlockTranscriptTableView: NSTableView {
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        super.makeView(withIdentifier: identifier, owner: owner)
            ?? (identifier == BlockTranscriptRowView.identifier ? BlockTranscriptRowView() : nil)
    }
}

@MainActor
private final class BlockTranscriptRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BlockTranscriptRow")
    private let textView = BlockTranscriptTextView()
    private let assistantMark = NSImageView()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var messageRole: Role = .assistant
    private let copyButton = NSButton()
    private var position: BlockTextPosition?
    private weak var selection: BlockSelectionCoordinator?
    private var allBlocks: [TranscriptBlock] = []
    private var messageText: (String) -> String? = { _ in nil }
    private var onCopyCode: (String) -> Void = { _ in }
    private var copiedCode = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: MessageTypography.bubblePadding, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.onBegin = { [weak self] offset in self?.reportBegin(offset) }
        textView.onExtend = { [weak self] offset in self?.reportExtend(offset) }
        addSubview(textView)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.title = "Copy"
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")
        copyButton.imagePosition = .imageLeading
        copyButton.bezelStyle = .texturedRounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyCodeAction)
        copyButton.isHidden = true
        addSubview(copyButton)
        assistantMark.translatesAutoresizingMaskIntoConstraints = false
        assistantMark.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Assistant")
        addSubview(assistantMark)
        leading = textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48)
        trailing = textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24)
        NSLayoutConstraint.activate([
            leading,
            trailing,
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            copyButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            assistantMark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            assistantMark.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            assistantMark.widthAnchor.constraint(equalToConstant: 20),
            assistantMark.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    fileprivate func configure(
        block: TranscriptBlock,
        message: ChatMessage,
        sourceText: String,
        prepared: BlockTranscriptView.Coordinator.Prepared?,
        isFirstInMessage: Bool,
        isLastInMessage: Bool,
        findRanges: [Range<Int>],
        isFindActive: Bool,
        selection: BlockSelectionCoordinator,
        allBlocks: [TranscriptBlock],
        messageText: @escaping (String) -> String?,
        onCopyCode: @escaping (String) -> Void
    ) {
        self.messageRole = message.role
        self.selection = selection
        self.allBlocks = allBlocks
        self.messageText = messageText
        self.onCopyCode = onCopyCode
        self.position = BlockTextPosition(
            messageID: block.messageID,
            blockIndex: block.blockIndex,
            utf16Offset: 0
        )
        textView.position = position
        textView.selectionHandler = self

        let content: NSAttributedString
        if let prepared {
            content = NSAttributedString(prepared.attributed ?? AttributedString(prepared.text))
            copiedCode = prepared.code ? prepared.text : ""
        } else {
            let font = block.kind == .code
                ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                : NSFont.systemFont(ofSize: NSFont.systemFontSize)
            content = NSAttributedString(string: sourceText, attributes: [.font: font])
            copiedCode = block.kind == .code ? sourceText : ""
        }
        textView.textStorage?.setAttributedString(content)
        textView.alignment = message.role == .user ? .right : (message.role == .system ? .center : .left)
        assistantMark.isHidden = message.role != .assistant || !isFirstInMessage
        layer?.backgroundColor = message.role == .user
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        copyButton.isHidden = copiedCode.isEmpty
        layer?.cornerRadius = message.role == .user ? AppShapeScale.toast : 0
        layer?.maskedCorners = {
            var corners: CACornerMask = []
            if isFirstInMessage { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
            if isLastInMessage { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
            return corners
        }()
        layer?.borderWidth = isFindActive ? 1 : 0
        layer?.borderColor = isFindActive ? NSColor.systemOrange.cgColor : NSColor.clear.cgColor
        if !findRanges.isEmpty {
            let projected = findRanges.compactMap { range -> NSRange? in
                let lower = max(range.lowerBound, block.sourceRange.lowerBound)
                let upper = min(range.upperBound, block.sourceRange.upperBound)
                guard upper > lower else { return nil }
                return NSRange(location: lower - block.sourceRange.lowerBound, length: upper - lower)
            }
            for range in projected {
                textView.textStorage?.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: range)
            }
        }
        setAccessibilityLabel(sourceText)
    }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width - 44)
        let outer = min(width, messageRole == .user ? MessageTypography.userBubbleMeasure : MessageTypography.readingMeasure)
        if messageRole == .user {
            leading.constant = max(60, bounds.width - 24 - outer)
            trailing.constant = -24
        } else {
            leading.constant = messageRole == .assistant ? 48 : 20
            trailing.constant = -max(20, bounds.width - leading.constant - outer)
        }
    }

    private func reportBegin(_ offset: Int) {
        guard let position, let selection else { return }
        selection.begin(at: position.withOffset(offset))
    }

    private func reportExtend(_ offset: Int) {
        guard let position, let selection else { return }
        selection.extend(to: position.withOffset(offset))
    }

    fileprivate func copySelection() {
        guard let selection, let range = selection.selectedRange else { return }
        let plain = selection.plainText(for: range, blocks: allBlocks, messageText: messageText)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain, forType: .string)
    }

    fileprivate func copyCode() {
        guard !copiedCode.isEmpty else { return }
        onCopyCode(copiedCode)
    }
    @objc private func copyCodeAction() {
        copyCode()
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyButton.title = "Copy"
        }
    }
}

@MainActor
private final class BlockTranscriptTextView: NSTextView {
    var position: BlockTextPosition?
    var onBegin: (Int) -> Void = { _ in }
    var onExtend: (Int) -> Void = { _ in }
    weak var selectionHandler: BlockTranscriptRowView?

    override func mouseDown(with event: NSEvent) {
        onBegin(offset(for: event))
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        onExtend(offset(for: event))
        super.mouseDragged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            selectionHandler?.copySelection()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func offset(for event: NSEvent) -> Int {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndex(for: point)
        return max(0, min(string.utf16.count, index))
    }

}

private extension BlockTextPosition {
    func withOffset(_ offset: Int) -> BlockTextPosition {
        BlockTextPosition(messageID: messageID, blockIndex: blockIndex, utf16Offset: offset)
    }
}

@MainActor
final class BlockTranscriptContainerView: NSView {
    let tableView: NSTableView
    private let scrollView = NSScrollView()
    private var lastDocumentWidth: CGFloat = 0
    fileprivate var messageElements: [BlockMessageAccessibilityElement] = []
    var onPaint: ((UInt64) -> Void)?

    init(tableView: NSTableView) {
        self.tableView = tableView
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.setAccessibilityElement(false)
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        tableView.translatesAutoresizingMaskIntoConstraints = true
        tableView.autoresizingMask = [.width]
        tableView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        scrollView.documentView = tableView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layoutTableDocument()
    }

    /// Updates the document frame after row-count, width, or corrected-height
    /// changes. Width invalidation starts at the visible boundary so resize
    /// estimates cannot move content above the cursor.
    func layoutTableDocument() {
        let width = max(1, scrollView.contentView.bounds.width)
        let widthChanged = abs(lastDocumentWidth - width) > 0.5
        lastDocumentWidth = width
        if widthChanged {
            let visibleRect = tableView.enclosingScrollView.map {
                tableView.convert($0.contentView.bounds, from: $0.contentView)
            } ?? tableView.bounds
            let boundary = tableView.rows(in: visibleRect).location
            let start = boundary == NSNotFound ? 0 : boundary
            if start < tableView.numberOfRows {
                tableView.noteHeightOfRows(
                    withIndexesChanged: IndexSet(integersIn: start..<tableView.numberOfRows)
                )
            }
        }
        tableView.frame.size.width = width
        tableView.frame.size.height = max(1, tableView.fittingSize.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let timestamp = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            self?.onPaint?(timestamp)
        }
    }

    override func accessibilityChildren() -> [Any] {
        messageElements
    }
}

@MainActor
fileprivate final class BlockMessageAccessibilityElement: NSView {
    private let spokenLabel: String
    private let childElements: [BlockAccessibilityElement]

    init(label: String, blocks: [BlockAccessibilityElement]) {
        spokenLabel = label
        childElements = blocks
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityLabel() -> String? { spokenLabel }
    override func accessibilityChildren() -> [Any] { childElements }
}

@MainActor
fileprivate final class BlockAccessibilityElement: NSView {
    private let spokenLabel: String

    init(label: String) {
        spokenLabel = label
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityLabel() -> String? { spokenLabel }
}

