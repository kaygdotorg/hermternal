import AppKit
import HermternalCore
import Observation
import SwiftUI

@MainActor
@Observable
final class ToastPresenter {
    private(set) var entries: [ToastEntry] = []

    @ObservationIgnored private var queue: ToastQueue
    @ObservationIgnored private var actions: [ToastID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private var appActive = true
    @ObservationIgnored private var windowVisible = true
    @ObservationIgnored private var dragging = false
    @ObservationIgnored private var suppressed = false
    @ObservationIgnored private var announcedIDs: Set<ToastID> = []
    init(policy: ToastPolicy = .default) {
        queue = ToastQueue(policy: policy)
        installObservers()
    }

    deinit {
        expiryTask?.cancel()
    }

    func post(_ message: ToastMessage, action: (@MainActor () -> Void)? = nil) {
        let effects = queue.post(message, at: .now)
        apply(effects)
        if let action {
            actions[message.id] = action
        } else {
            actions.removeValue(forKey: message.id)
        }
        rescheduleExpiry()
    }

    func dismiss(_ id: ToastID) {
        apply(queue.dismiss(id, at: .now))
        rescheduleExpiry()
    }

    func dismissFront() {
        apply(queue.dismissFront(at: .now))
        rescheduleExpiry()
    }

    func dismissAll() {
        apply(queue.dismissAll(at: .now))
        rescheduleExpiry()
    }

    func setHovering(_ hovering: Bool) {
        guard self.hovering != hovering else { return }
        self.hovering = hovering
        updatePause()
    }

    func setDragging(_ dragging: Bool) {
        guard self.dragging != dragging else { return }
        self.dragging = dragging
        updatePause()
    }

    func setAppActive(_ active: Bool) {
        guard appActive != active else { return }
        appActive = active
        updatePause()
    }

    func setWindowVisible(_ visible: Bool) {
        guard windowVisible != visible else { return }
        windowVisible = visible
        updatePause()
    }

    /// Search takes precedence over toasts without removing or expiring them.
    func setSuppressed(_ suppressed: Bool) {
        guard self.suppressed != suppressed else { return }
        self.suppressed = suppressed
        updatePause()
    }

    var isSuppressed: Bool {
        suppressed
    }

    func performAction(for id: ToastID) {
        guard let action = actions[id] else { return }
        dismiss(id)
        action()
    }

    func setHeight(_ height: CGFloat, for id: ToastID) {
        heights[id] = height
    }

    fileprivate func height(for id: ToastID) -> CGFloat? {
        heights[id]
    }

    @ObservationIgnored private var heights: [ToastID: CGFloat] = [:]

    private func apply(_ effects: ToastQueueEffects) {
        entries = queue.entries
        for removal in effects.removed {
            actions.removeValue(forKey: removal.id)
            heights.removeValue(forKey: removal.id)
            announcedIDs.remove(removal.id)
        }
        if let insertedID = effects.inserted,
           let inserted = entries.first(where: { $0.id == insertedID }),
           announcedIDs.insert(insertedID).inserted {
            announce(inserted)
        }
    }

    private func announce(_ entry: ToastEntry) {
        var text = AttributedString(
            [severityWord(for: entry.message.severity), entry.message.title, entry.message.detail]
                .compactMap { $0 }
                .joined(separator: ". ")
        )
        text.accessibilitySpeechAnnouncementPriority =
            entry.message.severity == .error ? .high : .default
        AccessibilityNotification.Announcement(text).post()
    }

    private func severityWord(for severity: ToastSeverity) -> String {
        switch severity {
        case .success: "Success"
        case .info: "Information"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    private func updatePause() {
        let now: ToastInstant = .now
        queue.setPaused(hovering, for: .hover, at: now)
        queue.setPaused(dragging, for: .dragging, at: now)
        queue.setPaused(!appActive, for: .appInactive, at: now)
        queue.setPaused(!windowVisible, for: .windowHidden, at: now)
        queue.setPaused(suppressed, for: .visibility, at: now)
        entries = queue.entries
        rescheduleExpiry()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setAppActive(false) }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setAppActive(true) }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let visible = NSApp.keyWindow?.occlusionState.contains(.visible) ?? true
                self.setWindowVisible(visible)
            }
        })
    }

    private func rescheduleExpiry() {
        expiryTask?.cancel()
        guard let deadline = queue.nextDeadline() else {
            expiryTask = nil
            return
        }
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: SuspendingClock())
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.apply(self.queue.tick(at: .now))
            self.rescheduleExpiry()
        }
    }
}

extension ToastPresenter {
    func success(_ title: String, id: ToastID = .unique(), detail: String? = nil) {
        post(ToastMessage(id: id, title: title, detail: detail, severity: .success))
    }

    func info(_ title: String, id: ToastID = .unique(), detail: String? = nil) {
        post(ToastMessage(id: id, title: title, detail: detail, severity: .info))
    }

    func warning(_ title: String, id: ToastID = .unique(), detail: String? = nil) {
        post(ToastMessage(id: id, title: title, detail: detail, severity: .warning))
    }

    func error(
        _ title: String,
        id: ToastID = .unique(),
        detail: String? = nil,
        actionLabel: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        post(
            ToastMessage(
                id: id,
                title: title,
                detail: detail,
                severity: .error,
                action: actionLabel.map(ToastAction.init(label:))
            ),
            action: action
        )
    }
}

extension ToastID {
    static func unique() -> ToastID { ToastID(UUID().uuidString) }

    static let sessionList = ToastID("session-list")
    static let cacheClear = ToastID("cache-clear")
    static let cacheRebuild = ToastID("cache-rebuild")
    static let newChat = ToastID("new-chat")
    static let sendFailed = ToastID("send-failed")
    static let stream = ToastID("stream")
    static let reconcile = ToastID("reconcile")
    static func transcript(_ id: String) -> ToastID { ToastID("transcript-\(id)") }
}

enum ToastMotion {
    static let enter = Animation.spring(duration: 0.40, bounce: 0.16)
    static let exit = Animation.timingCurve(0.4, 0.0, 1.0, 1.0, duration: 0.22)
    static let restack = Animation.spring(duration: 0.34, bounce: 0.10)
    static let expand = Animation.spring(duration: 0.30, bounce: 0.0)
    static let settle = Animation.spring(duration: 0.30, bounce: 0.20)
    static let fling = Animation.timingCurve(0.3, 0.0, 1.0, 1.0, duration: 0.18)
    static let content = Animation.easeOut(duration: 0.16)
    static let reducedEnter = Animation.easeOut(duration: 0.16)
    static let reducedExit = Animation.easeIn(duration: 0.12)
    static let reducedRestack = Animation.easeInOut(duration: 0.18)
}

struct ToastLayer: View {
    @Environment(ToastPresenter.self) private var presenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heights: [ToastID: CGFloat] = [:]
    @State private var expanded = false

    private let gap: CGFloat = 10
    var body: some View {
        if presenter.entries.isEmpty || presenter.isSuppressed {
            EmptyView()
        } else {
            GeometryReader { geometry in
                let toastWidth = min(360, max(0, geometry.size.width - 32))
                let frontHeight = heights[presenter.entries[0].id] ?? 70
                let expandedHeight = presenter.entries.reduce(CGFloat.zero) { partial, entry in
                    partial + (heights[entry.id] ?? frontHeight)
                } + gap * CGFloat(max(0, presenter.entries.count - 1))
                let regionHeight = expanded
                    ? expandedHeight
                    : frontHeight + gap * CGFloat(max(0, presenter.entries.count - 1))
                let availableHeight = SearchSurfaceGeometry.maximumHeight(in: geometry.size.height)

                ZStack(alignment: .top) {
                    ForEach(Array(presenter.entries.enumerated()), id: \.element.id) { index, entry in
                        ToastCard(
                            entry: entry,
                            depth: index,
                            frontHeight: frontHeight,
                            isExpanded: expanded,
                            reduceMotion: reduceMotion,
                            presenter: presenter,
                            width: toastWidth
                        )
                        .transition(.asymmetric(
                            insertion: reduceMotion
                                ? .opacity
                                : .offset(y: -20).combined(with: .opacity),
                            removal: reduceMotion
                                ? .opacity
                                : .offset(y: -12).combined(with: .opacity)
                        ))
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear {
                                        heights[entry.id] = proxy.size.height
                                        presenter.setHeight(proxy.size.height, for: entry.id)
                                    }
                                    .onChange(of: proxy.size.height) { _, height in
                                        heights[entry.id] = height
                                        presenter.setHeight(height, for: entry.id)
                                    }
                            }
                        }
                    }
                }
                .frame(width: toastWidth, height: min(regionHeight, availableHeight), alignment: .top)
                .clipShape(
                    RoundedRectangle(cornerRadius: AppShapeScale.card, style: .continuous)
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    expanded = hovering
                    presenter.setHovering(hovering)
                }
                .focusSection()
                .animation(
                    reduceMotion ? nil : ToastMotion.expand,
                    value: regionHeight
                )
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, SearchSurfaceGeometry.topInset(in: geometry.size.height))
            }
        }
    }
}

private struct ToastCard: View {
    let entry: ToastEntry
    let depth: Int
    let frontHeight: CGFloat
    let isExpanded: Bool
    let reduceMotion: Bool
    let presenter: ToastPresenter
    let width: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @GestureState private var dragOffset: CGFloat = 0

    private var showsClose: Bool {
        isHovering || entry.isPersistent || isFocused
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 15))
                .symbolRenderingMode(contrast == .increased ? .monochrome : .hierarchical)
                .foregroundStyle(iconTint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message.title)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? ToastMotion.reducedEnter : ToastMotion.content, value: entry.contentVersion)
                if let detail = entry.message.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let action = entry.message.action {
                Button(action.label) { presenter.performAction(for: entry.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            closeButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: width, alignment: .top)
        .frame(minHeight: 44, alignment: .top)
        .background(
            .thickMaterial,
            in: .rect(cornerRadius: AppShapeScale.toast, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppShapeScale.toast, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.18), radius: 14, y: 8)
        .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
        .modifier(
            ToastStackPresentation(
                reduceMotion: reduceMotion,
                depth: depth,
                stackOffset: stackOffset,
                dragOffset: dragOffset,
                depthScale: depthScale,
                depthOpacity: depthOpacity
            )
        )
        .modifier(
            ToastInteraction(
                presenter: presenter,
                entry: entry,
                isHovering: $isHovering,
                isFocused: $isFocused
            )
        )
        .modifier(
            ToastAccessibility(
                presenter: presenter,
                entry: entry,
                severityWord: severityWord
            )
        )
    }

    /// One concrete button rather than a `@ViewBuilder` either/or: an
    /// invisible control must not be focusable, and a `Color.clear`
    /// placeholder branch both changes view identity on every hover and
    /// pushes this expression past the type checker's budget.
    private var closeButton: some View {
        Button {
            presenter.dismiss(entry.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Dismiss")
        .opacity(showsClose ? 1 : 0)
        .disabled(!showsClose)
        .allowsHitTesting(showsClose)
        .accessibilityHidden(!showsClose)
        .animation(.easeOut(duration: 0.12), value: showsClose)
    }

    /// Split out of the `strokeBorder` call: a ternary mixing `Color` with a
    /// `ShapeStyle` such as `.separator` forces the compiler to unify two
    /// unrelated types inside an already large expression.
    private var borderColor: Color {
        isFocused ? .accentColor : Color(nsColor: .separatorColor)
    }

    private var borderWidth: CGFloat {
        if isFocused { return 2 }
        return contrast == .increased ? 1 : 0.5
    }



    private var stackOffset: CGFloat {
        if isExpanded {
            return presenter.entries.prefix(depth).reduce(CGFloat.zero) { partial, prior in
                partial + (presenter.height(for: prior.id) ?? frontHeight) + 10
            }
        }
        return CGFloat(depth * 10)
    }

    private var depthScale: CGFloat {
        reduceMotion ? 1 : 1 - CGFloat(depth) * 0.05
    }

    private var depthOpacity: Double {
        if depth == 0 { return 1 }
        if reduceMotion { return 0.78 }
        return depth < 2 ? 1 : 0.9
    }

    private var iconName: String {
        switch entry.message.severity {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var iconTint: Color {
        switch entry.message.severity {
        case .success: .green
        case .info: contrast == .increased ? .primary : .secondary
        case .warning: .orange
        case .error: .red
        }
    }

    private var severityWord: String {
        switch entry.message.severity {
        case .success: "Success"
        case .info: "Information"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { _ in presenter.setDragging(true) }
            .updating($dragOffset) { value, state, _ in
                state = Self.resist(value.translation.height)
            }
            .onEnded { value in
                presenter.setDragging(false)
                let travel = -value.translation.height
                let speed = -value.velocity.height
                let predicted = -value.predictedEndTranslation.height
                if travel >= 40 || predicted >= 40 || (speed >= 320 && travel >= 12) {
                    presenter.dismiss(entry.id)
                }
            }
    }

    private static func resist(_ translation: CGFloat) -> CGFloat {
        guard translation > 0 else { return translation }
        let limit: CGFloat = 36
        return limit * (1 - 1 / (translation / limit + 1))
    }
}

// MARK: - Card modifiers
//
// The card applies roughly two dozen modifiers. Swift type-checks a modifier
// chain as a single expression, and at that length it exceeds its budget and
// fails to compile. Grouping them into `ViewModifier` values keeps each body
// small enough to infer immediately, with no `AnyView` and no behaviour lost.

private struct ToastStackPresentation: ViewModifier {
    let reduceMotion: Bool
    let depth: Int
    let stackOffset: CGFloat
    let dragOffset: CGFloat
    let depthScale: CGFloat
    let depthOpacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: stackOffset + dragOffset)
            .scaleEffect(depthScale, anchor: .top)
            .opacity(depthOpacity)
            .zIndex(Double(-depth))
            .geometryGroup()
            .animation(reduceMotion ? nil : ToastMotion.restack, value: stackOffset)
            .animation(reduceMotion ? nil : ToastMotion.restack, value: depthScale)
            .animation(
                reduceMotion ? ToastMotion.reducedRestack : ToastMotion.restack,
                value: depthOpacity
            )
    }
}

private struct ToastInteraction: ViewModifier {
    let presenter: ToastPresenter
    let entry: ToastEntry
    @Binding var isHovering: Bool
    @FocusState.Binding var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .focusable()
            .focused($isFocused)
            .onKeyPress(.escape) {
                presenter.dismiss(entry.id)
                return .handled
            }
            .onKeyPress(.delete) {
                presenter.dismiss(entry.id)
                return .handled
            }
            .onKeyPress(.return) {
                guard entry.message.action != nil else { return .ignored }
                presenter.performAction(for: entry.id)
                return .handled
            }
    }
}

private struct ToastAccessibility: ViewModifier {
    let presenter: ToastPresenter
    let entry: ToastEntry
    let severityWord: String

    private var messageText: String {
        guard let detail = entry.message.detail else { return entry.message.title }
        return "\(entry.message.title)\n\(detail)"
    }

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(severityWord). \(entry.message.title)")
            .accessibilityValue(entry.message.detail ?? "")
            .accessibilityAction(named: "Dismiss") {
                presenter.dismiss(entry.id)
            }
            .accessibilityAction(named: entry.message.action?.label ?? "Action") {
                guard entry.message.action != nil else { return }
                presenter.performAction(for: entry.id)
            }
            .contextMenu {
                Button("Copy Message") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(messageText, forType: .string)
                }
            }
    }
}
