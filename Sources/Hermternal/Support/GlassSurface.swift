import SwiftUI

/// Backs a surface with liquid glass at a caller-chosen intensity.
///
/// `glassEffect` has no intensity knob, so the glass is laid down first and
/// then veiled with the window background at `1 - intensity`. At 0 the
/// surface is indistinguishable from a plain background; at 1 it is pure
/// glass. Doing it in this order keeps the glass's specular highlights while
/// still letting text sit on something opaque enough to read.
///
/// The backing is deliberately clipped to the modified view's own bounds. An
/// earlier version called `ignoresSafeArea()`, which let the detail column's
/// veil span the whole window and sit behind the sidebar — so the sidebar's
/// glass revealed the chat's opacity instead of the desktop, and the two
/// sliders appeared coupled.
private struct GlassSurface: ViewModifier {
    let intensity: Double

    func body(content: Content) -> some View {
        let clamped = min(max(intensity, 0), 1)
        return content.background {
            ZStack {
                Rectangle()
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect)
                Rectangle()
                    .fill(.background.opacity(1 - clamped))
            }
            .clipped()
        }
    }
}

extension View {
    /// Apply liquid glass behind this view at `intensity` (0…1), confined to
    /// this view's own bounds.
    func glassSurface(intensity: Double) -> some View {
        modifier(GlassSurface(intensity: intensity))
    }
}
