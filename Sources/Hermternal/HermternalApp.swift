import SwiftUI
import HermternalCore

private struct HermternalFindActionKey: FocusedValueKey {
    typealias Value = @MainActor @Sendable () -> Void
}

extension FocusedValues {
    var hermternalFindAction: (@MainActor @Sendable () -> Void)? {
        get { self[HermternalFindActionKey.self] }
        set { self[HermternalFindActionKey.self] = newValue }
    }
}

@main
struct HermternalApp: App {
    @State private var model: AppModel
    @State private var appearance = AppearanceSettings()
    @State private var registry: CapabilityRegistry
    private let fixtureMode: Bool

    init() {
        #if DEBUG
        let fixtureMode = SidebarFixtures.isEnabled
        let model: AppModel = {
            guard fixtureMode else { return AppModel() }
            // Keep fixture authority in memory only. Never write it to the
            // production server setting or credential stores.
            let model = AppModel(transcriptSource: SidebarFixtures.transcriptSource)
            model.serverText = SidebarFixtures.gatewayURL.absoluteString
            model.sessions = SidebarFixtures.sessions
            model.selectedSessionID = SidebarFixtures.transcriptSessionID
            model.messages = SidebarFixtures.transcriptMessages
            model.phase = .ready
            return model
        }()
        #else
        let fixtureMode = false
        let model = AppModel()
        #endif
        self.fixtureMode = fixtureMode
        _model = State(initialValue: model)

        var registry = CapabilityRegistry()
        let searchState: CapabilityState = if model.searchQuerying != nil {
            .available
        } else {
            .unavailable(
                reason: model.searchUnavailableReason
                    ?? "The local search index could not be opened."
            )
        }
        do {
            try registry.register(CapabilityDescriptor(
                id: CapabilityID("search"),
                name: "Transcript Search",
                purpose: "Search persisted conversation transcripts.",
                state: searchState,
                implementationSource: .builtIn
            ))
        } catch {
            Log.error(
                "Built-in search capability registration failed for descriptor "
                    + "search; Modules page will remain empty: \(error)"
            )
        }
        _registry = State(initialValue: registry)
    }

    var body: some Scene {
        Window("", id: "main") {
            GlassFrame(appearance: appearance) {
                RootView(model: model)
            }
            .preferredColorScheme(appearance.mode.colorScheme)
            .background {
                HiddenWindowTitle()
            }
            .onOpenURL { url in
                guard let link = MessageDeepLink(url: url) else {
                    model.toastPresenter.error("Unsupported message link")
                    return
                }
                guard let expectedHost = model.configuredGatewayHost,
                      expectedHost.caseInsensitiveCompare(link.gatewayHost) == .orderedSame
                else {
                    model.toastPresenter.error(
                        "Message belongs to a different gateway"
                    )
                    return
                }
                Task {
                    switch link.destination {
                    case .chat(let sessionID):
                        await model.openChat(sessionID: sessionID)
                    case .message(let location):
                        await model.open(at: location)
                    }
                }
            }
            .task {
                guard !fixtureMode else { return }
                await model.restoreOrPromptSignIn()
            }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1_040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    Task { await model.newChat() }
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Search Messages") {
                    model.toggleSearch()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                FindCommand()
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    SettingsWindowController.shared.show(
                        appearance: appearance,
                        model: model,
                        registry: registry
                    )
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
}
}

private struct FindCommand: View {
    @FocusedValue(\.hermternalFindAction) private var findAction

    var body: some View {
        Button("Find in Conversation") {
            findAction?()
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(findAction == nil)
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
                    // material. No base blur here — the glass is the blur, and
                    // a material over it would stop it refracting.
                    FrostedWindowBackground(
                        materialOpacity: appearance.windowFrostMaterialOpacity,
                        includesBaseBlur: false
                    )
                }
                .ignoresSafeArea()
            }
            .containerBackground(.clear, for: .window)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}
