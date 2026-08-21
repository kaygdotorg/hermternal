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
///
/// Tahoe owns Liquid Glass for standard components. The public native
/// sidebar material has no opacity/intensity control, so this model does not
/// pretend to expose one through custom backgrounds.
@MainActor
@Observable
final class AppearanceSettings {
    var mode: AppearanceMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }


    private let defaults: UserDefaults

    private enum Keys {
        static let mode = "appearance.mode"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AppearanceMode(rawValue: defaults.string(forKey: Keys.mode) ?? "")
            ?? .system
    }

    func resetToDefaults() {
        mode = .system
    }
}
