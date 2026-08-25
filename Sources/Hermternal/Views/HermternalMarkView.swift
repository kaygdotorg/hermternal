import AppKit
import HermternalCore
import SwiftUI

/// The product mark used wherever Hermternal identifies itself.
///
/// The light and dark drawings are decoded once from the app bundle. The
/// current color scheme is read at render time so an Appearance change swaps
/// the drawing without rebuilding the caller.
@MainActor
enum HermternalMark {
    static func image(for colorScheme: ColorScheme) -> NSImage? {
        colorScheme == .dark ? dark : light
    }

    private static let light = load("HermternalMarkLight")
    private static let dark = load("HermternalMarkDark")

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else {
            Log.error("Missing bundle resource \(name).png")
            return nil
        }
        return image
    }
}

/// Renders the canonical mark at a call-site-specific square size.
///
/// The source drawings are square, but `aspectRatio(contentMode: .fit)` is
/// intentional: callers can place this view in non-square layout proposals
/// without ever stretching the brand. If packaging omitted the required
/// resource, the view stays empty rather than silently showing a generic
/// system symbol in its place.
struct HermternalMarkView: View {
    @Environment(\.colorScheme) private var colorScheme
    let size: CGFloat

    var body: some View {
        if let image = HermternalMark.image(for: colorScheme) {
            Image(nsImage: image)
                .interpolation(.high)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityLabel("Hermternal")
        }
    }
}
