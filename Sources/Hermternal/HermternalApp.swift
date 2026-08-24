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
    /// The one instrumentation capability for the process, decided here and
    /// injected. Held behind its protocol so a real controller, an in-memory
    /// fake, or an omission are the same seam to every consumer.
    private let debugModules: any DebugModuleCapability

    init() {
        // The app's only reads of the instrumentation environment. Composition
        // owns both decisions and hands them down as Bools, so no view and no
        // hot path consults the environment.
        //
        // HERMTERNAL_DEBUG reveals the Modules pane and turns every module on
        // by default. HERMTERNAL_SWITCH_TRACE forces the mask on for a single
        // launch without revealing the pane, which is how headless automation
        // keeps measuring. With neither present the gate is a hard zero and
        // the persisted mask is neither read nor written, so a module enabled
        // during an earlier debug session cannot come back in a normal one.
        let environment = ProcessInfo.processInfo.environment
        let debugModules = DebugModuleController(
            debugMode: environment["HERMTERNAL_DEBUG"] == "1",
            forceAllModulesOn: environment["HERMTERNAL_SWITCH_TRACE"] == "1"
        )
        self.debugModules = debugModules

        #if DEBUG
        let fixtureMode = SidebarFixtures.isEnabled
        let model: AppModel = {
            guard fixtureMode else { return AppModel(debugModules: debugModules) }
            // Keep fixture authority in memory only. Never write it to the
            // production server setting or credential stores.
            let model = AppModel(
                transcriptSource: SidebarFixtures.transcriptSource,
                debugModules: debugModules
            )
            model.serverText = SidebarFixtures.gatewayURL.absoluteString
            model.sessions = SidebarFixtures.sessions.filter { !$0.archived }
            model.archivedSessions = SidebarFixtures.sessions.filter(\.archived)
            model.selectedSessionID = SidebarFixtures.transcriptSessionID
            model.messages = SidebarFixtures.transcriptMessages
            model.phase = .ready
            return model
        }()
        #else
        let fixtureMode = false
        let model = AppModel(debugModules: debugModules)
        #endif
        self.fixtureMode = fixtureMode
        _model = State(initialValue: model)

        let registry = CapabilityRegistry()
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
        do {
            try registry.register(CapabilityDescriptor(
                id: CapabilityID("session-purge"),
                name: "Complete Session Deletion",
                purpose: "Permanently remove application session state through the gateway REST API.",
                state: model.canPurgeSessions ? .available : .omitted,
                implementationSource: .builtIn
            ))
        } catch {
            Log.error("Built-in session purge capability registration failed: \(error)")
        }
        _registry = State(initialValue: registry)
    }

    private var sessionPurgeCapabilityState: CapabilityState {
        if model.canPurgeSessions {
            return .available
        }
        if case .ready = model.phase {
            return .unavailable(reason: model.sessionPurgeUnavailableReason)
        }
        return .omitted
    }

    private func refreshSessionPurgeCapability() {
        do {
            try registry.replace(CapabilityDescriptor(
                id: CapabilityID("session-purge"),
                name: "Complete Session Deletion",
                purpose: "Permanently remove application session state through the gateway REST API.",
                state: sessionPurgeCapabilityState,
                implementationSource: .builtIn
            ))
        } catch {
            Log.error("Built-in session purge capability update failed: \(error)")
        }
    }

    var body: some Scene {
        Window("", id: "main") {
            WindowFrame(appearance: appearance) {
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
                model.route(link.destination)
            }
            .task {
                guard !fixtureMode else { return }
                await model.restoreOrPromptSignIn()
            }
            .onChange(of: model.phase) { _, _ in
                refreshSessionPurgeCapability()
            }
            .onChange(of: model.sessionPurgeCapability) { _, _ in
                refreshSessionPurgeCapability()
            }
            .onChange(of: model.sessionPurgeUnavailableReason) { _, _ in
                refreshSessionPurgeCapability()
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
                        registry: registry,
                        debugModules: debugModules
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

/// The window's background, escaping the titlebar so the chrome is not a solid
/// strip.
///
/// Both halves are load-bearing: the background must escape the titlebar safe
/// area, or the titlebar stays a solid strip; and the toolbar draws its own
/// opaque backing over it, so without hiding that backing the titlebar masks
/// the treatment either way.
///
/// The default treatment is a frosted blur, not Liquid Glass. The Materials HIG
/// is explicit — "Don't use Liquid Glass in the content layer… Instead, use
/// standard materials for elements in the content layer, such as app
/// backgrounds" — and a window-sized `glassEffect(.regular)` used to sit here.
/// `Glass.regular` "adjusts the luminosity of background content" to protect
/// legibility, which is right for a floating control and can wash a whole
/// window of text. Glass is now the tick in Settings rather than the default,
/// and the always-on Liquid Glass stays where Apple puts it: the composer
/// capsule, the send button, and the search field.
private struct WindowFrame<Content: View>: View {
    let appearance: AppearanceSettings
    @ViewBuilder let content: Content

    var body: some View {
        content
            // The background must escape the titlebar safe area, but the
            // content must not: a ZStack sibling that ignores it collapses the
            // safe area for the whole stack, so the transcript stops knowing a
            // titlebar is above it and loses its scroll edge effect.
            .background {
                WindowBackdrop(
                    opacity: appearance.backgroundOpacity,
                    usesLiquidGlass: appearance.usesLiquidGlass
                )
                .ignoresSafeArea()
            }
            .containerBackground(.clear, for: .window)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}
