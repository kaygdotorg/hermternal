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
/// Glass intensity is stored per surface because the sidebar and the
/// transcript want different amounts in practice: a translucent sidebar
/// reads as chrome, while long-form text needs more opacity to stay legible.
@MainActor
@Observable
final class AppearanceSettings {
    var mode: AppearanceMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }

    /// 0 = fully opaque, 1 = fully translucent.
    var sidebarGlass: Double {
        didSet { defaults.set(sidebarGlass, forKey: Keys.sidebarGlass) }
    }

    var chatGlass: Double {
        didSet { defaults.set(chatGlass, forKey: Keys.chatGlass) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let mode = "appearance.mode"
        static let sidebarGlass = "appearance.sidebarGlass"
        static let chatGlass = "appearance.chatGlass"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AppearanceMode(rawValue: defaults.string(forKey: Keys.mode) ?? "")
            ?? .system
        // Chrome leans translucent, reading surface leans opaque.
        sidebarGlass = defaults.object(forKey: Keys.sidebarGlass) as? Double ?? 0.85
        chatGlass = defaults.object(forKey: Keys.chatGlass) as? Double ?? 0.35
    }

    func resetToDefaults() {
        mode = .system
        sidebarGlass = 0.85
        chatGlass = 0.35
    }
}
