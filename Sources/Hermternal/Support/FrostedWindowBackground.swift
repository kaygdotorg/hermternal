import SwiftUI

/// System frosted materials shared by the main and Settings windows.
///
/// `includesBaseBlur` is the whole difference between the two surfaces. The
/// Settings window has nothing behind it, so without a thin material of its
/// own the desktop shows through sharp. The main window already sits on Liquid
/// Glass, which *is* the blur; a material there would paint over the glass and
/// stop it refracting, which is the one thing that window must never do.
struct FrostedWindowBackground: View {
    let materialOpacity: Double
    let includesBaseBlur: Bool

    var body: some View {
        ZStack {
            if includesBaseBlur {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
            Rectangle()
                .fill(.regularMaterial)
                .opacity(materialOpacity)
            // A minimal light tint keeps the fully frosted state from reading
            // as a dark scrim, without changing the transparent end.
            Rectangle()
                .fill(.white.opacity(materialOpacity * 0.08))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
