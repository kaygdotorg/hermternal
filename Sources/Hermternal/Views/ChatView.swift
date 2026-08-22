import SwiftUI
import HermternalCore
import AppKit

struct ChatView: View {
    @Bindable var model: AppModel
    @State private var pendingScrollTask: Task<Void, Never>?

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

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.messages.isEmpty {
                        EmptyState()
                            .padding(.top, 80)
                    }
                    ForEach(model.messages) { message in
                        MessageRow(message: message)
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
            .onChange(of: model.messages.last?.text) {
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

                if newCount == oldCount + 1 {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onDisappear {
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
            }
        }
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

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.tint.opacity(0.16), in: .rect(cornerRadius: 14))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .frame(width: 16)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 6) {
                    MarkdownMessage(text: message.text, isStreaming: message.isStreaming)
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

private extension String {
    var isEmptyAfterTrim: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
