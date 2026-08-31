import CoreGraphics
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The colour type of the platform's UI framework.
///
/// This alias is the whole platform Seam for the outgoing bubble's colours.
/// HermternalCore stays colour-free, and an iOS Adapter compiles this source
/// without a second copy of the policy.
#if canImport(AppKit)
typealias PlatformColor = NSColor
#elseif canImport(UIKit)
typealias PlatformColor = UIColor
#endif

/// Chooses black or white text for an arbitrary filled surface.
///
/// The outgoing bubble is filled with the platform accent, which can be any
/// colour the user selects. Apple documents no foreground partner for
/// `controlAccentColor`, so this policy measures the fill instead of following
/// a convention. WCAG 2.1 relative luminance gives at least 4.5:1 on every
/// possible fill, which a fixed white foreground does not.
enum OutgoingForegroundPolicy {
    /// The luminance at which black text and white text read equally well.
    ///
    /// WCAG contrast is `(L1 + 0.05) / (L2 + 0.05)`. Black and white are equal
    /// when `1.05 / (L + 0.05) == (L + 0.05) / 0.05`, so the crossover is
    /// `sqrt(0.0525) - 0.05`.
    static let crossoverLuminance: CGFloat = 0.179128784747792

    /// The WCAG 2.1 relative luminance of one sRGB colour.
    static func relativeLuminance(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> CGFloat {
        0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// `true` when black text has the higher contrast ratio on this fill.
    static func prefersBlackText(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> Bool {
        relativeLuminance(red: red, green: green, blue: blue) > crossoverLuminance
    }

    /// The sRGB transfer function, which turns a stored component into light.
    private static func linear(_ component: CGFloat) -> CGFloat {
        let value = min(max(component, 0), 1)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

/// Everything the outgoing bubble draws with, from one resolution of the fill.
///
/// The bubble draws in two places: a shape layer behind the row and text inside it. Each place resolved the accent separately.
/// The unresolved layer used its default black. The text policy read the accent as blue and selected black foreground text.
/// The bubble therefore showed a black background and black text.
///
/// One value now carries every product of one resolution, so no caller can take
/// the fill from one reading and the foreground from another.
struct OutgoingBubbleColors {
    /// The bubble's fill, resolved to sRGB.
    ///
    /// The dynamic colour is already spent: this value has components, and it
    /// does not change again with the appearance. It is the exact colour the
    /// foreground was measured against.
    let fill: PlatformColor

    /// `fill` for a layer property.
    ///
    /// The conversion happens here, beside the resolution that makes it total.
    /// `fill` is sRGB, which CoreGraphics always represents, so this is never
    /// the undefined conversion that a catalog colour's `cgColor` is.
    let layerFill: CGColor

    /// The text colour that reads on `fill`: black or white, whichever WCAG 2.1
    /// gives the higher contrast ratio.
    let foreground: PlatformColor
}

/// The outgoing bubble's fill and text colours for the current platform.
enum OutgoingBubblePalette {
    /// The bubble's fill, before an appearance resolves it.
    ///
    /// The value is never stored. Each read returns the platform's dynamic
    /// colour, so it resolves again in whichever appearance and contrast
    /// setting is current when it is read.
    static var fill: PlatformColor {
        #if canImport(AppKit)
        // The live system accent. The app's own accent override is deliberately
        // not read here: this bubble states what macOS is set to, not what one
        // app stores.
        return NSColor.controlAccentColor
        #elseif canImport(UIKit)
        // iOS has no system accent preference. System blue is the platform's
        // default tint, and it adapts to the current trait collection. This
        // stands until an iOS app supplies another policy.
        return UIColor.systemBlue
        #endif
    }

    #if canImport(AppKit)
    /// Everything the bubble draws with, under `appearance`.
    ///
    /// Pass the effective appearance of the view the bubble is seen in. The
    /// result carries no dynamic colour, so it is safe to hand to a layer.
    ///
    /// Main-actor: the appearance always comes from a view, and every caller is
    /// a view.
    @MainActor
    static func colors(for appearance: NSAppearance) -> OutgoingBubbleColors {
        var resolved: OutgoingBubbleColors?
        // A dynamic colour has components only while an appearance is the
        // current drawing appearance. This is the call Apple's Dark Mode guide
        // names for appearance-sensitive custom drawing code.
        appearance.performAsCurrentDrawingAppearance {
            resolved = colorsInCurrentAppearance()
        }
        // The block runs before the call returns. The coalesce is only what lets
        // the result be a plain value instead of an optional at every call site.
        return resolved ?? colorsInCurrentAppearance()
    }

    /// Everything the bubble draws with, under whichever appearance is current.
    private static func colorsInCurrentAppearance() -> OutgoingBubbleColors {
        // `NSColor.cgColor` is defined for a colour CoreGraphics can represent.
        // The accent is a catalog colour, which it cannot, so the layer must
        // never be handed the accent's own `cgColor`. sRGB is the conversion the
        // foreground policy needs anyway, so one conversion serves both.
        guard let resolved = fill.usingColorSpace(.sRGB) else { return fallback }
        return OutgoingBubbleColors(
            fill: resolved,
            layerFill: resolved.cgColor,
            foreground: foreground(on: resolved)
        )
    }

    /// The pair AppKit itself uses for text on an accent-filled selection.
    ///
    /// Reached only when the accent cannot be read as sRGB, which is what a
    /// pattern colour or an unconvertible colour space would cause. The
    /// selection background is the one other system colour that states "this
    /// surface carries the accent", and `selectedControlTextColor` is its
    /// documented text partner, so the pair still follows appearance and
    /// contrast. It is never black on black.
    private static var fallback: OutgoingBubbleColors {
        let selection = NSColor.selectedContentBackgroundColor
        let resolved = selection.usingColorSpace(.sRGB) ?? selection
        return OutgoingBubbleColors(
            fill: resolved,
            layerFill: resolved.cgColor,
            foreground: NSColor.selectedControlTextColor
        )
    }
    #elseif canImport(UIKit)
    /// Everything the bubble draws with, under `traits`.
    ///
    /// Main-actor for the same reason the AppKit branch is: the traits come
    /// from a view.
    @MainActor
    static func colors(for traits: UITraitCollection) -> OutgoingBubbleColors {
        let resolved = fill.resolvedColor(with: traits)
        return OutgoingBubbleColors(
            fill: resolved,
            layerFill: resolved.cgColor,
            foreground: foreground(on: resolved)
        )
    }
    #endif

    /// The text colour that reads best on `fill`.
    ///
    /// Call this with a fill an appearance has already resolved. The components
    /// of a dynamic colour do not exist until then.
    static func foreground(on fill: PlatformColor) -> PlatformColor {
        #if canImport(AppKit)
        guard let resolved = fill.usingColorSpace(.sRGB) else {
            // Conversion fails for a pattern colour or an unconvertible space.
            // AppKit's own text colour for an accent-filled selection is the
            // only remaining answer that follows appearance and contrast.
            return NSColor.selectedControlTextColor
        }
        let prefersBlack = OutgoingForegroundPolicy.prefersBlackText(
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent
        )
        return prefersBlack ? NSColor.black : NSColor.white
        #elseif canImport(UIKit)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard fill.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return UIColor.white
        }
        let prefersBlack = OutgoingForegroundPolicy.prefersBlackText(
            red: red,
            green: green,
            blue: blue
        )
        return prefersBlack ? UIColor.black : UIColor.white
        #endif
    }
}
