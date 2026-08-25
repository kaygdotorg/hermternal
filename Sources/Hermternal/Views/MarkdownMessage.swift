import Foundation

/// Shared transcript measurements used by the AppKit block renderer.
///
/// This type remains in the existing file so the renderer keeps one source of
/// truth for its reading measure, list geometry, and text rhythm.
enum MessageTypography {
    static let bodyLineSpacing: CGFloat = 3
    static let listIndent: CGFloat = 24
    static let markerColumn: CGFloat = 24
    static let markerGap: CGFloat = 4
    static let maxListDepth = 4

    static let readingMeasure: CGFloat = 556
    static let assistantTrailingInset: CGFloat = 24
    static let bubblePadding: CGFloat = 14
    static let userBubbleMeasure: CGFloat = readingMeasure + bubblePadding * 2

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
