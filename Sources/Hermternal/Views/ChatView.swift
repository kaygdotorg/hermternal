import SwiftUI
import HermternalCore
import AppKit

struct ChatView: View {
    @Bindable var model: AppModel
    @State private var pendingScrollTask: Task<Void, Never>?
    @State private var isFindPresented = false
    @State private var findQuery = ""
    @State private var activeFindIndex = 0

    var body: some View {
        transcript
            // safeAreaInset keeps the last message clear of the composer at
            // rest while still letting content scroll underneath it, which a
            // docked VStack row cannot do.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Composer(model: model)
                    .background { Self.composerHalo }
            }
        // Declared on the detail, not the sidebar column: only the window
        // toolbar region groups adjacent items into one shared pill.
        .toolbar {
            // Reserve the native principal slot without drawing a duplicate
            // window title; the traffic lights and toolbar remain native.
            ToolbarItem(placement: .principal) {
                EmptyView()
            }
            if !model.isSearchPresented {
                ToolbarItemGroup {
                    Button {
                        Task { await model.newChat() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New chat")
                    .keyboardShortcut("n", modifiers: .command)

                    Button {
                        Task { await model.loadSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload the chat list from the server")
                }
            }
        }
        .focusedSceneValue(\.hermternalFindAction, { openFind() })
        .onChange(of: findQuery) {
            activeFindIndex = 0
        }
        .onChange(of: model.selectedSessionID) {
            closeFind()
        }
    }

    private var findMatches: [TranscriptMatch] {
        TranscriptMatcher.matches(
            in: model.messages.map(\.text),
            query: findQuery
        )
    }

    private var activeFindMatch: TranscriptMatch? {
        guard findMatches.indices.contains(activeFindIndex) else { return nil }
        return findMatches[activeFindIndex]
    }

    private func openFind() {
        isFindPresented = true
        activeFindIndex = 0
    }

    private func closeFind() {
        isFindPresented = false
        findQuery = ""
        activeFindIndex = 0
    }

    private func advanceFind(by delta: Int) {
        let count = findMatches.count
        guard count > 0 else { return }
        activeFindIndex = (activeFindIndex + delta + count) % count
    }

    private func activateFindMatch(using proxy: ScrollViewProxy) {
        guard isFindPresented, let match = activeFindMatch,
              model.messages.indices.contains(match.messageIndex)
        else { return }
        pendingScrollTask?.cancel()
        pendingScrollTask = nil
        withAnimation(.easeInOut(duration: 0.28)) {
            proxy.scrollTo(model.messages[match.messageIndex].id, anchor: .center)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.messages.isEmpty {
                        EmptyState()
                            .padding(.top, 80)
                    }
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(
                            message: message,
                            sessionID: model.selectedSessionID,
                            gatewayHost: model.configuredGatewayHost,
                            findQuery: isFindPresented ? findQuery : "",
                            isFindActive: isFindPresented && activeFindMatch?.messageIndex == index
                        )
                        .id(message.id)
                    }
                    // Zero-height anchor: scrolling to the last message id
                    // lands short while its own height is still growing.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .top) { Self.topFade }
            .overlay(alignment: .top) {
                if isFindPresented {
                    FindBar(
                        query: $findQuery,
                        matchCount: findMatches.count,
                        selectedMatchNumber: activeFindMatch.map { findMatches.firstIndex(of: $0)! + 1 },
                        next: { advanceFind(by: 1) },
                        previous: { advanceFind(by: -1) },
                        close: closeFind
                    )
                    .padding(.top, 12)
                    .padding(.horizontal, 18)
                }
            }
            .onChange(of: model.pendingMessageLocation) {
                _ = consumePendingMessageTarget(using: proxy)
            }
            .onChange(of: isFindPresented) {
                activateFindMatch(using: proxy)
            }
            .onChange(of: findQuery) {
                activateFindMatch(using: proxy)
            }
            .onChange(of: activeFindIndex) {
                activateFindMatch(using: proxy)
            }
            .onChange(of: model.messages.last?.text) {
                guard !consumePendingMessageTarget(using: proxy) else { return }
                guard !isFindPresented else { return }
                guard pendingScrollTask == nil else { return }
                pendingScrollTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .milliseconds(20))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    pendingScrollTask = nil
                }
            }
            .onChange(of: model.messages.count) { oldCount, newCount in
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
                guard !consumePendingMessageTarget(using: proxy) else { return }
                guard !isFindPresented else { return }

                if newCount == oldCount + 1 {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onAppear {
                _ = consumePendingMessageTarget(using: proxy)
            }
            .onDisappear {
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
            }
        }
    }
    /// Consume a routed target only once its durable row is in the transcript.
    /// The animated scroll is intentional: non-animated scrolling can fail
    /// silently for variable-height LazyVStack rows.
    @MainActor
    private func consumePendingMessageTarget(using proxy: ScrollViewProxy) -> Bool {
        guard let location = model.pendingMessageLocation,
              model.selectedSessionID == location.sessionID,
              model.messages.contains(where: {
                  $0.id == .server(location.messageID)
              })
        else { return false }

        pendingScrollTask?.cancel()
        pendingScrollTask = nil
        model.pendingMessageLocation = nil
        withAnimation(.easeInOut(duration: 0.28)) {
            proxy.scrollTo(
                MessageIdentity.server(location.messageID),
                anchor: .center
            )
        }
        return true
    }

    /// Hiding the toolbar backing is what makes the titlebar glass, but it
    /// also removes the built-in scroll edge effect, so the progressive blur
    /// is drawn here instead.
    ///
    /// One masked material rather than stacked bands: a gradient mask fades
    /// continuously, so there are no seams between opacity steps. The stops
    /// are weighted toward the top so the tail is long and the falloff stays
    /// gentle instead of ending on a visible line.
    private static var topFade: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.75), location: 0.30),
                        .init(color: .black.opacity(0.35), location: 0.55),
                        .init(color: .black.opacity(0.12), location: 0.76),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: 130)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }

    /// The soft pocket the composer sits in: a fixed ramp above it, then
    /// solid material from the capsule down to the window edge. Expressed in
    /// points rather than gradient stops so the ramp height stays put no
    /// matter how tall the composer grows.
    private static var composerHalo: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(height: Self.haloRamp)
            Rectangle()
                .fill(.ultraThinMaterial)
        }
        .padding(.top, -Self.haloRamp)
        .allowsHitTesting(false)
    }

    private static let haloRamp: CGFloat = 34

    private static let bottomAnchor = "transcript.bottom"
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            hermesMark
            Text("Ask Hermes anything")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var hermesMark: some View {
        if let path = Bundle.main.path(forResource: "HermesIcon", ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Hermes")
        } else {
            Text("Hermes")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Hermes")
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let sessionID: String?
    let gatewayHost: String?
    let findQuery: String
    let isFindActive: Bool

    var body: some View {
        rowContent
            .contextMenu {
                if let gatewayHost,
                   let sessionID,
                   let link = MessageDeepLink(
                       gatewayHost: gatewayHost,
                       sessionID: sessionID,
                       messageIdentity: message.id
                   ) {
                    Button("Copy Message Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            link.url.absoluteString,
                            forType: .string
                        )
                    }
                }
            }
    }

    @ViewBuilder
    private var rowContent: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                if findQuery.isEmpty {
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            .tint.opacity(0.16),
                            in: .rect(
                                cornerRadius: AppShapeScale.toast,
                                style: .continuous
                            )
                        )
                } else {
                    FindHighlightedMessage(
                        text: message.text,
                        isStreaming: false,
                        query: findQuery,
                        isActive: isFindActive
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        .tint.opacity(0.16),
                        in: .rect(
                            cornerRadius: AppShapeScale.toast,
                            style: .continuous
                        )
                    )
                }
            }
        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .frame(width: 16)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 6) {
                    if findQuery.isEmpty {
                        MarkdownMessage(text: message.text, isStreaming: message.isStreaming)
                    } else {
                        FindHighlightedMessage(
                            text: message.text,
                            isStreaming: message.isStreaming,
                            query: findQuery,
                            isActive: isFindActive
                        )
                    }
                    if message.isStreaming && message.text.isEmpty {
                        ThinkingIndicator()
                    }
                }
                Spacer(minLength: 40)
            }
        case .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(
                    isFindActive ? Color.orange.opacity(0.12) : .clear,
                    in: .rect(
                        cornerRadius: AppShapeScale.compact,
                        style: .continuous
                    )
                )
        }
    }
}

/// Shown only before the first token lands, so an empty bubble never sits
/// there looking stalled.
private struct ThinkingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 5, height: 5)
                    .foregroundStyle(.secondary)
                    .opacity(0.35 + 0.65 * abs(sin(phase + Double(index) * 0.6)))
            }
        }
        .task {
            // A timer beats a repeatForever animation here: it stops cleanly
            // when the row is replaced by real text.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(90))
                phase += 0.22
            }
        }
    }
}

private struct Composer: View {
    @Bindable var model: AppModel
    @FocusState private var isFocused: Bool
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Hermes…", text: $model.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .onSubmit { send() }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("field", in: glass)

                Button {
                    if model.isAwaitingReply {
                        Task { await model.interrupt() }
                    } else {
                        send()
                    }
                } label: {
                    Image(systemName: model.isAwaitingReply ? "stop.fill" : "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .clipShape(.circle)
                .glassEffectID("send", in: glass)
                .disabled(!model.isAwaitingReply && model.composerText.isEmptyAfterTrim)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .onAppear { isFocused = true }
    }
    private func send() {
        Task { await model.send() }
    }
}

/// Hides only the title text while leaving the native titlebar and traffic
/// lights intact. A hidden-titlebar window style would remove those controls.
struct HiddenWindowTitle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowTitleHider {
        WindowTitleHider()
    }

    func updateNSView(_ nsView: WindowTitleHider, context: Context) {
        nsView.hideTitle()
    }
}

final class WindowTitleHider: NSView {
    fileprivate func hideTitle() {
        guard let window else { return }
        window.title = ""
        window.titleVisibility = .hidden
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideTitle()
        // SwiftUI may install the unified toolbar after the representable
        // joins the window; re-apply once that titlebar update has settled.
        DispatchQueue.main.async { [weak self] in
            self?.hideTitle()
        }
    }
}

private extension String {
    var isEmptyAfterTrim: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
