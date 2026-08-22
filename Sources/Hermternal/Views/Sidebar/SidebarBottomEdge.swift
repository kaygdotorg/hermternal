import SwiftUI

/// Keeps the sidebar's scrolling rows readable beneath the fixed account row.
/// Like the transcript edge, this is one masked material with a continuous
/// gradient rather than several stacked opacity bands.
struct SidebarBottomEdge<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.12), location: 0.24),
                            .init(color: .black.opacity(0.35), location: 0.50),
                            .init(color: .black.opacity(0.75), location: 0.76),
                            .init(color: .black, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(height: 130)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)

            content()
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
    }
}
