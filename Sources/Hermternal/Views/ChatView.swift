import SwiftUI

struct ChatView: View {
    @Bindable var model: AppModel
    @Bindable var appearance: AppearanceSettings

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Composer(model: model)
        }
        .glassSurface(intensity: appearance.chatGlass)
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.messages.last?.text) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: model.messages.count) {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "transcript.bottom"
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Ask Hermes anything")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Hermes…", text: $model.composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($isFocused)
                .onSubmit { send() }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Button {
                if model.isAwaitingReply {
                    Task { await model.interrupt() }
                } else {
                    send()
                }
            } label: {
                Image(systemName: model.isAwaitingReply ? "stop.fill" : "arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(.circle)
            .disabled(!model.isAwaitingReply && model.composerText.isEmptyAfterTrim)
            .padding(6)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
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
