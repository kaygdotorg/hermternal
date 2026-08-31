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

    static let readingMeasure: CGFloat = 680
    static let transcriptInset: CGFloat = 20
    static let hermesIndent: CGFloat = 20
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

    /// The outgoing bubble's text measure: half the document measure.
    ///
    /// The step down is unmistakable at any window width. 340pt still holds
    /// about 52 characters of 13pt body text, which is the right measure for a
    /// prompt rather than for a document.
    static let outgoingTextMeasure: CGFloat = readingMeasure / 2

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
