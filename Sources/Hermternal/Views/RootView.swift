import SwiftUI

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
        // The search panel is the front surface of the window. No toolbar item
        // must show above it. The `automatic` placement removes the toolbar
        // items only. The `.windowToolbar` placement removes the whole window
        // toolbar, and it also removes the title and the traffic light
        // controls. This window keeps those controls.
        .toolbarVisibility(model.isSearchPresented ? .hidden : .automatic)
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
                // `NavigationSplitView` supplies the sidebar toggle item. A
                // hidden toolbar visibility removes custom items only, so it
                // does not remove this item. Apple documents
                // `toolbar(removing:)` on the sidebar column for this purpose.
                // The parameter is optional, so one state controls both
                // modifiers.
                .toolbar(
                    removing: model.isSearchPresented ? .sidebarToggle : nil
                )
        } detail: {
            ChatView(
                model: model,
                isReadOnly: model.isViewingArchivedTranscript
            )
        }
        // The window keeps the native titlebar and the traffic light controls.
        // `ChatView` and `SidebarView` declare the toolbar items
        // unconditionally. Only the visibility modifiers above respond to the
        // search panel, so the panel does not cause a toolbar rebuild.
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
