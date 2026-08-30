import SwiftUI
import HermternalCore


@main
struct HermternalApp: App {
    @NSApplicationDelegateAdaptor(HermternalApplicationDelegate.self)
    private var applicationDelegate
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
        do {
            try registry.register(CapabilityDescriptor(
                id: CapabilityID("composer"),
                name: "Message Composer",
                purpose: "Send text and staged attachments through the gateway.",
                state: model.phase == .ready ? .available : .omitted,
                implementationSource: .builtIn
            ))
        } catch {
            Log.error("Built-in composer capability registration failed: \(error)")
        }
        _registry = State(initialValue: registry)
        let capabilityRefresh: @MainActor () -> Void = { [model, registry] in
            let state: CapabilityState
            if model.canPurgeSessions {
                state = .available
            } else if case .ready = model.phase {
                state = .unavailable(reason: model.sessionPurgeUnavailableReason)
            } else {
                state = .omitted
            }
            do {
                try registry.replace(CapabilityDescriptor(
                    id: CapabilityID("session-purge"),
                    name: "Complete Session Deletion",
                    purpose: "Permanently remove application session state through the gateway REST API.",
                    state: state,
                    implementationSource: .builtIn
                ))
            } catch {
                Log.error("Built-in session purge capability update failed: \(error)")
            }
            do {
                try registry.replace(CapabilityDescriptor(
                    id: CapabilityID("composer"),
                    name: "Message Composer",
                    purpose: "Send text and staged attachments through the gateway.",
                    state: model.phase == .ready ? .available : .omitted,
                    implementationSource: .builtIn
                ))
            } catch {
                Log.error("Built-in composer capability update failed: \(error)")
            }
        }
        applicationDelegate.configure(
            appearance: appearance,
            model: model,
            registry: registry,
            debugModules: debugModules,
            fixtureMode: fixtureMode,
            capabilityRefresh: capabilityRefresh
        )
    }


    var body: some Scene {
        // The main window is created and owned by MainWindowController. This
        // scene exists only to keep SwiftUI's application commands available.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    _ = applicationDelegate.showMainWindowIfReady()
                    Task { await model.newChatCommand() }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.phase != .ready)
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Conversation") {
                    _ = applicationDelegate.showMainWindowIfReady()
                    model.requestFind()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.phase != .ready)
                Button("Search Messages") {
                    _ = applicationDelegate.showMainWindowIfReady()
                    model.toggleSearch()
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model.phase != .ready || model.searchQuerying == nil)
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
