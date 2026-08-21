import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Bindable var appearance: AppearanceSettings

    var body: some View {
        switch model.phase {
        case .signedOut:
            SignInView(model: model)
        case .connecting:
            ConnectingView()
        case .ready:
            ChatWindow(model: model, appearance: appearance)
        case .failed(let message):
            FailureView(message: message, model: model)
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
        .background(.background)
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
        .background(.background)
    }
}

struct ChatWindow: View {
    @Bindable var model: AppModel
    @Bindable var appearance: AppearanceSettings
    @State private var isSidebarVisible = true

    var body: some View {
        ZStack(alignment: .leading) {
            // The reading surface owns the whole window, including the
            // unified titlebar area; this removes the transparent top strip.
            ChatView(model: model, appearance: appearance)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            if isSidebarVisible {
                SidebarView(model: model, appearance: appearance)
                    .frame(width: 264)
                    .clipShape(.rect(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
                    .padding(.leading, 12)
                    .padding(.vertical, 10)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.snappy(duration: 0.24, extraBounce: 0)) {
                        isSidebarVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help(isSidebarVisible ? "Hide sidebar" : "Show sidebar")
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                NoticeBanner(text: notice) { model.notice = nil }
            }
        }
    }
}

/// Transient, dismissible problem report that must not replace the chat.
private struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
