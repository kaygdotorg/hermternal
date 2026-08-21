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

    /// Darkens the window backing *behind* the glass, so refraction survives.
    /// Live value while dragging; persisted when editing ends so a pointer
    /// drag does not write UserDefaults once per sample.
    var windowDimming: Double

    private let defaults: UserDefaults

    private enum Keys {
        static let mode = "appearance.mode"
        static let windowDimming = "appearance.windowDimming"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AppearanceMode(rawValue: defaults.string(forKey: Keys.mode) ?? "")
            ?? .system
        windowDimming = defaults.object(forKey: Keys.windowDimming) as? Double ?? 0.20
    }

    func previewWindowDimming(_ value: Double) {
        windowDimming = min(max(value, 0), 1)
    }

    func persistWindowDimming() {
        defaults.set(windowDimming, forKey: Keys.windowDimming)
    }

    func resetToDefaults() {
        mode = .system
        windowDimming = 0.20
        persistWindowDimming()
    }
}
