import CoreGraphics

/// Geometry shared by the command-K search panel and the toast surface.
enum SearchSurfaceGeometry {
    static let maximumWidth: CGFloat = 680
    static let horizontalInset: CGFloat = 24
    static let minimumWidth: CGFloat = 280
    static let verticalFraction: CGFloat = 1 / 3

    static func width(in containerWidth: CGFloat) -> CGFloat {
        min(maximumWidth, max(minimumWidth, containerWidth - horizontalInset * 2))
    }

    static func topInset(in containerHeight: CGFloat) -> CGFloat {
        containerHeight * verticalFraction
    }

    static func maximumHeight(in containerHeight: CGFloat) -> CGFloat {
        containerHeight * verticalFraction
    }
}
