import AppKit
import SwiftUI

/// Neutralises the AppKit material AppKit puts behind a SwiftUI surface.
///
/// `NavigationSplitView` backs its sidebar column with an `NSVisualEffectView`
/// sidebar material, and a `List` sits on an `NSScrollView` that draws its own
/// background. Neither is reachable from SwiftUI:
/// `scrollContentBackground(.hidden)` only clears the scroll *content*, so the
/// column's material still paints over our glass.
///
/// This walks up the AppKit hierarchy and stops those two from drawing. The
/// visual effect view is made transparent via `alphaValue` rather than
/// `isHidden`, because hiding it removes it from layout and the split view
/// relies on it for column metrics.
private struct ClearBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-apply after SwiftUI rebuilds, which can restore the material.
        (nsView as? Probe)?.clearAncestors()
    }

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            clearAncestors()
        }

        func clearAncestors() {
            // Defer one turn: on first layout the enclosing views may not be
            // installed yet.
            DispatchQueue.main.async { [weak self] in
                var ancestor = self?.superview
                while let current = ancestor {
                    if let effect = current as? NSVisualEffectView {
                        effect.alphaValue = 0
                    }
                    if let scroll = current as? NSScrollView {
                        scroll.drawsBackground = false
                        scroll.backgroundColor = .clear
                    }
                    ancestor = current.superview
                }
            }
        }
    }
}

extension View {
    /// Stop the enclosing AppKit material and scroll background from painting,
    /// so a `glassSurface` behind this view is actually visible.
    func clearAppKitBackground() -> some View {
        background(ClearBackground().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
