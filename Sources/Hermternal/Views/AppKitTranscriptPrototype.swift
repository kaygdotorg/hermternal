import AppKit
import HermternalCore
import SwiftUI


struct AppKitTranscript: NSViewRepresentable {
    let messages: [ChatMessage]
    let routeIdentity: String
    let isReadOnly: Bool
    let isStreaming: Bool
    var findQuery: String = ""
    var findMatches: [TranscriptMatch] = []
    var activeFindIndex: Int? = nil
    var pendingMessageID: MessageIdentity?
    var onRequestOlder: () -> Void = {}
    var onCopyCode: (String) -> Void = { _ in }


    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    func makeNSView(context: Context) -> AppKitTranscriptContainerView {
        context.coordinator.makeContainer()
    }

    func updateNSView(_ nsView: AppKitTranscriptContainerView, context: Context) {
        context.coordinator.update(
            container: nsView,
            messages: messages,
            routeIdentity: routeIdentity,
            isReadOnly: isReadOnly,
            isStreaming: isStreaming,
            findQuery: findQuery,
            findMatches: findMatches,
            activeFindIndex: activeFindIndex,
            pendingMessageID: pendingMessageID,
            onRequestOlder: onRequestOlder,
            onCopyCode: onCopyCode
        )
    }

    static func dismantleNSView(_ nsView: AppKitTranscriptContainerView, coordinator: Coordinator) {
        coordinator.dismantle(container: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var messages: [ChatMessage] = []
        private var routeIdentity = ""
        private var isReadOnly = false
        private var isStreaming = false
        private var findQuery = ""
        private var findMatches: [TranscriptMatch] = []
        private var activeFindIndex: Int?
        private var pendingMessageID: MessageIdentity?
        private var onRequestOlder: () -> Void = {}
        private var onCopyCode: (String) -> Void = { _ in }
        private var olderRequestMessageCount = -1
        private var positionedMessageID: MessageIdentity?
        private var positionedFindMessageID: MessageIdentity?
        private weak var container: AppKitTranscriptContainerView?
        private var positioningGeneration = 0
        private weak var tableView: AppKitTranscriptTableView?
        private var scrollObserver: NSObjectProtocol?

        func makeContainer() -> AppKitTranscriptContainerView {
            let tableView = AppKitTranscriptTableView()
            tableView.delegate = self
            tableView.dataSource = self
            tableView.headerView = nil
            tableView.intercellSpacing = NSSize(width: 0, height: 18)
            tableView.selectionHighlightStyle = .none
            tableView.allowsEmptySelection = true
            tableView.allowsMultipleSelection = false
            tableView.usesAlternatingRowBackgroundColors = false
            tableView.rowSizeStyle = .custom
            tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            tableView.backgroundColor = .clear
            tableView.addTableColumn(NSTableColumn(identifier: .init("transcript")))

            let container = AppKitTranscriptContainerView(tableView: tableView)
            self.container = container
            self.tableView = tableView
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: tableView.enclosingScrollView?.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.requestOlderIfNeeded()
            }
            updateEmptyState(in: container)
            return container
        }

        func update(
            container: AppKitTranscriptContainerView,
            messages: [ChatMessage],
            routeIdentity: String,
            isReadOnly: Bool,
            isStreaming: Bool,
            findQuery: String,
            findMatches: [TranscriptMatch],
            activeFindIndex: Int?,
            pendingMessageID: MessageIdentity?,
            onRequestOlder: @escaping () -> Void,
            onCopyCode: @escaping (String) -> Void
        ) {
            let routeChanged = self.routeIdentity != routeIdentity
            let oldMessages = self.messages
            if oldMessages.count != messages.count {
                olderRequestMessageCount = -1
            }
            let findChanged = self.findQuery != findQuery
                || self.findMatches != findMatches
                || self.activeFindIndex != activeFindIndex
            let pendingChanged = self.pendingMessageID != pendingMessageID
            self.container = container
            self.tableView = container.tableView
            self.routeIdentity = routeIdentity
            self.isReadOnly = isReadOnly
            self.isStreaming = isStreaming
            self.findQuery = findQuery
            self.findMatches = findMatches
            self.activeFindIndex = activeFindIndex
            self.pendingMessageID = pendingMessageID
            self.onRequestOlder = onRequestOlder
            self.onCopyCode = onCopyCode
            self.messages = messages
            if routeChanged {
                positionedMessageID = nil
                positionedFindMessageID = nil
            }
            updateEmptyState(in: container)

            let changedRows = changedRowIndexes(
                oldMessages: oldMessages,
                newMessages: messages,
                window: TranscriptWindow(range: renderedRange, hasMoreOlderMessages: false)
            )
            guard routeChanged || oldMessages.count != messages.count || !changedRows.isEmpty
                    || findChanged || pendingChanged else {
                schedulePositioning(routeChanged: false)
                return
            }
            if routeChanged || oldMessages.count != messages.count || findChanged || pendingChanged {
                container.tableView.reloadData()
            } else {
                container.tableView.reloadData(
                    forRowIndexes: changedRows,
                    columnIndexes: IndexSet(integer: 0)
                )
            }
            container.tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: 0..<max(1, messages.count))
            )
            container.layoutTableDocument()
            schedulePositioning(routeChanged: routeChanged)
        }

        func dismantle(container: AppKitTranscriptContainerView) {
            positioningGeneration &+= 1
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
            renderedRange.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            let index = renderedRange.lowerBound + row
            guard messages.indices.contains(index),
                  let rowView = tableView.makeView(
                    withIdentifier: AppKitTranscriptRowView.identifier,
                    owner: self
                  ) as? AppKitTranscriptRowView
            else { return nil }
            let message = messages[index]
            let matchRanges = findMatches
                .filter { $0.messageIndex == index }
                .map(\.range)
            let isActive = activeFindIndex.map {
                findMatches.indices.contains($0) && findMatches[$0].messageIndex == index
            } ?? false
            rowView.configure(
                message: message,
                content: AppKitTranscriptRenderCache.shared.attributedString(
                    for: message,
                    displayScale: displayScale(for: tableView)
                ),
                findRanges: findQuery.isEmpty ? [] : matchRanges,
                isFindActive: isActive,
                onCopyCode: onCopyCode
            )
            return rowView
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let index = renderedRange.lowerBound + row
            guard messages.indices.contains(index) else { return 24 }
            return AppKitTranscriptRenderCache.shared.height(
                for: messages[index],
                width: contentWidth(for: messages[index], in: tableView),
                displayScale: displayScale(for: tableView)
            )
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false
        }

        func tableView(
            _ tableView: NSTableView,
            shouldEdit tableColumn: NSTableColumn?,
            row: Int
        ) -> Bool {
            false
        }

        private var renderedRange: Range<Int> {
            0..<messages.count
        }

        private func changedRowIndexes(
            oldMessages: [ChatMessage],
            newMessages: [ChatMessage],
            window: TranscriptWindow
        ) -> IndexSet {
            var changed = IndexSet()
            for row in 0..<window.range.count {
                let index = window.range.lowerBound + row
                guard newMessages.indices.contains(index) else { continue }
                let old = oldMessages.indices.contains(index) ? oldMessages[index] : nil
                let new = newMessages[index]
                if old?.id != new.id || old?.role != new.role
                    || old?.text != new.text || old?.isStreaming != new.isStreaming {
                    changed.insert(row)
                }
            }
            return changed
        }

        private func contentWidth(for message: ChatMessage, in tableView: NSTableView) -> CGFloat {
            // NSTableView can ask for heights before its document view has
            // received the clip view's width. The clip view is the authoritative
            // width in that first pass; using bounds.width there measured rows
            // against the initial 1pt table frame.
            let tableWidth = tableView.enclosingScrollView?.contentView.bounds.width
                ?? tableView.bounds.width
            let leadingInset: CGFloat
            let trailingInset: CGFloat
            let maximumWidth: CGFloat
            switch message.role {
            case .assistant:
                leadingInset = 48
                trailingInset = 24
                maximumWidth = MessageTypography.readingMeasure
            case .user:
                leadingInset = 60
                trailingInset = 24
                maximumWidth = MessageTypography.userBubbleMeasure
                    - MessageTypography.bubblePadding * 2
            case .system:
                leadingInset = 20
                trailingInset = 20
                maximumWidth = .greatestFiniteMagnitude
            }
            let available = max(
                1,
                tableWidth - leadingInset - trailingInset
                    - contentViewHorizontalInset * 2
            )
            return min(available, maximumWidth)
        }

        private var contentViewHorizontalInset: CGFloat {
            MessageTypography.bubblePadding
        }

        private func displayScale(for tableView: NSTableView) -> CGFloat {
            tableView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        }

        private func updateEmptyState(in container: AppKitTranscriptContainerView) {
            let empty = messages.isEmpty
            container.tableView.isHidden = empty
            container.emptyImageView.isHidden = !empty
            if empty {
                container.emptyImageView.image = AppKitTranscriptEmptyState.image(
                    for: container.effectiveAppearance
                )
            }
        }

        private func schedulePositioning(routeChanged: Bool) {
            positioningGeneration &+= 1
            let generation = positioningGeneration
            guard !messages.isEmpty else { return }

            // Do not replace this with DispatchWorkItem: the malformed
            // @MainActor work-item construction crashed in _Block_copy,
            // before any positioning work ran. A generation-gated main-queue
            // closure coalesces rapid updates without cancellation or
            // double-perform state. Every stale closure returns before
            // touching the table.
            DispatchQueue.main.async { @MainActor [weak self] in
                guard let self, generation == self.positioningGeneration else { return }
                guard let tableView = self.tableView else { return }
                tableView.layoutSubtreeIfNeeded()
                if let pending = self.pendingMessageID {
                    guard let index = self.messages.firstIndex(where: { $0.id == pending }) else { return }
                    guard self.positionedMessageID != pending || routeChanged else { return }
                    self.scrollToMessage(at: index)
                    self.positionedMessageID = pending
                    return
                }
                if let activeIndex = self.activeFindIndex,
                   self.findMatches.indices.contains(activeIndex) {
                    let active = self.findMatches[activeIndex]
                    guard self.messages.indices.contains(active.messageIndex) else { return }
                    let id = self.messages[active.messageIndex].id
                    guard self.positionedFindMessageID != id || routeChanged else { return }
                    self.scrollToMessage(at: active.messageIndex)
                    self.positionedFindMessageID = id
                    return
                }
                guard !self.isReadOnly, routeChanged || self.isStreaming else { return }
                self.scrollToBottom()
            }
        }

        private func requestOlderIfNeeded() {
            guard let tableView,
                  let scrollView = tableView.enclosingScrollView,
                  scrollView.contentView.bounds.origin.y <= 1,
                  olderRequestMessageCount != messages.count
            else { return }
            olderRequestMessageCount = messages.count
            onRequestOlder()

        }
        private func scrollToMessage(at index: Int) {
            guard let tableView, renderedRange.contains(index) else { return }
            tableView.scrollRowToVisible(index - renderedRange.lowerBound)
        }

        private func scrollToBottom() {
            guard let container, !messages.isEmpty else { return }
            let tableView = container.tableView
            tableView.layoutSubtreeIfNeeded()
            guard let scrollView = tableView.enclosingScrollView else { return }
            let clipView = scrollView.contentView
            var origin = clipView.bounds.origin
            origin.y = max(0, tableView.bounds.height - clipView.bounds.height)
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}

/// The table overrides the documented `makeView` seam so the first request
/// creates a row and later requests receive rows from NSTableView's reuse queue.
@MainActor
final class AppKitTranscriptTableView: NSTableView {
    override func makeView(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        owner: Any?
    ) -> NSView? {
        if let reused = super.makeView(withIdentifier: identifier, owner: owner) {
            return reused
        }
        guard identifier == AppKitTranscriptRowView.identifier else { return nil }
        return AppKitTranscriptRowView()
    }
}

@MainActor
final class AppKitTranscriptRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("AppKitTranscriptRow")

    private let contentView = NSTextView()
    private let copyButton = NSButton()
    private let assistantMark = NSImageView()
    private var copiedCode = ""
    private var contentRole: Role = .system
    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?
    private var copyHandler: (String) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        layer?.cornerCurve = .continuous

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.isSelectable = true
        contentView.isEditable = false
        contentView.isRichText = true
        contentView.drawsBackground = false
        contentView.textContainerInset = NSSize(
            width: MessageTypography.bubblePadding,
            height: 10
        )
        contentView.textContainer?.lineFragmentPadding = 0
        contentView.textContainer?.widthTracksTextView = true
        contentView.textContainer?.heightTracksTextView = false
        contentView.isVerticallyResizable = false
        contentView.isHorizontallyResizable = false
        contentView.autoresizingMask = [.width]
        addSubview(contentView)

        contentView.wantsLayer = true
        assistantMark.translatesAutoresizingMaskIntoConstraints = false
        assistantMark.imageScaling = .scaleProportionallyUpOrDown
        assistantMark.image = AppKitTranscriptEmptyState.image(for: effectiveAppearance)
        addSubview(assistantMark)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.title = "Copy"
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton.imagePosition = .imageLeading
        copyButton.bezelStyle = .texturedRounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyCode)
        copyButton.isHidden = true
        addSubview(copyButton)

        leadingConstraint = contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20)
        copyButton.toolTip = "Copy"
        trailingConstraint = contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20)
        NSLayoutConstraint.activate([
            leadingConstraint!,
            trailingConstraint!,
            assistantMark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            assistantMark.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            assistantMark.widthAnchor.constraint(equalToConstant: 20),
            assistantMark.heightAnchor.constraint(equalToConstant: 20),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            copyButton.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        ])
    }

    override func layout() {
        super.layout()
        let leadingInset: CGFloat
        let trailingInset: CGFloat
        let maximumOuterWidth: CGFloat
        switch contentRole {
        case .assistant:
            leadingInset = 48
            trailingInset = 24
            maximumOuterWidth = MessageTypography.readingMeasure
                + contentView.textContainerInset.width * 2
        case .user:
            leadingInset = 60
            trailingInset = 24
            maximumOuterWidth = MessageTypography.userBubbleMeasure
        case .system:
            leadingInset = 20
            trailingInset = 20
            maximumOuterWidth = .greatestFiniteMagnitude
        }
        let available = max(1, bounds.width - leadingInset - trailingInset)
        let outerWidth = min(available, maximumOuterWidth)
        if contentRole == .user {
            leadingConstraint?.constant = max(
                leadingInset,
                bounds.width - trailingInset - outerWidth
            )
            trailingConstraint?.constant = -trailingInset
        } else {
            leadingConstraint?.constant = leadingInset
            trailingConstraint?.constant = -max(
                trailingInset,
                bounds.width - leadingInset - outerWidth
            )
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        message: ChatMessage,
        content: NSAttributedString,
        findRanges: [Range<Int>],
        isFindActive: Bool,
        onCopyCode: @escaping (String) -> Void
    ) {
        copyHandler = onCopyCode
        var rendered = NSMutableAttributedString(attributedString: content)
        if !findRanges.isEmpty {
            let projected = FindTextHighlighting.project(
                findRanges,
                from: message.text,
                to: rendered.string
            )
            for (offset, range) in projected.enumerated() {
                let nsRange = NSRange(location: range.lowerBound, length: range.count)
                rendered.addAttribute(
                    .foregroundColor,
                    value: offset == 0 ? NSColor.systemOrange : NSColor.systemYellow,
                    range: nsRange
                )
                if let font = rendered.attribute(.font, at: nsRange.location, effectiveRange: nil) as? NSFont {
                    rendered.addAttribute(
                        .font,
                        value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                        range: nsRange
                    )
            }
            }
        }
        contentRole = message.role
        contentView.textStorage?.setAttributedString(rendered)
        contentView.alignment = message.role == .user ? .right : (message.role == .system ? .center : .left)

        assistantMark.isHidden = message.role != .assistant
        assistantMark.image = AppKitTranscriptEmptyState.image(for: effectiveAppearance)
        layer?.backgroundColor = isFindActive
            ? NSColor.systemOrange.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
        layer?.borderColor = isFindActive ? NSColor.systemOrange.withAlphaComponent(0.8).cgColor : NSColor.clear.cgColor
        layer?.borderWidth = isFindActive ? 1 : 0

        // SwiftUI creates TranscriptCodeBlock only for parsed fenced-code
        // segments inside assistant MarkdownMessage rows. In particular, a
        // user row remains plain text even if its payload contains backticks.
        let codeSegments = message.role == .assistant
            ? MarkdownSegment.parse(message.text).compactMap { segment -> String? in
                if case .code(_, _, let body) = segment { return body }
                return nil
            }
            : []
        let hasCodeBlock = !codeSegments.isEmpty
        copiedCode = codeSegments.joined(separator: "\n")
        contentView.layer?.cornerRadius = hasCodeBlock
            ? 6
            : (message.role == .user ? AppShapeScale.toast : 0)
        contentView.layer?.backgroundColor = hasCodeBlock
            ? NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
            : (message.role == .user
                ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
                : NSColor.clear.cgColor)
        copyButton.isHidden = !hasCodeBlock
        if message.isStreaming && message.text.isEmpty {
            contentView.string = "•••"
            contentView.textStorage?.addAttribute(
                .foregroundColor,
                value: NSColor.secondaryLabelColor,
                range: NSRange(location: 0, length: contentView.string.utf16.count)
            )
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.35
            animation.toValue = 1
            animation.duration = 0.72
            animation.autoreverses = true
            animation.repeatCount = .infinity
            contentView.layer?.add(animation, forKey: "thinking")
        } else {
            contentView.layer?.removeAnimation(forKey: "thinking")
        }

        }
    @objc private func copyCode() {
        copyHandler(copiedCode)
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyButton.title = "Copy"
        }
    }
}

@MainActor
final class AppKitTranscriptContainerView: NSView {
    let tableView: AppKitTranscriptTableView
    let emptyImageView: NSImageView
    private let scrollView: NSScrollView

    init(tableView: AppKitTranscriptTableView) {
        self.tableView = tableView
        emptyImageView = NSImageView()
        scrollView = NSScrollView()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        tableView.translatesAutoresizingMaskIntoConstraints = true
        tableView.autoresizingMask = [.width]
        tableView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        scrollView.documentView = tableView
        emptyImageView.translatesAutoresizingMaskIntoConstraints = false
        emptyImageView.imageScaling = .scaleProportionallyUpOrDown
        emptyImageView.imageAlignment = .alignCenter
        emptyImageView.setAccessibilityLabel("Hermternal")
        addSubview(scrollView)
        addSubview(emptyImageView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyImageView.widthAnchor.constraint(equalToConstant: 128),
            emptyImageView.heightAnchor.constraint(equalToConstant: 128)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layoutTableDocument()
    }

    func layoutTableDocument() {
        let contentView = scrollView.contentView
        let width = max(1, contentView.bounds.width)
        tableView.frame.size.width = width
        tableView.noteHeightOfRows(
            withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows)
        )
        let height = max(1, tableView.fittingSize.height)
        tableView.frame.size.height = height
    }
}


/// The renderer cache has one byte budget and one deterministic LRU policy for
/// both prepared attributed content and measured row heights. A row-height key
/// carries identity, revision, width, text style, backing scale, and renderer
/// version; omitting any one of those inputs can reuse a wrong measurement.
@MainActor
private final class AppKitTranscriptRenderCache {
    private struct ContentKey: Hashable {
        let messageID: MessageIdentity
        let revision: String
        let textStyle: String
        let displayScaleBits: UInt64
        let rendererVersion: Int
    }

    private enum Key: Hashable {
        case content(ContentKey)
        case height(RowHeightCacheKey)
    }

    private enum Value {
        case attributed(NSAttributedString)
        case height(CGFloat)
    }

    static let shared = AppKitTranscriptRenderCache()
    private let storage = ByteBoundedCache<Key, Value>(
        byteBudget: MarkdownSegment.parseCacheByteBudget
    )

    /// A content-cache hit costs key construction, one bounded lookup, and
    /// the caller's `attributedStringValue` assignment/alignment. It performs
    /// no Markdown parsing or attributed-string construction.
    func attributedString(for message: ChatMessage, displayScale: CGFloat) -> NSAttributedString {
        let key = contentKey(for: message, displayScale: displayScale)
        if case .attributed(let cached)? = storage.value(for: .content(key)) {
            return cached
        }

        let prepared = AppKitTranscriptText.attributedString(for: message)
        let cost = byteCost(for: message, style: key.textStyle) + prepared.length * 2
        storage.insert(.attributed(prepared), for: .content(key), byteCost: cost)
        return prepared
    }
 
    /// A height-cache hit costs key construction and one bounded lookup, then
    /// returns the stored CGFloat. It creates no text storage, layout manager,
    /// text container, or layout transaction.

    func height(
        for message: ChatMessage,
        width: CGFloat,
        displayScale: CGFloat
    ) -> CGFloat {
        let key = rowHeightKey(
            for: message,
            width: width,
            displayScale: displayScale
        )
        if case .height(let cached)? = storage.value(for: .height(key)) {
            return cached
        }

        let content = attributedString(for: message, displayScale: displayScale)
        let widthValue = max(1, CGFloat(Double(bitPattern: key.availableWidthBits)))
        let textStorage = NSTextStorage(attributedString: content)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: widthValue, height: .greatestFiniteMagnitude)
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        // usedRect may otherwise reflect only the first fragment when the
        // delegate is measuring during NSTableView's pre-layout pass.
        layoutManager.ensureLayout(for: textContainer)
        let measured = max(4, ceil(layoutManager.usedRect(for: textContainer).height) + 20)
        storage.insert(
            .height(measured),
            for: .height(key),
            byteCost: byteCost(for: message, style: key.textStyle) + 32
        )
        return measured
    }
    private func byteCost(for message: ChatMessage, style: String) -> Int {
        let textBytes = message.text.utf8.count.multipliedReportingOverflow(by: 2)
        let styleBytes = style.utf8.count.multipliedReportingOverflow(by: 2)
        let total = textBytes.partialValue
            .addingReportingOverflow(styleBytes.partialValue)
            .partialValue
            .addingReportingOverflow(256)
            .partialValue
        return max(256, total)
    }

    private func contentKey(
        for message: ChatMessage,
        displayScale: CGFloat
    ) -> ContentKey {
        ContentKey(
            messageID: message.id,
            revision: AppKitTranscriptText.revision(for: message),
            textStyle: AppKitTranscriptText.styleSignature(for: message),
            displayScaleBits: Double(displayScale).bitPattern,
            rendererVersion: AppKitTranscriptText.rendererVersion
        )
    }

    private func rowHeightKey(
        for message: ChatMessage,
        width: CGFloat,
        displayScale: CGFloat
    ) -> RowHeightCacheKey {
        RowHeightCacheKey(
            messageID: message.id,
            revision: AppKitTranscriptText.revision(for: message),
            availableWidthBits: Double(width).bitPattern,
            textStyle: AppKitTranscriptText.styleSignature(for: message),
            displayScaleBits: Double(displayScale).bitPattern,
            rendererVersion: AppKitTranscriptText.rendererVersion
        )
    }
}

@MainActor
private enum AppKitTranscriptText {
    static let rendererVersion = 1

    static func revision(for message: ChatMessage) -> String {
        // The complete payload is the revision: unlike a digest, this cannot
        // collide and reuse a measurement for different message text.
        message.text
    }

    static func styleSignature(for message: ChatMessage) -> String {
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let heading = headingFont(1)
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return [
            String(describing: message.role),
            "streaming=\(message.isStreaming)",
            "body=\(body.fontDescriptor.postscriptName ?? "")@\(body.pointSize)",
            "heading=\(heading.fontDescriptor.postscriptName ?? "")@\(heading.pointSize)",
            "mono=\(mono.fontDescriptor.postscriptName ?? "")@\(mono.pointSize)",
            "line=\(MessageTypography.bodyLineSpacing)",
            "marker=\(MessageTypography.markerColumn)",
            "gap=\(MessageTypography.markerGap)",
            "version=\(rendererVersion)"
        ].joined(separator: "|")
    }

    static func attributedString(for message: ChatMessage) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if message.isStreaming {
            Self.append(message.text, to: result, font: NSFont.systemFont(ofSize: NSFont.systemFontSize))
            if result.length > 0 {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.lineSpacing = MessageTypography.bodyLineSpacing
                result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))
                result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: result.length))
            }
            return result
        }
        let segments = MarkdownSegment.parse(message.text)
        var previous: MarkdownSegment?
        for segment in segments {
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            let start = result.length
            switch segment {
            case .heading(_, let level, let content):
                Self.append(content, to: result, font: Self.headingFont(level))
            case .prose(_, let content):
                Self.append(content, to: result, font: NSFont.systemFont(ofSize: NSFont.systemFontSize))
            case .bullet(_, _, let depth, let content):
                Self.append("\(String(repeating: " ", count: depth * 3))\(MessageTypography.bulletGlyph(depth))  ", to: result, font: NSFont.systemFont(ofSize: NSFont.systemFontSize))
                Self.append(content, to: result, font: NSFont.systemFont(ofSize: NSFont.systemFontSize))
            case .numbered(_, let marker, let number, let depth, let content):
                let delimiter = marker.last.map { $0 == ")" ? ")" : "." } ?? "."
                Self.append("\(String(repeating: " ", count: depth * 3))\(number)\(delimiter)  ", to: result, font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
                Self.append(content, to: result, font: NSFont.systemFont(ofSize: NSFont.systemFontSize))
            case .code(_, let language, let body):
                let label = language.isEmpty ? "code" : language
                Self.append("\(label)\n\(body)", to: result, font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
            }
            let end = result.length
            guard end > start else { continue }
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = MessageTypography.bodyLineSpacing
            if let previous {
                paragraphStyle.paragraphSpacingBefore = MessageTypography.spacing(from: .init(previous), to: .init(segment))
            }
            result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: start, length: end - start))
            result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: start, length: end - start))
            previous = segment
        }
        if result.length == 0 { result.append(NSAttributedString(string: "")) }
        return result
    }

    private static func append(_ text: String, to result: NSMutableAttributedString, font: NSFont) {
        let start = result.length
        result.append(NSAttributedString(string: text))
        result.addAttribute(.font, value: font, range: NSRange(location: start, length: text.utf16.count))
    }

    private static func append(_ text: AttributedString, to result: NSMutableAttributedString, font: NSFont) {
        let start = result.length
        let converted = NSAttributedString(text)
        result.append(converted)
        result.addAttribute(.font, value: font, range: NSRange(location: start, length: converted.length))
    }

    private static func headingFont(_ level: Int) -> NSFont {
            let size: CGFloat
            switch level {
            case 1: size = 22
            case 2: size = 19
            default: size = 16
            }
            return NSFont.systemFont(ofSize: size, weight: .semibold)
        }
    }

@MainActor
private enum AppKitTranscriptEmptyState {
    private static let light = load("HermternalMarkLight")
    private static let dark = load("HermternalMarkDark")

    static func image(for appearance: NSAppearance) -> NSImage? {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (isDark ? dark : light)
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Hermternal")
    }

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
