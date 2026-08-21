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
/// Tahoe owns the native sidebar material. Only the chat detail has an
/// app-controlled opacity veil over one persistent glass host.
@MainActor
@Observable
final class AppearanceSettings {
    var mode: AppearanceMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }

    /// Live value used while dragging. Persist explicitly when editing ends
    /// so UserDefaults is not written once per pointer sample.
    var chatOpacity: Double


    private let defaults: UserDefaults

    private enum Keys {
        static let mode = "appearance.mode"
        static let chatOpacity = "appearance.chatOpacity"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AppearanceMode(rawValue: defaults.string(forKey: Keys.mode) ?? "")
            ?? .system
        chatOpacity = defaults.object(forKey: Keys.chatOpacity) as? Double ?? 0.50
    }

    func previewChatOpacity(_ value: Double) {
        chatOpacity = min(max(value, 0), 1)
    }

    func persistChatOpacity() {
        defaults.set(chatOpacity, forKey: Keys.chatOpacity)
    }

    func resetToDefaults() {
        mode = .system
        chatOpacity = 0.50
        persistChatOpacity()
    }
}
