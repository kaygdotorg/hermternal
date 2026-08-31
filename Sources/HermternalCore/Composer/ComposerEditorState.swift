import Foundation

/// The two editing representations exposed by the macOS composer.
public enum ComposerEditorMode: String, Equatable, Hashable, Sendable {
    case wysiwyg
    case source
}

/// A bounded source transition result for the composer editor.
///
/// The source remains unchanged when a transition to WYSIWYG fails. This
/// keeps invalid Markdown visible in Source mode and preserves exact input.
public struct ComposerEditorState: Equatable, Sendable {
    public private(set) var source: String
    public private(set) var mode: ComposerEditorMode
    public private(set) var error: MarkdownParseError?

    public init(source: String = "", mode: ComposerEditorMode = .wysiwyg) {
        self.source = source
        self.mode = mode
        self.error = mode == .source ? MarkdownDocument.parse(source).error : nil
    }

    /// Replaces the exact Markdown source without normalizing it.
    public mutating func updateSource(_ source: String) {
        self.source = source
        error = mode == .source ? MarkdownDocument.parse(source).error : nil
    }

    /// Changes representation. Invalid source stays in Source mode.
    @discardableResult
    public mutating func setMode(_ requested: ComposerEditorMode) -> Bool {
        guard requested != mode else { return error == nil }
        if requested == .wysiwyg {
            let parsed = MarkdownDocument.parse(source)
            guard parsed.error == nil else {
                error = parsed.error
                return false
            }
        }
        mode = requested
        error = requested == .source ? MarkdownDocument.parse(source).error : nil
        return error == nil
    }

    public var isValid: Bool { error == nil }
}

/// Formatting commands understood by the native composer editor.
public enum ComposerEditorFormat: String, CaseIterable, Hashable, Sendable {
    case heading
    case emphasis
    case link
    case unorderedList
    case quote
    case inlineCode
    case fencedCode
    case strong
}

/// A source edit and the selection that should remain active after it.
public struct ComposerEditorEdit: Equatable, Sendable {
    public let source: String
    public let selectedRange: Range<Int>

    public init(source: String, selectedRange: Range<Int>) {
        self.source = source
        self.selectedRange = selectedRange
    }
}

/// Formatting commands understood by the native composer editor.
public enum ComposerEditorFormatter {
    public static func apply(
        _ format: ComposerEditorFormat,
        source: String,
        selectedRange: Range<Int>
    ) -> ComposerEditorEdit {
        let units = Array(source.utf16)
        let lower = min(max(0, selectedRange.lowerBound), units.count)
        let upper = min(max(lower, selectedRange.upperBound), units.count)
        let selected = String(decoding: units[lower..<upper], as: UTF16.self)
        var replacementLower = lower
        var replacementUpper = upper
        let replacement: String
        let selectionOffset: Int
        switch format {
        case .heading:
            let lineStart = units[..<lower].lastIndex(of: 10).map { $0 + 1 } ?? 0
            replacementLower = lineStart
            replacementUpper = lineStart
            replacement = "# "
            selectionOffset = 2
        case .emphasis:
            replacement = "*\(selected)*"
            selectionOffset = 1
        case .strong:
            replacement = "**\(selected)**"
            selectionOffset = 2
        case .link:
            replacement = "[\(selected)](https://)"
            selectionOffset = 1
        case .unorderedList:
            replacement = "- \(selected)"
            selectionOffset = 2
        case .quote:
            replacement = "> \(selected)"
            selectionOffset = 2
        case .inlineCode:
            replacement = "`\(selected)`"
            selectionOffset = 1
        case .fencedCode:
            replacement = "```\n\(selected)\n```"
            selectionOffset = 4
        }
        var result = units
        result.replaceSubrange(replacementLower..<replacementUpper, with: replacement.utf16)
        let newLower = max(0, lower + selectionOffset)
        let newUpper = newLower + selected.utf16.count
        return ComposerEditorEdit(
            source: String(decoding: result, as: UTF16.self),
            selectedRange: newLower..<newUpper
        )
    }
}

/// Height limits for the native editor.
///
/// The adapter measures content and returns this policy's bounded result to
/// SwiftUI from `sizeThatFits`, so one layout pass settles the height and
/// nothing is written back into view state. The frame never participates in
/// the measurement.
public enum ComposerEditorHeightPolicy {
    public static let minimum: Double = 38
    public static let maximum: Double = 168
    public static let verticalInset: Double = 14
    public static let measurementEpsilon: Double = 0.5

    /// Converts a layout measurement into one stable height band.
    public static func height(for measuredContentHeight: Double) -> Double {
        let measured = max(0, measuredContentHeight) + verticalInset
        let bounded = min(maximum, max(minimum, measured))
        return bounded.rounded()
    }

    /// Returns a new height only when it enters a different height band.
    public static func nextHeight(
        measuredContentHeight: Double,
        currentHeight: Double?
    ) -> Double? {
        let candidate = height(for: measuredContentHeight)
        guard let currentHeight else { return candidate }
        return abs(candidate - currentHeight) > measurementEpsilon ? candidate : nil
    }

    /// True when a proposed width names the column the editor will occupy.
    ///
    /// SwiftUI probes a leaf view with a zero width and an infinite width to
    /// learn how flexible it is, and it proposes an unspecified width to ask
    /// for an ideal size. None of those is a column the editor ever has, and
    /// measuring wrapped text against one is not a smaller answer but a
    /// different one: at zero width the text breaks after every glyph and
    /// reaches `maximum`, and at an infinite width it reports a single line.
    /// Only a real column may become the editor's height, so a probe is
    /// answered from the last real measurement instead.
    ///
    /// Empty text measures the same at every width, which is why only a
    /// non-empty draft could see the two answers disagree.
    public static func isLayoutWidth(_ proposedWidth: Double) -> Bool {
        proposedWidth.isFinite && proposedWidth > 1
    }
}

/// Focus behaviour for the editor's formatting controls.
public enum ComposerEditorInteractionPolicy {
    public static let formattingRowTransitionDuration: Double = 0.12

    /// Duration of the formatting-row reveal.
    ///
    /// Reduced motion drops the travel and keeps the same path, matching
    /// `TranscriptMotion.duration(reducesMotion:)`.
    public static func formattingRowAnimationDuration(reducesMotion: Bool) -> Double {
        reducesMotion ? 0 : formattingRowTransitionDuration
    }

    public static func formattingRowIsVisible(
        isEditorFocused: Bool,
        isExpanded: Bool,
        hasSource: Bool
    ) -> Bool {
        isEditorFocused && isExpanded && hasSource
    }

    public static func shouldRevealFormattingRow(
        isEditorFocused: Bool,
        hasSource: Bool,
        explicitFormatAction: Bool
    ) -> Bool {
        explicitFormatAction && isEditorFocused && hasSource
    }

    public static func formattingActionPreservesFocus(_ isEditorFocused: Bool) -> Bool {
        isEditorFocused
    }

    public static func shouldHideFormattingRow(
        isEditorFocused: Bool,
        hasSource: Bool
    ) -> Bool {
        !isEditorFocused || !hasSource
    }

    public static func shouldPublishFocusChange(
        from previous: Bool,
        to current: Bool
    ) -> Bool {
        previous != current
    }
}
