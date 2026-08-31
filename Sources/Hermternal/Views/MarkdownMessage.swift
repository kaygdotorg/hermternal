import Foundation

/// Shared transcript measurements for the macOS document renderer.
///
/// These values describe the readable measure and the vertical rhythm.
/// System controls own their shape and inset.
enum MessageTypography {
    static let bodyLineSpacing: CGFloat = 2
    static let bodyLineHeight: CGFloat = 18
    static let paragraphGap: CGFloat = 10
    static let listIndent: CGFloat = 24
    static let markerColumn: CGFloat = 24
    static let markerGap: CGFloat = 4
    static let maxListDepth = 6

    /// The readable measure: the widest a message may be, gutters excluded.
    ///
    /// 490pt is 0.72 of the 680pt band this transcript filled before. 680pt
    /// holds about 100 characters of 13pt body text, which is a page measure,
    /// not a message measure: the eye loses the line on the way back to the
    /// start of the next one. 490pt holds about 70 characters, inside the band
    /// a reader scans without effort, so a wide window widens the gutters and
    /// never the text.
    ///
    /// Defended by rendererRowsKeepDocumentWidthThroughTableLayoutAndResize.
    static let readingMeasure: CGFloat = 490
    static let transcriptInset: CGFloat = 20

    /// The agent mark's side, in points.
    ///
    /// The mark is the app icon beside the answer, and it identifies the
    /// speaker in the same way an avatar does in Messages. 28pt is the size
    /// Messages gives that avatar, and it is the size that balances a 490pt
    /// measure: a 14pt mark read as a stray glyph beside the text.
    ///
    /// Defended by markStandsBesideTheFirstLineOfAWrappedAnswer.
    static let markSide: CGFloat = 28

    /// The space between the mark and the text of the turn.
    static let markGap: CGFloat = 8

    /// The agent's gutter: the mark, and the gap to the text it marks.
    ///
    /// Derived, never stated twice. The mark stands in this gutter, so a change
    /// of the mark's size moves the text of every agent turn with it.
    static let hermesIndent: CGFloat = markSide + markGap
    static let internalBlockGap: CGFloat = 8
    static let turnGap: CGFloat = 24
    /// The height of a system row's role label band.
    ///
    /// Only a system row shows a role label. An agent row states its speaker
    /// with the mark in the gutter, beside the first line of the turn, and the
    /// mark takes no band of its own.
    static let roleLabelHeight: CGFloat = 18
    static let disclosureHeight: CGFloat = 24
    static let metadataFooterHeight: CGFloat = 22
    static let metadataGap: CGFloat = 8
    static let loadingRowHeight: CGFloat = 64
    static let minimumTurnHeight: CGFloat = 92
    static let codePadding: CGFloat = 14

    /// The share of the content column an outgoing bubble may fill.
    ///
    /// 0.7, the share Messages.app leaves a bubble. The empty 30% on the
    /// leading side is what states the speaker: a bubble that fills the column
    /// reads as a document, and its trailing edge is then the only clue left
    /// that the user wrote it. The share is taken from the column and not from
    /// the window, so the proportion holds at every window width.
    ///
    /// Defended by longOutgoingMessageWrapsInsideTextCap and
    /// narrowWindowKeepsRequiredTranscriptInsets.
    static let outgoingBubbleShare: CGFloat = 0.7

    /// The content column inside `availableWidth`.
    ///
    /// The column is the band both speakers share: centred, one gutter on each
    /// side, and never wider than the readable measure. An agent answer fills
    /// it after its own gutter. An outgoing bubble takes its share of it and
    /// trails its trailing edge.
    ///
    /// Defended by outgoingRowTrailsGutterAndKeepsRowBands.
    static func contentColumn(in availableWidth: CGFloat) -> CGFloat {
        max(1, min(readingMeasure, availableWidth - 2 * transcriptInset))
    }

    /// The outgoing text measure inside a content column.
    ///
    /// The bubble's own box is its share of the column. The tail and both
    /// paddings come off that box before the text gets any, so the box, and
    /// not the text, is what holds the share.
    static func outgoingTextMeasure(in column: CGFloat) -> CGFloat {
        max(1, column * outgoingBubbleShare
            - 2 * outgoingBubblePaddingH
            - OutgoingBubbleGeometry.tailWidth)
    }

    /// The widest outgoing text the transcript can show: the measure inside a
    /// full content column.
    static let widestOutgoingText: CGFloat = outgoingTextMeasure(in: readingMeasure)

    /// The space between the bubble's side and its text.
    ///
    /// The code block is the other app-owned filled block in this transcript,
    /// and two filled blocks in one transcript pad alike. The value also equals
    /// the body radius, so no glyph enters the corner curve.
    static let outgoingBubblePaddingH: CGFloat = codePadding

    /// The space between the bubble's top or bottom and its text.
    ///
    /// The space above the first line equals the space the renderer puts
    /// between paragraphs, so the rhythm inside the bubble matches the rhythm
    /// outside it.
    static let outgoingBubblePaddingV: CGFloat = paragraphGap

    /// The smallest honest outgoing row: one line of body text in its padding,
    /// inside the turn rhythm.
    ///
    /// `minimumTurnHeight` cannot serve here. It reserves a role band, a
    /// disclosure band, and a metadata band that an outgoing turn never shows.
    static let outgoingMinimumTurnHeight: CGFloat =
        2 * outgoingBubblePaddingV + bodyLineHeight + turnGap

    /// Tolerance between the CoreText measurement and the text view's layout.
    ///
    /// The two round a final line's ascent differently by less than a point.
    /// One point cannot clip a descender and is invisible in the bubble.
    static let outgoingMeasurementSlack: CGFloat = 1

    /// The reserve between the agent measurement and the rendered answer.
    ///
    /// The agent measurement runs off the main thread. It measures the raw
    /// Markdown source in Helvetica 13, with no line spacing and no paragraph
    /// spacing. The row then renders the parsed document in the body font, with
    /// `bodyLineSpacing` on every line and `paragraphGap` after every
    /// paragraph. The rendered text is therefore taller than the measurement.
    /// This reserve holds that difference.
    ///
    /// The reserve is not exact. The difference grows with the number of lines
    /// and paragraphs, and an exact figure needs the rendered text, which the
    /// measurement pass does not build. The value is the reserve the transcript
    /// has always held: it was named after the agent role band, which the mark
    /// in the gutter replaced.
    static let agentMeasurementReserve: CGFloat = 18

    static func headingTracking(_ level: Int) -> CGFloat {
        switch level {
        case 1: -0.2
        case 2: -0.1
        default: 0
        }
    }

    static func bulletGlyph(_ depth: Int) -> String {
        switch depth {
        case 0: "\u{2022}"
        case 1: "\u{25E6}"
        default: "\u{25AA}"
        }
    }
}
