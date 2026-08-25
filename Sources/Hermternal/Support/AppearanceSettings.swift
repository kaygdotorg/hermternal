import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` defers to the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// A stored accent value. `nil` means that the system accent remains active.
struct AccentColorValue: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(nsColor: NSColor) {
        guard let color = nsColor.usingColorSpace(.sRGB) else {
            self.init(red: 0.5, green: 0.5, blue: 0.5)
            return
        }
        self.init(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent)
        )
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}

/// Stores the optional application accent without changing the system colour.
enum AccentColorStore {
    static let key = "appearance.accentOverride"
    static let didChangeNotification = Notification.Name(
        "HermternalAccentColorDidChange"
    )

    static func load(from defaults: UserDefaults = .standard) -> AccentColorValue? {
        guard let values = defaults.array(forKey: key) as? [Double], values.count == 4 else {
            return nil
        }
        return AccentColorValue(
            red: values[0],
            green: values[1],
            blue: values[2],
            alpha: values[3]
        )
    }

    static func save(
        _ value: AccentColorValue,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set([value.red, value.green, value.blue, value.alpha], forKey: key)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    static func resolvedColor(
        from defaults: UserDefaults = .standard
    ) -> NSColor {
        load(from: defaults)?.nsColor ?? NSColor.controlAccentColor
    }
}

/// User-tunable appearance, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppearanceSettings {
    var mode: AppearanceMode {
        didSet {
            guard oldValue != mode else { return }
            defaults.set(mode.rawValue, forKey: Keys.mode)
            applyAppKitAppearance()
        }
    }

    /// An explicit app accent. `nil` keeps the macOS system accent active.
    var accentOverride: AccentColorValue? {
        didSet {
            guard oldValue != accentOverride else { return }
            if let accentOverride {
                AccentColorStore.save(accentOverride, to: defaults)
            } else {
                AccentColorStore.clear(from: defaults)
            }
            NotificationCenter.default.post(
                name: AccentColorStore.didChangeNotification,
                object: nil
            )
            // Reuse the renderer's existing system-colour invalidation path.
            NotificationCenter.default.post(
                name: NSColor.systemColorsDidChangeNotification,
                object: nil
            )
        }
    }

    /// The current accent for views that need an AppKit colour.
    var effectiveAccentColor: NSColor {
        accentOverride?.nsColor ?? NSColor.controlAccentColor
    }

    /// How solid the chat window's background is, 0...1. Continuous, and it
    /// owns show-through on its own: the treatment behind it is never scaled
    /// by this value. Live value while dragging; persisted when editing ends
    /// so a pointer drag does not write UserDefaults once per sample.
    var backgroundOpacity: Double

    /// Swaps the window's frosted blur for Liquid Glass. A mode, not a point
    /// on the opacity dial, and the two are mutually exclusive. Persisted on
    /// change rather than on edit end, because a tick is not dragged.
    var usesLiquidGlass: Bool {
        didSet {
            defaults.set(usesLiquidGlass, forKey: Keys.usesLiquidGlass)
        }
    }

    /// Solid enough to read against any desktop, translucent enough that the
    /// blur behind it is plainly the point.
    private static let defaultBackgroundOpacity = 0.85

    /// Opacity only means anything inside 0...1, and the value can arrive from
    /// a `UserDefaults` payload written by another build.
    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : defaultBackgroundOpacity
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let mode = "appearance.mode"
        static let backgroundOpacity = "appearance.backgroundOpacity"
        static let usesLiquidGlass = "appearance.usesLiquidGlass"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AppearanceMode(rawValue: defaults.string(forKey: Keys.mode) ?? "")
            ?? .system
        accentOverride = AccentColorStore.load(from: defaults)
        backgroundOpacity = Self.clamped(
            defaults.object(forKey: Keys.backgroundOpacity) as? Double
                ?? Self.defaultBackgroundOpacity
        )
        // `didSet` does not fire for this, so loading costs no write back.
        usesLiquidGlass = defaults.bool(forKey: Keys.usesLiquidGlass)
        applyAppKitAppearance()
    }

    /// Sets an override only after the user chooses a colour.
    func setAccentOverride(_ color: AccentColorValue) {
        accentOverride = color
    }

    /// Removes the override and returns to the macOS system accent.
    func useSystemAccent() {
        accentOverride = nil
    }

    /// SwiftUI's `preferredColorScheme` only updates SwiftUI's environment.
    /// AppKit materials, toolbars, and window chrome resolve from `NSAppearance`,
    /// so update the application synchronously before SwiftUI renders the new mode.
    private func applyAppKitAppearance() {
        let appKitAppearance: NSAppearance? = switch mode {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }

        // Apple documents that NSApplication.appearance is inherited by the app's windows and views:
        // https://developer.apple.com/documentation/appkit/nsapplication/appearance
        // Assigning windows one at a time made adoption depend on each window's next update cycle, so Settings changed first while Chat waited for focus to repaint.
        // Use `.shared` rather than `NSApp`: initialization can run before NSApp's implicitly unwrapped global has an application instance.
        NSApplication.shared.appearance = appKitAppearance
    }

    /// Live value while the thumb is moving: the window follows it exactly.
    func previewBackgroundOpacity(_ value: Double) {
        backgroundOpacity = Self.clamped(value)
    }

    func persistBackgroundOpacity() {
        defaults.set(backgroundOpacity, forKey: Keys.backgroundOpacity)
    }

    func resetToDefaults() {
        mode = .system
        accentOverride = nil
        backgroundOpacity = Self.defaultBackgroundOpacity
        persistBackgroundOpacity()
        usesLiquidGlass = false
    }
}
