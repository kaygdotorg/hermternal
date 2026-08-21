import AppKit
import SwiftUI

/// One persistent Tahoe glass host for the chat detail. The native sidebar,
/// titlebar, toolbar, and Settings window remain system-owned.
@MainActor
struct AdjustableChatSurface<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    func makeNSView(context: Context) -> ChatGlassEffectView {
        let glass = ChatGlassEffectView(frame: .zero)
        glass.style = .regular
        glass.cornerRadius = 0
        glass.tintColor = nil
        glass.contentView = context.coordinator.hosting
        return glass
    }

    func updateNSView(_ glass: ChatGlassEffectView, context: Context) {
        // App/model changes still replace the root value. Chat opacity is read
        // only by ChatOpacityVeil inside that root, so slider samples do not
        // invalidate this representable or reconcile the transcript.
        context.coordinator.hosting.rootView = content
    }

    static func dismantleNSView(_ nsView: ChatGlassEffectView, coordinator: Coordinator) {
        nsView.restoreWindow()
    }

    @MainActor
    final class Coordinator {
        let hosting: NSHostingView<Content>

        init(content: Content) {
            hosting = NSHostingView(rootView: content)
        }
    }
}

/// A plain semantic color layer inside the glass content tree. Observation is
/// deliberately local so live slider updates touch this layer, not ChatView.
private struct ChatOpacityVeil: View {
    @Bindable var appearance: AppearanceSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var effectiveOpacity: Double {
        let requested = min(max(appearance.chatOpacity, 0), 1)
        if reduceTransparency { return 1 }
        if contrast == .increased { return max(requested, 0.95) }
        return requested
    }

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .opacity(effectiveOpacity)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Places this native chat content over the locally-observed opacity veil.
    func chatOpacityVeil(_ appearance: AppearanceSettings) -> some View {
        ZStack {
            ChatOpacityVeil(appearance: appearance)
            self
        }
    }
}

@MainActor
final class ChatGlassEffectView: NSGlassEffectView {
    private weak var configuredWindow: NSWindow?
    private var originalIsOpaque: Bool?
    private var originalBackgroundColor: NSColor?
    private var originalSeparatorStyle: NSWindow.TitlebarSeparatorStyle?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            restoreWindow()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfNeeded()
    }

    private func configureWindowIfNeeded() {
        guard let window, configuredWindow !== window else { return }
        restoreWindow()
        configuredWindow = window
        originalIsOpaque = window.isOpaque
        originalBackgroundColor = window.backgroundColor
        originalSeparatorStyle = window.titlebarSeparatorStyle
        window.isOpaque = false
        window.backgroundColor = .clear
        // Remove the line that makes the detail read as a separate inner
        // panel while retaining native titlebar and toolbar behavior.
        window.titlebarSeparatorStyle = .none
    }
    func restoreWindow() {
        guard let window = configuredWindow else { return }
        if let originalIsOpaque { window.isOpaque = originalIsOpaque }
        window.backgroundColor = originalBackgroundColor
        if let originalSeparatorStyle { window.titlebarSeparatorStyle = originalSeparatorStyle }
        configuredWindow = nil
    }
}
