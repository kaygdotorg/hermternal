import Foundation

/// The measure the transcript lays a message out in.
///
/// Two states, not a dial. A reading measure has one right answer for a body
/// font, and a continuous width would invite every wrong one. Full width is
/// the reader's answer to a window held wide for tables, code, and side-by-side
/// work, where wrapping costs more than a long line does.
enum TranscriptWidthMode: String, CaseIterable, Sendable {
    /// The centred reading column: `MessageTypography.readingMeasure`.
    case standard
    /// The window, its two gutters excluded.
    case full

    var other: TranscriptWidthMode {
        switch self {
        case .standard: .full
        case .full: .standard
        }
    }
}

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
    /// never the text. `TranscriptWidthMode.full` is the reader's own answer to
    /// a window held wide for tables and code, and it is the one state that
    /// gives this cap up.
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

    /// The measure every reader of the column lays out in.
    ///
    /// `AppearanceSettings` owns the reader's choice, persists it, and writes
    /// it here before it posts `TranscriptWidthStore.didChangeNotification`.
    /// One value for the process: the measurement pass and the constraint chain
    /// must read the same answer, and a row measured in one measure and laid
    /// out in the other disagrees by every line it wraps.
    ///
    /// Main-actor, which every reader already is: the row views, the height
    /// delegate, and the pass that resolves a width before it hands the number
    /// to a detached measurer.
    @MainActor static var widthMode: TranscriptWidthMode = .standard

    /// The content column inside `availableWidth`.
    ///
    /// The column is the band both speakers share: centred, one gutter on each
    /// side. The standard measure caps it at `readingMeasure`, so a wide window
    /// widens the gutters; the full measure gives it the window less its two
    /// gutters. An agent answer fills the column after its own gutter. An
    /// outgoing bubble fills it and trails its trailing edge.
    ///
    /// This is the only place the measure is decided. The row's column guide
    /// and the measurement pass both read it, so the width toggle is one
    /// constant switch instead of a second layout path.
    ///
    /// Defended by outgoingRowTrailsGutterAndKeepsRowBands and
    /// theFullMeasureGivesBothSpeakersTheWindow.
    @MainActor
    static func contentColumn(in availableWidth: CGFloat) -> CGFloat {
        let insideGutters = availableWidth - 2 * transcriptInset
        return switch widthMode {
        case .standard: max(1, min(readingMeasure, insideGutters))
        case .full: max(1, insideGutters)
        }
    }

    /// The outgoing text measure inside a content column.
    ///
    /// The bubble's box is the column, not a share of it: the tail tip lands on
    /// the column's trailing edge, and both paddings and the tail come off the
    /// column before the text gets any. What is left is within a point of the
    /// agent's own measure, `column - hermesIndent`, and that is the point —
    /// one message measure for both speakers, at every window width and in both
    /// width modes. The tail on the trailing edge states the speaker; an empty
    /// leading third used to, and it cost the user's own words a third of the
    /// column the answer below them was allowed.
    ///
    /// Defended by bothSpeakersShareOneTextMeasure.
    static func outgoingTextMeasure(in column: CGFloat) -> CGFloat {
        max(1, column
            - 2 * outgoingBubblePaddingH
            - OutgoingBubbleGeometry.tailWidth)
    }

    /// The widest outgoing text the standard measure holds.
    ///
    /// A row that has no measurement yet and no cap from its caller lays out at
    /// this width, and its column cap trims it on a narrower window. It is not
    /// the widest text the transcript can show: the full measure has no constant
    /// answer, because the window decides it.
    static let widestStandardOutgoingText: CGFloat =
        outgoingTextMeasure(in: readingMeasure)

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
