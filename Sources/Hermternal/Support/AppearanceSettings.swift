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
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }

    /// Crossfades the window between clear Liquid Glass at 0 and a frosted
    /// material at 1. Live value while dragging; persisted when editing ends
    /// so a pointer drag does not write UserDefaults once per sample.
    var windowFrost: Double

    private let defaults: UserDefaults

    private enum Keys {
        static let mode = "appearance.mode"
        static let windowFrost = "appearance.windowFrost"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AppearanceMode(rawValue: defaults.string(forKey: Keys.mode) ?? "")
            ?? .system
        windowFrost = defaults.object(forKey: Keys.windowFrost) as? Double ?? 0.20
    }

    func previewWindowFrost(_ value: Double) {
        windowFrost = min(max(value, 0), 1)
    }

    func persistWindowFrost() {
        defaults.set(windowFrost, forKey: Keys.windowFrost)
    }

    func resetToDefaults() {
        mode = .system
        windowFrost = 0.20
        persistWindowFrost()
    }
}
