import SwiftUI
import AppKit

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .signedOut:
                SignInView(model: model)
            case .connecting:
                ConnectingView()
            case .ready:
                ChatWindow(model: model)
            case .failed(let message):
                FailureView(message: message, model: model)
            }
        }
        .background {
            ToolbarChromeVisibility(isHidden: model.isSearchPresented)
        }
        .overlay {
            ToastLayer()
                .environment(model.toastPresenter)
                .zIndex(2)
        }
    }
}

private struct ConnectingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to Hermes…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailureView: View {
    let message: String
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.orange)
            Text("Could not connect")
                .font(.title3.weight(.semibold))
            // The gateway's own error text is the most useful thing we can
            // show while iterating, so surface it verbatim and selectable.
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
            HStack {
                Button("Try Again") { Task { await model.signIn() } }
                    .buttonStyle(.borderedProminent)
                Button("Sign Out") { Task { await model.signOut() } }
            }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ChatWindow: View {
    @Bindable var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                model: model,
                accountName: model.accountPresentation.title,
                accountDetail: model.accountPresentation.detail,
                // The visible title is a truncated account id, so the full
                // value has to reach the tooltip and VoiceOver label.
                accountID: model.accountPresentation.accountID
            )
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
        } detail: {
            ChatView(
                model: model,
                isReadOnly: model.isViewingArchivedTranscript
            )
        }
        // Keep the native titlebar and traffic lights; ChatView conditionally
        // renders its controls so the toolbar group has no empty capsule.
        .overlay {
            ZStack {
                if model.isSearchPresented, let querying = model.searchQuerying {
                    SearchPanel(
                        querying: querying,
                        activate: { location in
                            Task {
                                await model.open(at: location)
                                model.isSearchPresented = false
                            }
                        },
                        dismiss: { model.isSearchPresented = false }
                    )
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            // The overlay and the panel share one animation so material,
            // panel content, and dismissal remain a single interruptible
            // gesture when ⌘K/Escape are pressed repeatedly.
            .animation(
                SearchPanel.panelAnimation(reduceMotion: reduceMotion),
                value: model.isSearchPresented
            )
        }
        .onChange(of: model.isSearchPresented) { _, presented in
            model.toastPresenter.setSuppressed(presented)
        }
        .task {
            model.toastPresenter.setSuppressed(model.isSearchPresented)
        }
    }
}


private struct ToolbarChromeVisibility: NSViewRepresentable {
    let isHidden: Bool

    func makeNSView(context: Context) -> ToolbarChromeHost {
        ToolbarChromeHost()
    }

    func updateNSView(_ nsView: ToolbarChromeHost, context: Context) {
        nsView.setHidden(isHidden)
    }
}

@MainActor
private final class ToolbarChromeHost: NSView {
    private var desiredHidden = false
    private var savedIdentifiers: [NSToolbarItem.Identifier] = []
    private var savedTitlebarButtons: [(NSView, Bool)] = []

    func setHidden(_ hidden: Bool) {
        desiredHidden = hidden

        if hidden {
            // Hide chrome as soon as the panel appears, but keep restoration
            // behind the panel's opacity transition so it cannot flash over
            // the still-fading card and shadow on dismissal.
            applyVisibility()
        } else {
            // The search overlay owns the fade-out. Let the dim remain until
            // that transition has completed; restoring here would expose a
            // bright window behind the card for a frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.desiredHidden else { return }
                self.applyVisibility()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyVisibility()
    }

    private func applyVisibility() {
        if desiredHidden {
            hideTitlebarButtons()
        } else {
            restoreTitlebarButtons()
        }

        guard let toolbar = window?.toolbar else { return }
        if desiredHidden {
            guard savedIdentifiers.isEmpty else { return }
            savedIdentifiers = toolbar.items.map(\.itemIdentifier)
            guard !toolbar.items.isEmpty else { return }
            for index in stride(from: toolbar.items.count - 1, through: 0, by: -1) {
                toolbar.removeItem(at: index)
            }
        } else {
            guard !savedIdentifiers.isEmpty else { return }
            let identifiers = savedIdentifiers
            savedIdentifiers.removeAll()
            for (index, identifier) in identifiers.enumerated() {
                guard !toolbar.items.contains(where: {
                    $0.itemIdentifier == identifier
                }) else { continue }
                toolbar.insertItem(
                    withItemIdentifier: identifier,
                    at: min(index, toolbar.items.count)
                )
            }
        }
    }

    private func hideTitlebarButtons() {
        guard savedTitlebarButtons.isEmpty, let window else { return }
        let standardButtons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }
        guard let root = window.contentView?.superview else { return }
        collectTitlebarViews(
            in: root,
            insideTitlebar: false,
            insideStandardButton: false,
            excluding: standardButtons
        )
    }

    private func collectTitlebarViews(
        in view: NSView,
        insideTitlebar: Bool,
        insideStandardButton: Bool,
        excluding standardButtons: [NSButton]
    ) {
        let className = NSStringFromClass(type(of: view))
        let isTitlebar = insideTitlebar
            || className.localizedCaseInsensitiveContains("toolbar")
            || className.localizedCaseInsensitiveContains("titlebar")
        let isStandardButton = view is NSButton
            && standardButtons.contains(where: { $0 === view })
        let isInsideStandardButton = insideStandardButton || isStandardButton

        if isTitlebar, !isInsideStandardButton, view !== window,
           view.subviews.isEmpty {
            savedTitlebarButtons.append((view, view.isHidden))
            view.isHidden = true
        }
        for child in view.subviews {
            collectTitlebarViews(
                in: child,
                insideTitlebar: isTitlebar,
                insideStandardButton: isInsideStandardButton,
                excluding: standardButtons
            )
        }
    }

    private func restoreTitlebarButtons() {
        let saved = savedTitlebarButtons
        savedTitlebarButtons.removeAll()
        for (button, wasHidden) in saved {
            button.isHidden = wasHidden
        }
    }
}
