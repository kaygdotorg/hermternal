import SwiftUI

@main
struct HermternalApp: App {
    @State private var model = AppModel()
    @State private var appearance = AppearanceSettings()

    var body: some Scene {
        Window("Hermternal", id: "main") {
            GlassFrame(appearance: appearance) {
                RootView(model: model)
            }
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

/// One Liquid Glass layer spanning the whole window, titlebar included.
///
/// Both halves are load-bearing: the glass layer respects the titlebar safe
/// area, so without `ignoresSafeArea` the titlebar stays a solid strip; and
/// the toolbar draws its own opaque backing over the glass, so without
/// hiding that backing the titlebar covers the material either way.
private struct GlassFrame<Content: View>: View {
    @Bindable var appearance: AppearanceSettings
    @ViewBuilder let content: Content

    var body: some View {
        content
            // The glass must escape the titlebar safe area, but the content
            // must not: a ZStack sibling that ignores it collapses the safe
            // area for the whole stack, so the transcript stops knowing a
            // titlebar is above it and loses its scroll edge effect.
            .background {
                ZStack {
                    Color.clear
                        .glassEffect(.regular, in: .rect(cornerRadius: 0))
                    // Frost rides over the glass on purpose: at 0 the glass
                    // refracts untouched, at 1 the window reads as a frosted
                    // material. Unlike a mandatory scrim, this is a dial the
                    // user chooses, and 0 leaves the material intact.
                    Rectangle()
                        .fill(.regularMaterial)
                        .opacity(appearance.windowFrost)
                }
                .ignoresSafeArea()
            }
            .containerBackground(.clear, for: .window)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}
