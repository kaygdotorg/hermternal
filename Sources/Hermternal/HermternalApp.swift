import SwiftUI

@main
struct HermternalApp: App {
    @State private var model = AppModel()
    @State private var appearance = AppearanceSettings()

    var body: some Scene {
        Window("Hermternal", id: "main") {
            RootView(model: model, appearance: appearance)
                .preferredColorScheme(appearance.mode.colorScheme)
                .task { await model.restoreOrPromptSignIn() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1_040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    Task { await model.newChat() }
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsView(appearance: appearance, model: model)
                .preferredColorScheme(appearance.mode.colorScheme)
        }
    }
}
