import SwiftUI

@main
struct HermternalApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Hermternal", id: "main") {
            RootView(model: model)
                .task { await model.restoreOrPromptSignIn() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    Task { await model.newChat() }
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
