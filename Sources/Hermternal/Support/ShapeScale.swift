import SwiftUI

/// Shape tokens for surfaces owned by Hermternal rather than macOS.
///
/// App-owned shapes nested inside another app-owned shape must use a strictly
/// smaller radius token than their parent so the curves remain concentric.
/// System-drawn controls, lists, selections, and grouped forms are excluded.
enum AppShapeScale {
    /// The outer window-level curve, when the app owns that boundary.
    static let window: CGFloat = 24

    /// The established search-panel/card radius.
    static let card: CGFloat = 18

    /// The established toast-card radius.
    static let toast: CGFloat = 14

    /// Compact app-owned rows and nested selections.
    static let row: CGFloat = 12

    /// Dense content blocks, such as a code block inside a transcript.
    static let compact: CGFloat = 8

    /// Capsule geometry for app-owned controls and identity pills.
    static let control = Capsule()
}
