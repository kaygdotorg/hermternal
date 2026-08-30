import AppKit
import HermternalCore
import SwiftUI

/// A native NSTextView adapter for the composer's two Markdown representations.
///
/// MarkdownDocument remains the only parser. NSTextView owns selection, undo,
/// paste, marked text, Writing Tools, and the system text services.
struct ComposerMarkdownEditor: NSViewRepresentable {
    @Binding var source: String
    @Binding var mode: ComposerEditorMode
    @Binding var measuredHeight: CGFloat
    @Binding var isFocused: Bool
    let isEditable: Bool
    let focusRequest: Int
    let formatRequest: ComposerEditorFormat?
    let onSubmit: () -> Void
    let onEscape: () -> Bool
    let onFormatHandled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.publishFocus(focused)
        }
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onEscape = onEscape
        context.coordinator.source = $source
        context.coordinator.mode = $mode
        context.coordinator.focus = $isFocused
        context.coordinator.lastSource = source
        context.coordinator.lastMode = mode
        context.coordinator.lastFocusRequest = focusRequest
        configure(textView)
        context.coordinator.render(source: source, mode: mode, in: textView)

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(x: 0, y: 0, width: 320, height: 38)
        scrollView.documentView = textView
        return scrollView
    }

    @MainActor
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard let textView = nsView.documentView as? NSTextView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return nil
        }
        let width = max(1, proposal.width ?? 320)
        textView.frame.size.width = width
        textContainer.containerSize.width = width
        layoutManager.ensureLayout(for: textContainer)
        let measured = layoutManager.usedRect(for: textContainer).height
        let height = CGFloat(ComposerEditorHeightPolicy.height(for: Double(measured)))
        context.coordinator.publishHeight(height, to: $measuredHeight)
        return CGSize(
            width: proposal.width ?? width,
            height: height
        )

    }

    @MainActor
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.source = $source
        context.coordinator.mode = $mode
        context.coordinator.focus = $isFocused
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onEscape = onEscape


        var didApplyFormat = false
        if let format = formatRequest, formatRequest != context.coordinator.lastFormatRequest {
            context.coordinator.apply(format, to: textView)
            context.coordinator.lastFormatRequest = formatRequest
            didApplyFormat = true
            onFormatHandled()
        } else if formatRequest == nil {
            context.coordinator.lastFormatRequest = nil
        }
        if !didApplyFormat,
           context.coordinator.lastMode != mode || context.coordinator.lastSource != source {
            let selectedRange = textView.selectedRange()
            let selectedText = (textView.string as NSString).substring(with: selectedRange)
            context.coordinator.render(source: source, mode: mode, in: textView)
            if !selectedText.isEmpty, let range = textView.string.range(of: selectedText) {
                let location = textView.string.utf16.distance(
                    from: textView.string.utf16.startIndex,
                    to: range.lowerBound
                )
                textView.setSelectedRange(NSRange(location: location, length: selectedText.utf16.count))
            } else {
                let length = textView.string.utf16.count
                let location = min(selectedRange.location, length)
                textView.setSelectedRange(NSRange(
                    location: location,
                    length: min(selectedRange.length, max(0, length - location))
                ))
            }
            context.coordinator.lastMode = mode
            context.coordinator.lastSource = source
        }
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window != nil else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    private func configure(_ textView: NSTextView) {
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: CGFloat(ComposerEditorHeightPolicy.minimum))
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat(ComposerEditorHeightPolicy.maximum))
        textView.textContainerInset = NSSize(width: 0, height: 7)
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.drawsBackground = false
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.usesFindBar = true
        textView.writingToolsBehavior = .complete
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var source: Binding<String> = .constant("")
        var mode: Binding<ComposerEditorMode> = .constant(.wysiwyg)
        var onSubmit: (() -> Void)?
        var onEscape: (() -> Bool)?
        var lastSource = ""
        var lastMode: ComposerEditorMode = .wysiwyg
        var focus: Binding<Bool> = .constant(false)
        private var lastPublishedHeight: CGFloat?
        private var pendingHeight: CGFloat?
        private var heightGeneration = 0
        private var lastPublishedFocus = false
        private var pendingFocus: Bool?
        private var focusGeneration = 0

        func publishHeight(_ height: CGFloat, to binding: Binding<CGFloat>) {
            let current = binding.wrappedValue
            guard ComposerEditorHeightPolicy.nextHeight(
                measuredContentHeight: Double(height) - ComposerEditorHeightPolicy.verticalInset,
                currentHeight: Double(current)
            ) != nil else {
                return
            }
            if let pendingHeight,
               ComposerEditorHeightPolicy.isEquivalent(Double(pendingHeight), Double(height)) {
                return
            }
            if let lastPublishedHeight,
               ComposerEditorHeightPolicy.isEquivalent(Double(lastPublishedHeight), Double(height)) {
                return
            }
            heightGeneration += 1
            let generation = heightGeneration
            pendingHeight = height
            Task { @MainActor [weak self] in
                guard let self, self.heightGeneration == generation else { return }
                self.pendingHeight = nil
                guard !ComposerEditorHeightPolicy.isEquivalent(
                    Double(binding.wrappedValue),
                    Double(height)
                ) else {
                    self.lastPublishedHeight = height
                    return
                }
                binding.wrappedValue = height
                self.lastPublishedHeight = height
            }
        }

        func publishFocus(_ focused: Bool) {
            guard ComposerEditorInteractionPolicy.shouldPublishFocusChange(
                from: lastPublishedFocus,
                to: focused
            ) else {
                return
            }
            if pendingFocus == focused { return }
            focusGeneration += 1
            let generation = focusGeneration
            pendingFocus = focused
            Task { @MainActor [weak self] in
                guard let self, self.focusGeneration == generation else { return }
                self.pendingFocus = nil
                guard self.focus.wrappedValue != focused else {
                    self.lastPublishedFocus = focused
                    return
                }
                self.focus.wrappedValue = focused
                self.lastPublishedFocus = focused
            }
        }
        var lastFocusRequest = 0
        var lastFormatRequest: ComposerEditorFormat?
        private var lastVisibleText = ""
        private var isApplying = false
        func textDidChange(_ notification: Notification) {
            guard !isApplying,
                  let textView = notification.object as? NSTextView else { return }
            let visible = textView.string
            if mode.wrappedValue == .source {
                source.wrappedValue = visible
            } else {
                source.wrappedValue = sourceAfterVisibleEdit(
                    oldVisible: lastVisibleText,
                    newVisible: visible,
                    source: source.wrappedValue
                )
            }
            lastSource = source.wrappedValue
            lastVisibleText = visible
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == Selector(("cancelOperation:")) {
                return onEscape?() ?? false
            }
            let isReturn = selector == Selector(("insertNewline:"))
                || selector == Selector(("insertNewlineIgnoringFieldEditor:"))
            guard isReturn else { return false }
            if textView.hasMarkedText() || NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                return false
            }
            onSubmit?()
            return true
        }

        private func sourceAfterVisibleEdit(
            oldVisible: String,
            newVisible: String,
            source: String
        ) -> String {
            let oldUnits = Array(oldVisible.utf16)
            let newUnits = Array(newVisible.utf16)
            var prefix = 0
            while prefix < oldUnits.count, prefix < newUnits.count,
                  oldUnits[prefix] == newUnits[prefix] {
                prefix += 1
            }
            var suffix = 0
            while suffix < oldUnits.count - prefix,
                  suffix < newUnits.count - prefix,
                  oldUnits[oldUnits.count - suffix - 1] == newUnits[newUnits.count - suffix - 1] {
                suffix += 1
            }
            let sourceBase: Int
            if let range = source.range(of: oldVisible) {
                sourceBase = source.utf16.distance(from: source.utf16.startIndex, to: range.lowerBound)
            } else {
                sourceBase = 0
            }
            let lower = sourceBase + prefix
            let upper = sourceBase + oldUnits.count - suffix
            var result = Array(source.utf16)
            let boundedLower = min(max(0, lower), result.count)
            let boundedUpper = min(max(boundedLower, upper), result.count)
            result.replaceSubrange(
                boundedLower..<boundedUpper,
                with: newUnits[prefix..<(newUnits.count - suffix)]
            )
            return String(decoding: result, as: UTF16.self)
        }
        func render(source: String, mode: ComposerEditorMode, in textView: NSTextView) {
            isApplying = true
            textView.undoManager?.disableUndoRegistration()
            defer {
                textView.undoManager?.enableUndoRegistration()
                isApplying = false
                lastVisibleText = textView.string
            }
            switch mode {
            case .source:
                textView.string = source
                textView.typingAttributes = Self.baseAttributes
            case .wysiwyg:
                let parsed = MarkdownDocument.parse(source)
                textView.textStorage?.setAttributedString(Self.attributedString(for: parsed.document))
            }
        }

        func apply(_ format: ComposerEditorFormat, to textView: NSTextView) {
            let selected = textView.selectedRange()
            let visibleSelection = (textView.string as NSString).substring(with: selected)
            let selectedRange: Range<Int>
            if mode.wrappedValue == .source {
                selectedRange = selected.location..<(selected.location + selected.length)
            } else if let range = source.wrappedValue.range(of: visibleSelection) {
                let lower = source.wrappedValue.utf16.distance(
                    from: source.wrappedValue.utf16.startIndex,
                    to: range.lowerBound
                )
                selectedRange = lower..<(lower + visibleSelection.utf16.count)
            } else {
                selectedRange = selected.location..<(selected.location + selected.length)
            }
            let edit = ComposerEditorFormatter.apply(
                format,
                source: source.wrappedValue,
                selectedRange: selectedRange
            )
            isApplying = true
            source.wrappedValue = edit.source
            if mode.wrappedValue == .source {
                textView.string = edit.source
                textView.setSelectedRange(NSRange(
                    location: edit.selectedRange.lowerBound,
                    length: edit.selectedRange.count
                ))
            } else {
                render(source: edit.source, mode: .wysiwyg, in: textView)
                if let range = textView.string.range(of: visibleSelection) {
                    let lower = textView.string.utf16.distance(
                        from: textView.string.utf16.startIndex,
                        to: range.lowerBound
                    )
                    textView.setSelectedRange(NSRange(location: lower, length: visibleSelection.utf16.count))
                }
            }
            isApplying = false
            lastSource = edit.source
            lastVisibleText = textView.string
        }

        private static let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ]

        private static func attributedString(for document: MarkdownDocument) -> NSAttributedString {
            let result = NSMutableAttributedString(string: "")
            for (index, block) in document.blocks.enumerated() {
                if index > 0 { result.append(NSAttributedString(string: "\n\n")) }
                append(block, document: document, to: result)
            }
            return result
        }

        private static func append(
            _ block: MarkdownBlock,
            document: MarkdownDocument,
            to result: NSMutableAttributedString
        ) {
            switch block {
            case let .paragraph(_, _, inlines): append(inlines, to: result, attributes: baseAttributes)
            case let .heading(_, _, level, inlines):
                let size = max(CGFloat(15), CGFloat(26) - CGFloat(level) * 2)
                append(inlines, to: result, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: size),
                    .foregroundColor: NSColor.labelColor
                ])
            case let .list(_, _, items), let .taskList(_, _, items):
                for (index, item) in items.enumerated() {
                    if index > 0 { result.append(NSAttributedString(string: "\n")) }
                    let marker = item.taskState == .checked ? "☑ " : item.taskState == .unchecked ? "☐ " : "• "
                    result.append(NSAttributedString(string: String(repeating: "  ", count: item.depth) + marker, attributes: baseAttributes))
                    append(item.inlines, to: result, attributes: baseAttributes)
                }
            case let .quote(_, _, inlines):
                result.append(NSAttributedString(string: "▏ ", attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]))
                append(inlines, to: result, attributes: baseAttributes)
            case let .code(_, _, language, body):
                let value = language.isEmpty ? body : "\(language)\n\(body)"
                result.append(NSAttributedString(string: value, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.55)
                ]))
            case let .table(_, _, headers, rows):
                appendTableRow(headers, to: result)
                for row in rows {
                    result.append(NSAttributedString(string: "\n"))
                    appendTableRow(row.cells, to: result)
                }
            case let .footnote(_, _, label, inlines):
                result.append(NSAttributedString(string: "[^\(label)]: ", attributes: baseAttributes))
                append(inlines, to: result, attributes: baseAttributes)
            case .source:
                result.append(NSAttributedString(
                    string: document.sourceText(for: block),
                    attributes: baseAttributes
                ))
            }
        }

        private static func appendTableRow(_ cells: [[MarkdownInline]], to result: NSMutableAttributedString) {
            for (index, cell) in cells.enumerated() {
                if index > 0 { result.append(NSAttributedString(string: " | ", attributes: baseAttributes)) }
                append(cell, to: result, attributes: baseAttributes)
            }
        }

        private static func append(
            _ inlines: [MarkdownInline],
            to result: NSMutableAttributedString,
            attributes: [NSAttributedString.Key: Any]
        ) {
            for inline in inlines {
                switch inline.kind {
                case let .text(value): result.append(NSAttributedString(string: value, attributes: attributes))
                case let .inlineCode(value):
                    result.append(NSAttributedString(string: value, attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                        .foregroundColor: NSColor.labelColor,
                        .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.55)
                    ]))
                case let .emphasis(children):
                    append(children, to: result, attributes: attributes.merging([
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular).withItalic
                    ]) { _, newer in newer })
                case let .strong(children):
                    append(children, to: result, attributes: attributes.merging([
                        .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
                    ]) { _, newer in newer })
                case let .strikethrough(children):
                    append(children, to: result, attributes: attributes.merging([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue
                    ]) { _, newer in newer })
                case let .link(destination, _, children):
                    append(children, to: result, attributes: attributes.merging([
                        .link: destination,
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]) { _, newer in newer })
                }
            }
        }
    }
}
/// Reports first-responder changes without changing text or layout.
@MainActor
private final class ComposerTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            onFocusChange?(true)
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
        }
        return resigned
    }
}

private extension NSFont {
    var withItalic: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}
