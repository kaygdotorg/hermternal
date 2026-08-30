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
    static let roleLabelHeight: CGFloat = 18
    static let disclosureHeight: CGFloat = 24
    static let metadataFooterHeight: CGFloat = 22
    static let metadataGap: CGFloat = 8
    static let loadingRowHeight: CGFloat = 64
    static let minimumTurnHeight: CGFloat = 92
    static let codePadding: CGFloat = 14

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
