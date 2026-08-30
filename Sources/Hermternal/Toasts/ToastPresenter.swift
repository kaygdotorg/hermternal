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
    @ObservationIgnored private let observers = ToastObservers()
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
        // Registrations outlive the presenter otherwise, and a presenter can
        // arrive through the `AppModel` injection seam and then be replaced.
        observers.removeAll()
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

    private func apply(_ effects: ToastQueueEffects) {
        entries = queue.entries
        for removal in effects.removed {
            actions.removeValue(forKey: removal.id)
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
            [entry.message.severity.spokenWord, entry.message.title, entry.message.detail]
                .compactMap { $0 }
                .joined(separator: ". ")
        )
        text.accessibilitySpeechAnnouncementPriority =
            entry.message.severity == .error ? .high : .default
        AccessibilityNotification.Announcement(text).post()
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
        observers.add(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setAppActive(false) }
        })
        observers.add(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setAppActive(true) }
        })
        observers.add(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // The notification names the window that changed. `NSApp.keyWindow`
            // samples a different window, and with no key window at all its
            // fallback kept expiring toasts behind a window nobody could see.
            guard let visible = (notification.object as? NSWindow)?
                .occlusionState.contains(.visible) else { return }
            Task { @MainActor [weak self] in self?.setWindowVisible(visible) }
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

/// The notification tokens of one presenter.
///
/// A `deinit` is not main-actor isolated, and under strict concurrency it may
/// not read a property whose type is not `Sendable`. The tokens therefore live
/// behind a reference the `deinit` may read. The claim is exact: they are
/// written while the presenter is built and read once while it is torn down,
/// when no other reference to it survives.
private final class ToastObservers: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    func removeAll() {
        let center = NotificationCenter.default
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
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

/// The animation vocabulary of the toast surface.
///
/// Springs, not keyframes: a keyframe timeline restarts at its first frame, so
/// a second toast 80 ms later makes the first one jump. A spring driven by
/// `.animation(_:value:)` retargets from the value on screen and blends the
/// current velocity into the new spring. `duration` is the response and
/// `bounce` is `1 - dampingRatio`, so `bounce: 0` is critically damped.
///
/// No curve here eases in. An ease-in holds still through the first third of
/// its duration, which is the moment the user watches hardest after acting.
enum ToastMotion {
    /// An arrival volunteers, so it may take its time.
    static let enter = Animation.spring(duration: 0.40, bounce: 0.16)

    /// A dismissal answers the user, so it is half of the arrival.
    static let exit = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.20)

    /// A card moving to a new depth.
    static let restack = Animation.spring(duration: 0.34, bounce: 0.10)

    /// The hover expansion. Critically damped, because a stack that overshoots
    /// under the pointer reads as a wobble rather than as a reveal.
    static let expand = Animation.spring(duration: 0.30, bounce: 0.0)

    /// A restored drag earns its bounce: a momentum gesture preceded it.
    static let settle = Animation.spring(duration: 0.32, bounce: 0.22)

    /// A flick already supplied the velocity, so the hand-off must not stall.
    static let fling = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)

    /// A title or detail changing inside a card that stays.
    static let content = Animation.easeOut(duration: 0.16)

    /// Reduced motion keeps every opacity and colour change and drops only the
    /// positional part, so these are shorter but never absent. Writing
    /// `.animation(nil, …)` instead would remove the whole subtree
    /// transaction, including the fades that have to stay.
    static let reducedEnter = Animation.easeOut(duration: 0.16)
    static let reducedExit = Animation.easeOut(duration: 0.12)
    static let reducedRestack = Animation.easeInOut(duration: 0.18)
}

extension ToastSeverity {
    /// The word VoiceOver speaks before the title.
    var spokenWord: String {
        switch self {
        case .success: "Success"
        case .info: "Information"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    var iconName: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    /// Depends on the severity and the contrast setting alone, so it belongs
    /// to the severity rather than to a card instance.
    func iconTint(increasedContrast: Bool) -> Color {
        switch self {
        case .success: .green
        case .info: increasedContrast ? .primary : .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

// A custom surface, by exception to the native-first rule in AGENTS.md.
//
// Neither SwiftUI nor AppKit ships a stacking transient-notification surface
// on macOS. Every system alternative was ruled out on a concrete ground:
// `UNUserNotificationCenter` is an OS surface that needs authorisation,
// outlives the app, is coalesced by the OS, is suppressed by Do Not Disturb,
// and cannot host a button that mutates app state; `.alert` and
// `.confirmationDialog` block and demand acknowledgement; `.sheet` and
// `.popover` present one at a time with no queue; a toolbar `ProgressView`
// would violate the rule that every progress indicator track work actually in
// flight, because a toast is not work in flight.
//
// Measured need: five call sites today in `AppModel` and `HermternalApp`, plus
// the archive Undo and the Delete Folder notice in the sidebar plan. The Undo
// is the decisive one: it needs a transient in-window surface that carries a
// button which mutates app state.
//
/// The AppKit host uses this callback to pass pointer events through every
/// transparent part of the overlay. The rectangle is in the ToastLayer's
/// top-left SwiftUI coordinate space.
typealias ToastLayerHitRegionReporter = @MainActor (CGRect?) -> Void

// Only the stack arithmetic and the drag gesture are app-owned. The material,
// the radius, the symbols, the action button, the context menu, the
// presentation and the VoiceOver announcement are all system components.
//
// Approved by the user, who asked for Sonner's stacking behaviour directly.
struct ToastLayer: View {
    @Environment(ToastPresenter.self) private var presenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let reportHitRegion: ToastLayerHitRegionReporter?

    init(reportHitRegion: ToastLayerHitRegionReporter? = nil) {
        self.reportHitRegion = reportHitRegion
    }

    /// The one measured-height store. It is pruned whenever the entries
    /// change, because toast ids are fresh UUIDs and an unpruned store grows
    /// for the whole process lifetime.
    @State private var heights: [ToastID: CGFloat] = [:]
    @State private var hovering = false

    var body: some View {
        if presenter.entries.isEmpty || presenter.isSuppressed {
            Color.clear
                .onAppear { reportHitRegion?(nil) }
                .onDisappear { reportHitRegion?(nil) }
        } else {
            GeometryReader { geometry in
                stack(in: geometry.size)
            }
        }
    }

    @ViewBuilder
    private func stack(in container: CGSize) -> some View {
        let rendered = Array(presenter.entries.prefix(ToastStackGeometry.renderedLimit))
        let measured = rendered.map { measuredHeight(of: $0.id) }
        let expandedHeight = ToastStackGeometry.expandedHeight(of: measured)
        // Expansion is declined when it would not fit. Declining is honest;
        // clipping a half-expanded stack is a visual lie.
        let isExpanded = hovering
            && expandedHeight <= Double(SearchSurfaceGeometry.maximumHeight(in: container.height))
        let region = ToastStackGeometry.regionHeight(of: measured, expanded: isExpanded)
        let width = CGFloat(ToastStackGeometry.width(in: Double(container.width)))
        let topInset = SearchSurfaceGeometry.topInset(in: container.height)
        let hitRegion = CGRect(
            x: (container.width - width) / 2,
            y: topInset,
            width: width,
            height: CGFloat(region)
        )
        let frontHeight = measured.first ?? ToastStackGeometry.estimatedCardHeight
        let transition = AnyTransition.asymmetric(insertion: insertion, removal: removal)

        ZStack(alignment: .top) {
            ForEach(Array(rendered.enumerated()), id: \.element.id) { depth, entry in
                ToastCard(
                    entry: entry,
                    depth: depth,
                    stackOffset: CGFloat(offset(depth: depth, in: measured, expanded: isExpanded)),
                    isExpanded: isExpanded,
                    reduceMotion: reduceMotion,
                    reduceTransparency: reduceTransparency,
                    presenter: presenter,
                    width: width,
                    flingDistance: CGFloat(
                        frontHeight + ToastStackGeometry.gap + ToastStackGeometry.flingHeadroom
                    ),
                    uniformHeight: depth > 0 && !isExpanded ? CGFloat(frontHeight) : nil,
                    measure: { heights[entry.id] = $0 }
                )
                .transition(transition)
            }
        }
        // The transaction that carries the insertion. Entry timing must not
        // depend on a height coincidence, so it watches the entry count and
        // nothing else. It is applied inside the frame below, which must never
        // animate.
        .animation(
            reduceMotion ? ToastMotion.reducedEnter : ToastMotion.enter,
            value: presenter.entries.count
        )
        // Layout is set once per state change and is never animated: the
        // expansion the user sees comes from the card offsets, which
        // composite. Animating a height instead relayouts the stack and every
        // card in it on every frame.
        .frame(width: width, height: CGFloat(region), alignment: .top)
        // `contentShape` plus `onHover` on the container rather than on the
        // cards, so a pointer crossing a gap keeps the stack expanded. This is
        // the native answer to Sonner's `:after` pseudo-elements, and the
        // region is exactly what is visible, never an invisible hit area.
        .contentShape(Rectangle())
        .onHover { isInside in
            hovering = isInside
            presenter.setHovering(isInside)
        }
        .focusSection()
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, topInset)
        .onAppear { reportHitRegion?(hitRegion) }
        .onChange(of: hitRegion) { _, region in
            reportHitRegion?(region)
        }
        .onDisappear { reportHitRegion?(nil) }
        .onChange(of: presenter.entries) { _, entries in
            let kept = ToastStackGeometry.pruned(heights, keeping: entries.lazy.map(\.id))
            guard kept.count != heights.count else { return }
            heights = kept
        }
    }


    private func measuredHeight(of id: ToastID) -> Double {
        guard let height = heights[id] else { return ToastStackGeometry.estimatedCardHeight }
        return Double(height)
    }

    /// Computed once per layer body and handed to the card as a value, so no
    /// card body observes `presenter.entries`. One insert would otherwise
    /// invalidate every card body and make each redo this sum during layout.
    private func offset(depth: Int, in measured: [Double], expanded: Bool) -> Double {
        expanded
            ? ToastStackGeometry.expandedOffset(depth: depth, heights: measured)
            : ToastStackGeometry.collapsedOffset(depth: depth)
    }

    /// A card materialises with a subtle scale rather than sliding in flat.
    /// `0.94` reads as arrival and is far from `scale(0)`: nothing appears out
    /// of nothing. The `.top` anchor matches the depth-scale anchor, so the two
    /// compose instead of fighting.
    private var insertion: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .scale(scale: CGFloat(ToastStackGeometry.enterScale), anchor: .top)
            .combined(with: .offset(y: CGFloat(ToastStackGeometry.enterOffset)))
            .combined(with: .opacity)
    }

    /// The exit carries its own animation, because the ambient transaction
    /// carries the arrival timing and the two must not be symmetric.
    private var removal: AnyTransition {
        let transition: AnyTransition = reduceMotion
            ? .opacity
            : .offset(y: CGFloat(ToastStackGeometry.exitOffset)).combined(with: .opacity)
        return transition.animation(reduceMotion ? ToastMotion.reducedExit : ToastMotion.exit)
    }
}

private struct ToastCard: View {
    let entry: ToastEntry
    let depth: Int
    let stackOffset: CGFloat
    let isExpanded: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let presenter: ToastPresenter
    let width: CGFloat
    let flingDistance: CGFloat

    /// The height the card takes in the collapsed stack, where every card
    /// adopts the front height, or `nil` for the front card and for the
    /// expanded stack, where each card takes its own.
    let uniformHeight: CGFloat?

    /// Reports the card's own height to the one height store in the layer.
    let measure: (CGFloat) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.hermternalAccentColor) private var accentColor

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// `@State`, not `@GestureState`: a released drag must travel to a chosen
    /// target with a chosen spring, and `@GestureState` restores itself with
    /// neither.
    @State private var dragTranslation: CGFloat = 0
    @State private var dragStart: ContinuousClock.Instant?

    private var showsClose: Bool {
        isHovering || entry.isPersistent || isFocused
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.message.severity.iconName)
                .font(.system(size: 15))
                .symbolRenderingMode(contrast == .increased ? .monochrome : .hierarchical)
                .foregroundStyle(entry.message.severity.iconTint(increasedContrast: contrast == .increased))
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
        .modifier(
            ToastPlate(
                uniformHeight: uniformHeight,
                isOpaque: reduceTransparency,
                showsPlate: depth > 0 && !isExpanded,
                borderColor: borderColor,
                borderWidth: borderWidth,
                shadowOpacity: shadowOpacity,
                measure: measure
            )
        )
        .modifier(
            ToastStackPresentation(
                depth: depth,
                isExpanded: isExpanded,
                stackOffset: stackOffset,
                dragOffset: reduceMotion ? 0 : dragTranslation,
                dragFeedbackOpacity: dragFeedbackOpacity,
                depthScale: CGFloat(
                    ToastStackGeometry.depthScale(depth: depth, reduceMotion: reduceMotion)
                ),
                depthOpacity: ToastStackGeometry.depthOpacity(
                    depth: depth, reduceMotion: reduceMotion
                ),
                expandAnimation: reduceMotion ? ToastMotion.reducedRestack : ToastMotion.expand,
                restackAnimation: reduceMotion ? ToastMotion.reducedRestack : ToastMotion.restack
            )
        )
        .modifier(
            ToastInteraction(
                presenter: presenter,
                entry: entry,
                reduceMotion: reduceMotion,
                flingDistance: flingDistance,
                isHovering: $isHovering,
                isFocused: $isFocused,
                dragTranslation: $dragTranslation,
                dragStart: $dragStart
            )
        )
        .modifier(
            ToastAccessibility(
                presenter: presenter,
                entry: entry,
                severityWord: entry.message.severity.spokenWord
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
        isFocused ? accentColor : Color(nsColor: .separatorColor)
    }

    private var borderWidth: CGFloat {
        if isFocused { return 2 }
        return contrast == .increased ? 1 : 0.5
    }

    /// Two shadow passes per card is six passes for a three-card stack, and
    /// five of them are hidden behind the card in front. A shadow with no
    /// alpha is not drawn.
    private var shadowOpacity: Double {
        guard depth == 0 || isExpanded else { return 0 }
        return colorScheme == .dark ? 0.42 : 0.18
    }

    /// Under reduced motion the card reports drag progress by fading rather
    /// than by moving. The same thresholds still decide the dismissal, so only
    /// the rendering is non-positional, and a fade is a colour change, which
    /// reduced motion keeps.
    private var dragFeedbackOpacity: Double {
        guard reduceMotion else { return 1 }
        return ToastStackGeometry.dragFeedbackOpacity(travel: Double(-dragTranslation))
    }
}

/// The card surface: one material, with an opaque plate under it.
///
/// A `Material` is behind-window vibrancy. Two cards that overlap therefore
/// put two materials over the same desktop pixels, and the overlap gets twice
/// the vibrancy of a single card. A card behind the front card gets an opaque
/// plate, which keeps one material over each pixel. The plate is invisible
/// inside the 14 pt sliver, and its opacity change is a colour transition,
/// which reduced motion keeps. `accessibilityReduceTransparency` replaces the
/// material with the plate alone.
private struct ToastSurface: View {
    let isOpaque: Bool
    let showsPlate: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppShapeScale.toast, style: .continuous)
        ZStack {
            shape
                .fill(Color(nsColor: .controlBackgroundColor))
                .opacity(isOpaque || showsPlate ? 1 : 0)
                .animation(ToastMotion.content, value: showsPlate)
            if !isOpaque {
                shape.fill(.thickMaterial)
            }
        }
    }
}

// MARK: - Card modifiers
//
// The card applies roughly two dozen modifiers. Swift type-checks a modifier
// chain as a single expression, and at that length it exceeds its budget and
// fails to compile. Grouping them into `ViewModifier` values keeps each body
// small enough to infer immediately, with no `AnyView` and no behaviour lost.

private struct ToastPlate: ViewModifier {
    let uniformHeight: CGFloat?
    let isOpaque: Bool
    let showsPlate: Bool
    let borderColor: Color
    let borderWidth: CGFloat
    let shadowOpacity: Double
    let measure: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content
            // Measured before the uniform height below it, so the height store
            // keeps the card's own height and the expanded offsets stay
            // correct. One modifier, where a `GeometryReader` needed one extra
            // layout container and one `Color.clear` view per card.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: measure)
            .frame(height: uniformHeight, alignment: .top)
            .background {
                ToastSurface(isOpaque: isOpaque, showsPlate: showsPlate)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppShapeScale.toast, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            }
            // Concentric by construction: the clip is the card's own shape at
            // the card's own frame, so it can never disagree with the card
            // radius. It is also what makes the uniform height visible, by
            // holding a taller card inside its sliver. The shadows are applied
            // after it, so the clip cannot crop them.
            .clipShape(RoundedRectangle(cornerRadius: AppShapeScale.toast, style: .continuous))
            .shadow(color: .black.opacity(shadowOpacity), radius: 14, y: 8)
            .shadow(color: .black.opacity(shadowOpacity > 0 ? 0.10 : 0), radius: 1, y: 0.5)
    }
}

private struct ToastStackPresentation: ViewModifier {
    let depth: Int
    let isExpanded: Bool
    let stackOffset: CGFloat
    let dragOffset: CGFloat
    let dragFeedbackOpacity: Double
    let depthScale: CGFloat
    let depthOpacity: Double
    let expandAnimation: Animation
    let restackAnimation: Animation

    func body(content: Content) -> some View {
        content
            // One animatable scalar for the whole card. A spring retargets
            // from the value on screen and blends the velocity it already has
            // into the new spring, so a burst of toasts never jumps.
            // Splitting this into two offsets would break that blend.
            .offset(y: stackOffset + dragOffset)
            .scaleEffect(depthScale, anchor: .top)
            .opacity(depthOpacity)
            .zIndex(Double(-depth))
            .geometryGroup()
            // Each watcher names the cause rather than the property: hover
            // expands, a new depth restacks. Both retarget the same offset.
            .animation(expandAnimation, value: isExpanded)
            .animation(restackAnimation, value: depth)
            // Outside every watcher: a live drag has to track the pointer with
            // no animation at all, and its release picks its own.
            .opacity(dragFeedbackOpacity)
    }
}

private struct ToastInteraction: ViewModifier {
    let presenter: ToastPresenter
    let entry: ToastEntry
    let reduceMotion: Bool
    let flingDistance: CGFloat
    @Binding var isHovering: Bool
    @FocusState.Binding var isFocused: Bool
    @Binding var dragTranslation: CGFloat
    @Binding var dragStart: ContinuousClock.Instant?

    func body(content: Content) -> some View {
        content
            .gesture(dismissGesture)
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

    /// Swipe to dismiss, decided by momentum rather than by distance alone.
    ///
    /// `minimumDistance: 4` is the hysteresis that keeps a click from becoming
    /// a drag. Neither of Sonner's manual fixes is needed: `DragGesture` keeps
    /// delivering to this card after the pointer leaves it, and SwiftUI
    /// already binds the recognizer to the first pointer sequence.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if dragStart == nil {
                    // A gesture is wall-clock time, so this is
                    // `ContinuousClock` and not the queue's `SuspendingClock`.
                    // The two are deliberately different clocks.
                    dragStart = ContinuousClock.now
                    presenter.setDragging(true)
                }
                dragTranslation = CGFloat(
                    ToastSwipeThresholds.default.resisted(Double(value.translation.height))
                )
            }
            .onEnded { value in
                let elapsed = dragStart?.duration(to: ContinuousClock.now) ?? .zero
                dragStart = nil
                presenter.setDragging(false)
                let swipe = ToastSwipe(
                    travel: Double(-value.translation.height),
                    projectedTravel: Double(-value.predictedEndTranslation.height),
                    elapsed: elapsed
                )
                switch toastSwipeOutcome(swipe) {
                case .dismiss:
                    // Hand the momentum on rather than fading in place. The
                    // completion removes the entry, so no timer is involved.
                    withAnimation(reduceMotion ? ToastMotion.reducedExit : ToastMotion.fling) {
                        dragTranslation = -flingDistance
                    } completion: {
                        presenter.dismiss(entry.id)
                    }
                case .restore:
                    withAnimation(reduceMotion ? ToastMotion.reducedRestack : ToastMotion.settle) {
                        dragTranslation = 0
                    }
                }
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
