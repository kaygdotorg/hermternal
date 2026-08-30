import HermternalCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    let onModelStateChanged: @MainActor () -> Void

    init(
        model: AppModel,
        onModelStateChanged: @escaping @MainActor () -> Void = {}
    ) {
        self._model = Bindable(model)
        self.onModelStateChanged = onModelStateChanged
    }

    var body: some View {
        ZStack {
            switch model.phase {
            case .signedOut:
                SignInView(model: model)
            case .connecting:
                ConnectingView()
            case .ready:
                ChatView(
                    model: model,
                    isReadOnly: model.isViewingArchivedTranscript
                )
            case .failed(let message):
                FailureView(message: message, model: model)
            }
        }
        .onChange(of: model.isSearchPresented) { _, presented in
            model.toastPresenter.setSuppressed(presented)
            onModelStateChanged()
        }
        .onChange(of: model.viewingArchivedSessionID) { _, _ in
            onModelStateChanged()
        }
        .onChange(of: model.archivedSessions) { _, _ in
            onModelStateChanged()
        }
        .onChange(of: model.sessionPurgeCapability) { _, _ in
            onModelStateChanged()
        }
        .onChange(of: model.sessionPurgeUnavailableReason) { _, _ in
            onModelStateChanged()
        }
        .task {
            model.toastPresenter.setSuppressed(model.isSearchPresented)
            onModelStateChanged()
        }
    }
}

/// The SwiftUI-owned split is hosted by the AppKit window shell. Keeping the
/// visibility state here means a column change never changes the NSWindow's
/// frame or asks AppKit to restore a divider position.
struct MainSplitRoot: View {
    @Bindable var model: AppModel
    let appearance: AppearanceSettings
    let onModelStateChanged: @MainActor () -> Void
    let isActive: Bool
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var readyVisibility: NavigationSplitViewVisibility
    @State private var wasReady: Bool

    init(
        model: AppModel,
        appearance: AppearanceSettings,
        onModelStateChanged: @escaping @MainActor () -> Void = {},
        isActive: Bool = true
    ) {
        self._model = Bindable(model)
        self.appearance = appearance
        self.onModelStateChanged = onModelStateChanged
        self.isActive = isActive
        let startsReady = model.phase == .ready
        self._columnVisibility = State(initialValue: startsReady ? .all : .detailOnly)
        self._readyVisibility = State(initialValue: .all)
        self._wasReady = State(initialValue: startsReady)
    }

    var body: some View {
        Group {
            if !isActive {
                Color.clear
            } else if model.phase == .ready {
                splitContent
            } else {
                RootView(model: model, onModelStateChanged: onModelStateChanged)
                    // Keep the authentication surface below the titlebar.
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .environment(
            \.hermternalAccentColor,
            Color(nsColor: appearance.effectiveAccentColor)
        )
        .environment(
            \.hermternalAlwaysShowsChatMetadata,
            appearance.alwaysShowsChatMetadata
        )
        .tint(Color(nsColor: appearance.effectiveAccentColor))

        .onChange(of: model.phase) { _, phase in
            synchronizeVisibility(for: phase)
            onModelStateChanged()
        }
        .task {
            synchronizeVisibility(for: model.phase)
        }
    }

    private var splitContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                model: model,
                accountName: model.accountPresentation.title,
                accountDetail: model.accountPresentation.detail,
                accountID: model.accountPresentation.accountID
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
        } detail: {
            RootView(model: model, onModelStateChanged: onModelStateChanged)
                // Sidebar keeps the host's titlebar inset. The reading
                // surface alone reaches the physical top for its fade.
                .ignoresSafeArea(.container, edges: .top)
        }
        .background {
            MainSplitVisibilityBridge {
                toggleSidebar()
            }
            .frame(width: 0, height: 0)
        }
        .overlay(alignment: .topLeading) {
            FrameDeliveryProbe(capability: model.debugModules)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onChange(of: columnVisibility) { _, visibility in
            guard model.phase == .ready else { return }
            readyVisibility = visibility
        }
    }



    private func toggleSidebar() {
        guard model.phase == .ready else { return }
        withAnimation(.snappy(duration: 0.24, extraBounce: 0)) {
            columnVisibility = columnVisibility == .detailOnly
                ? readyVisibility == .detailOnly ? .all : readyVisibility
                : .detailOnly
        }
    }

    private func synchronizeVisibility(for phase: AppModel.Phase) {
        switch phase {
        case .ready:
            guard !wasReady else { return }
            wasReady = true
            withAnimation(.snappy(duration: 0.24, extraBounce: 0)) {
                columnVisibility = readyVisibility == .detailOnly ? .all : readyVisibility
            }
        case .signedOut, .connecting, .failed:
            if wasReady {
                readyVisibility = columnVisibility
                wasReady = false
            }
            withAnimation(.snappy(duration: 0.24, extraBounce: 0)) {
                columnVisibility = .detailOnly
            }
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
