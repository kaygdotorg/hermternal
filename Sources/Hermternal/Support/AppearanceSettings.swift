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
        backgroundOpacity = Self.clamped(
            defaults.object(forKey: Keys.backgroundOpacity) as? Double
                ?? Self.defaultBackgroundOpacity
        )
        // `didSet` does not fire for this, so loading costs no write back.
        usesLiquidGlass = defaults.bool(forKey: Keys.usesLiquidGlass)
        applyAppKitAppearance()
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

        // Apple documents that NSApplication.appearance is inherited by the
        // app's windows and views:
        // https://developer.apple.com/documentation/appkit/nsapplication/appearance
        // Assigning windows one at a time made adoption depend on each
        // window's next update cycle, so Settings changed first while Chat
        // waited for focus to repaint.
        // Use `.shared` rather than `NSApp`: initialization can run before
        // NSApp's implicitly unwrapped global has an application instance.
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
        backgroundOpacity = Self.defaultBackgroundOpacity
        persistBackgroundOpacity()
        usesLiquidGlass = false
    }
}
