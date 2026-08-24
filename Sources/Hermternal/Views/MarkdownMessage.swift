import SwiftUI
import HermternalCore

/// A segment's span in the original message text, as returned by
/// `MarkdownSegment.sourceSpans(for:)`. Only the find path needs it.
typealias MarkdownSourceSpan = (source: Range<Int>, language: Range<Int>?)

/// Type scale and vertical rhythm for transcript prose.
///
/// A reply is not a document, so the heading scale is compressed rather than
/// borrowed wholesale from a text-editing app: 17/15/13 semibold over a 13pt
/// body. Anything larger shouts across a chat column, and anything smaller
/// than the body would invert the hierarchy it is meant to establish.
enum MessageTypography {
    /// macOS `body` is 13pt on a ~16pt line. Long-form reading wants roughly
    /// 1.4–1.5× the point size, so +3pt lands at ~19pt (1.46×). This is also
    /// what pays for the column being wider than a book measure: leading and
    /// measure trade off against each other, and both move together here.
    static let bodyLineSpacing: CGFloat = 3

    /// Marker column and per-level list indent are deliberately the same
    /// value, so a nested item's marker starts exactly where its parent's
    /// text starts. The indent is then structural rather than arbitrary.
    ///
    /// 24pt is the smallest 4pt step that still holds a two-digit ordinal:
    /// `10.` runs ~19pt at 13pt monospaced digits, plus the 4pt gap. Below
    /// that, every list past nine items would hang into the gutter.
    static let listIndent: CGFloat = 24
    static let markerColumn: CGFloat = 24

    /// Gap between a right-aligned ordinal and its text.
    static let markerGap: CGFloat = 4

    /// Past this, further nesting stops indenting; a pathological list can
    /// not push its own text off the row.
    static let maxListDepth = 4

    /// The reading measure for assistant prose: the 680pt column, less 44pt
    /// of gutters, less the mark's 20pt column and its 10pt gap, less 96pt
    /// of trailing air. About 80 characters at 13pt, which the 1.46 line
    /// height carries comfortably; wider than this and the eye starts
    /// losing the line return. Applied as a cap rather than a fixed inset,
    /// so a narrow window hands the space back to the text instead of
    /// holding an empty gutter open.
    static let readingMeasure: CGFloat = 510

    /// Minimum trailing air on an assistant row, so its ragged right edge
    /// never lands on the same boundary as a right-aligned user bubble.
    static let assistantTrailingInset: CGFloat = 24

    /// The user bubble's own side padding.
    static let bubblePadding: CGFloat = 14

    /// Bubble width that gives a user message the same measure as a reply.
    /// Applied to a transparent trailing-aligned container rather than to
    /// the bubble, because a greedy `maxWidth` on the bubble itself would
    /// stop it hugging its text and stretch every one-line message.
    static let userBubbleMeasure: CGFloat = readingMeasure + bubblePadding * 2

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.semibold)
        case 2: .title3.weight(.semibold)
        default: .headline
        }
    }

    /// SF tightens optical tracking as size grows; matching it keeps the
    /// larger headings from reading loose next to the body.
    static func headingTracking(_ level: Int) -> CGFloat {
        switch level {
        case 1: -0.2
        case 2: -0.1
        default: 0
        }
    }

    /// The conventional nested progression — filled disc, open circle,
    /// filled square — so depth reads even where the indent is clipped.
    static func bulletGlyph(_ depth: Int) -> String {
        switch depth {
        case 0: "\u{2022}"
        case 1: "\u{25E6}"
        default: "\u{25AA}"
        }
    }

    /// Space above a heading is 2.5× the space below it, so a heading binds
    /// to the content it introduces instead of floating between two blocks.
    /// Items of one list sit at 4pt so the list reads as a single object,
    /// while a bullet list meeting a numbered list opens back up to 8pt so
    /// two adjacent lists do not fuse into one. Every value is on the 4pt
    /// grid.
    static func spacing(from previous: BlockKind, to current: BlockKind) -> CGFloat {
        if current == .heading {
            return previous == .heading ? 12 : 20
        }
        if previous == .heading {
            return 8
        }
        if previous.isListItem {
            guard current.isListItem else { return 12 }
            return previous == current ? 4 : 8
        }
        return current.isListItem ? 8 : 12
    }

    /// Vertical rhythm depends only on what kind of block sits on each side
    /// of a gap, not on the segment's contents.
    enum BlockKind {
        case heading
        case paragraph
        case bullet
        case numbered
        case code

        init(_ segment: MarkdownSegment) {
            switch segment {
            case .heading: self = .heading
            case .prose: self = .paragraph
            case .bullet: self = .bullet
            case .numbered: self = .numbered
            case .code: self = .code
            }
        }

        var isListItem: Bool {
            self == .bullet || self == .numbered
        }
    }
}

/// Find matches to draw over a message, in UTF-16 offsets into `text`.
struct MessageFindMatches {
    let text: String
    let ranges: [Range<Int>]
}

struct MarkdownMessage: View {
    let text: String
    /// While deltas land, skip segmentation entirely — it would re-segment
    /// the whole message on every token.
    let isStreaming: Bool

    var body: some View {
        if isStreaming {
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(MessageTypography.bodyLineSpacing)
                .textSelection(.enabled)
        } else {
            MarkdownBlocks(text: text)
        }
    }
}

/// Draws a message's block structure, with or without find marks.
///
/// Both transcript paths render through this one view, so a highlighted
/// message and a plain one cannot drift apart in type or spacing.
struct MarkdownBlocks: View {
    let text: String
    /// `nil` on the plain path, which skips all per-run attribute work.
    var matches: MessageFindMatches?

    var body: some View {
        // `parse` and `sourceSpans` are both cached in Core and keyed by the
        // message text, so this is a lookup rather than a parse, and the
        // segment ids are stable across invalidations for `ForEach` reuse.
        let segments = MarkdownSegment.parse(text)
        let spans = matches == nil ? [] : MarkdownSegment.sourceSpans(for: text)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                block(segment, span: span(at: index, in: spans))
                    .padding(.top, index == 0 ? 0 : MessageTypography.spacing(
                        from: .init(segments[index - 1]),
                        to: .init(segment)
                    ))
            }
        }
        // Long-form reading text is label-primary. Set once here so no
        // ancestor style can wash the transcript out; find marks carry their
        // own per-run color and still win over this.
        .foregroundStyle(.primary)
    }

    /// Absent whenever Find is closed, and tolerant of a span list that does
    /// not line up with the segments rather than mismatching highlights.
    private func span(at index: Int, in spans: [MarkdownSourceSpan]) -> MarkdownSourceSpan? {
        guard spans.indices.contains(index) else { return nil }
        return spans[index]
    }

    @ViewBuilder
    private func block(_ segment: MarkdownSegment, span: MarkdownSourceSpan?) -> some View {
        switch segment {
        case .heading(_, let level, let content):
            Text(marked(content, span: span))
                .font(MessageTypography.headingFont(level))
                .tracking(MessageTypography.headingTracking(level))
                // No added leading: a heading is tighter than the body it
                // introduces, and an ancestor's line spacing cannot leak in.
                .lineSpacing(0)
                .textSelection(.enabled)

        case .prose(_, let content):
            bodyText(content, span: span)

        case .bullet(_, _, let depth, let content):
            listRow(depth: depth) {
                Text(MessageTypography.bulletGlyph(depth))
                    .font(.body)
                    // A marker is structure, not prose, so it recedes; the
                    // item's own text stays at primary.
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(width: MessageTypography.markerColumn, alignment: .leading)
            } content: {
                bodyText(content, span: span)
            }

        case .numbered(_, let marker, let number, let depth, let content):
            listRow(depth: depth) {
                Text(Self.ordinal(number, marker: marker))
                    .font(.body)
                    // Ordinals right-align on a stable digit width, so the
                    // delimiters line up down the list.
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.trailing, MessageTypography.markerGap)
                    .frame(width: MessageTypography.markerColumn, alignment: .trailing)
            } content: {
                bodyText(content, span: span)
            }

        case .code(_, let language, let body):
            TranscriptCodeBlock(
                language: language,
                code: body,
                languageRanges: projected(
                    span?.language,
                    onto: TranscriptCodeBlock.label(for: language)
                ),
                codeRanges: projected(span?.source, onto: body)
            )
        }
    }

    private func bodyText(_ content: AttributedString, span: MarkdownSourceSpan?) -> some View {
        Text(marked(content, span: span))
            .font(.body)
            .lineSpacing(MessageTypography.bodyLineSpacing)
            .textSelection(.enabled)
    }

    /// Hanging indent: the marker sits in its own fixed column on the first
    /// text baseline, so wrapped lines align under the item's text rather
    /// than under its marker.
    private func listRow(
        depth: Int,
        @ViewBuilder marker: () -> some View,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            marker()
            content()
        }
        .padding(
            .leading,
            CGFloat(min(depth, MessageTypography.maxListDepth)) * MessageTypography.listIndent
        )
    }

    /// Keeps the author's delimiter, so `3)` stays `3)` and `3.` stays `3.`.
    private static func ordinal(_ number: Int, marker: String) -> String {
        let delimiter = marker.last.map { $0 == ")" ? ")" : "." } ?? "."
        return "\(number)\(delimiter)"
    }

    private func marked(_ content: AttributedString, span: MarkdownSourceSpan?) -> AttributedString {
        let ranges = projected(span?.source, onto: String(content.characters))
        guard !ranges.isEmpty else { return content }
        return FindTextHighlighting.mark(content, ranges: ranges)
    }

    /// Narrows the message's matches to the ones that start inside this
    /// segment, then maps them onto the string actually drawn.
    private func projected(_ span: Range<Int>?, onto rendered: String) -> [Range<Int>] {
        guard let matches, let span else { return [] }
        let inSpan = matches.ranges.filter { span.contains($0.lowerBound) }
        guard !inSpan.isEmpty else { return [] }
        return FindTextHighlighting.project(inSpan, from: matches.text, to: rendered)
    }
}

/// The transcript's fenced-code treatment. Find marks are passed in as
/// ranges so the highlighted and plain code blocks are literally the same
/// chrome, header, and copy affordance.
struct TranscriptCodeBlock: View {
    let language: String
    let code: String
    var languageRanges: [Range<Int>] = []
    var codeRanges: [Range<Int>] = []
    @State private var didCopy = false

    static func label(for language: String) -> String {
        language.isEmpty ? "code" : language
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(FindTextHighlighting.mark(
                    AttributedString(Self.label(for: language)),
                    ranges: languageRanges
                ))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy()
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider().opacity(0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(FindTextHighlighting.mark(AttributedString(code), ranges: codeRanges))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(
            .background.secondary,
            in: .rect(cornerRadius: AppShapeScale.compact, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppShapeScale.compact, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            didCopy = false
        }
    }
}
