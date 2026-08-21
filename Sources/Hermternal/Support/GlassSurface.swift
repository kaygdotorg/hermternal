import SwiftUI

/// Backs a surface with liquid glass at a caller-chosen intensity.
///
/// `glassEffect` has no intensity knob, so the glass is laid down first and
/// then veiled with the window background at `1 - intensity`. At 0 the
/// surface is indistinguishable from a plain background; at 1 it is pure
/// glass. Doing it in this order keeps the glass's specular highlights while
/// still letting text sit on something opaque enough to read.
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
            .ignoresSafeArea()
        }
    }
}

extension View {
    /// Apply liquid glass behind this view at `intensity` (0…1).
    func glassSurface(intensity: Double) -> some View {
        modifier(GlassSurface(intensity: intensity))
    }
}
