import AppKit
import Darwin
import SwiftUI

/// What sits behind the chat window's content.
///
/// Exactly one of these is ever active. They are alternatives, not layers.
/// Stacking them — a coloured fill under a vibrancy view, or a blur under
/// glass — is what put a second and a third tint over the same desktop pixels
/// and made this window read grey. Ghostty draws the same line: when glass is
/// on it skips the blur call outright.
enum WindowBackdropTreatment: Equatable {
    /// Solid window. No translucency, no blur, no glass, nothing to sample.
    case opaque

    /// The default. A translucent window over a real desktop blur, with the
    /// app background colour carrying the alpha.
    case blur

    /// The opt-in alternative. A translucent window over Liquid Glass, with
    /// the glass layer carrying the colour instead of the fill.
    ///
    /// The window's corner radius is part of the case because glass is the one
    /// treatment this app draws itself. The blur and the fill are the window's
    /// own background, so the frame view clips them to the window's rounded
    /// rectangle for nothing; a glass layer of ours is clipped by no one, and a
    /// full-bleed rectangle of it over a rounded window is the hard-edged plate
    /// this case exists to prevent. No shape, no glass.
    case glass(cornerRadius: CGFloat)
}

/// The resolved backdrop for one set of user choices.
///
/// Pure and total: the only place the inputs become a treatment, so "what is
/// behind the content right now" is a single testable function rather than a
/// rule spread across a view, a window, and a private API call.
struct WindowBackdropPlan: Equatable {
    /// How solid the background is. 1 hides the desktop; 0 leaves the fill
    /// fully clear, which still keeps the treatment's blur behind the content.
    let opacity: Double

    let treatment: WindowBackdropTreatment

    /// Alpha for the app background colour fill. Exactly one layer is ever
    /// tinted: in `blur` and `opaque` it is the fill, and in `glass` the fill
    /// steps aside because the glass layer carries the colour itself. This
    /// mirrors Ghostty's renderer, where the background clear colour takes the
    /// configured opacity and glass mode then drops that alpha to zero.
    var fillOpacity: Double {
        switch treatment {
        case .glass: 0
        case .blur, .opaque: opacity
        }
    }

    /// What a corner radius has to be before it is believed.
    ///
    /// The radius arrives from a private property, so a wrong number is a live
    /// possibility — and for the glass shape a wrong number is worse than no
    /// number, because it mis-clips into a seam along the window edge. macOS
    /// window radii have stayed in the low tens of points on every release
    /// that has them, so anything outside this range is read as "unavailable"
    /// and glass gives way to the blur, which the window clips for itself.
    private static let believableCornerRadii: ClosedRange<CGFloat> = 0...64

    init(
        opacity: Double,
        usesLiquidGlass: Bool,
        reduceTransparency: Bool,
        isFullScreen: Bool,
        windowCornerRadius: CGFloat?
    ) {
        // Three ways to end up solid, all of them correctness rather than
        // taste:
        //
        // * Reduce Transparency means solid. A half-faded window is precisely
        //   the stray haze the setting exists to remove, so it forces the
        //   opaque path: no translucency, no blur, no glass.
        // * Native fullscreen has no desktop behind it to blur. Translucency
        //   there turns the background grey and lets widgets show through,
        //   which is why Ghostty guards the same case with
        //   `!styleMask.contains(.fullScreen)`.
        // * A non-finite stored value resolves to the always-legible end
        //   rather than trapping or drawing an undefined alpha.
        guard !reduceTransparency, !isFullScreen, opacity.isFinite else {
            self.opacity = 1
            treatment = .opaque
            return
        }

        let clamped = min(max(opacity, 0), 1)
        self.opacity = clamped
        // Full opacity is a genuine fast path, not a rounding case. An opaque
        // window has nothing behind it to blur — Ghostty's blur call returns
        // early on the same condition — and a glass layer would only sample
        // the window's own fill.
        guard clamped < 1 else {
            treatment = .opaque
            return
        }

        // Glass needs the window's shape as much as it needs the user's tick.
        // With no radius to draw in, nothing stops it painting a square plate
        // over a rounded window, so the frosted blur — drawn by the window and
        // therefore clipped by it — is the honest answer rather than glass with
        // guessed corners.
        guard usesLiquidGlass,
              let windowCornerRadius,
              windowCornerRadius.isFinite,
              Self.believableCornerRadii.contains(windowCornerRadius)
        else {
            treatment = .blur
            return
        }
        treatment = .glass(cornerRadius: windowCornerRadius)
    }
}

/// The window background blur, resolved at runtime.
///
/// `CGSSetWindowBackgroundBlurRadius` is the only way to get a
/// radius-controlled blur behind a plainly coloured translucent window. No
/// public API offers it, which is why every terminal reaches for it,
/// Terminal.app included.
///
/// It is also private, and the tradeoff is worth stating exactly rather than
/// hiding. App Review guideline 2.5.1 requires public APIs, so this symbol is
/// an App Store rejection risk; notarisation is a malware and code-signing
/// scan and is not App Review. We ship notarised outside the App Store, so the
/// cost we actually carry is not review — it is OS fragility if the symbol
/// ever moves. That is exactly why it is resolved through `dlsym` and why the
/// public fallback below it is required rather than optional. Ghostty
/// extern-links the symbol with no runtime guard and marks even its own
/// wrapper "APIs I'd like to get rid of eventually… Don't use these unless you
/// know what you're doing"; we will not ship a window that silently loses its
/// background if that bet stops paying.
@MainActor
private enum WindowBackgroundBlur {
    /// Ghostty's plain `background-blur = true` maps to radius 20. Matching it
    /// keeps the default frost at the weight this class of window already
    /// reads as normal, and the dial deliberately does not scale it: opacity
    /// owns show-through, the blur is a treatment.
    static let defaultRadius: Int32 = 20

    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetBlurRadius = @convention(c) (Int32, UInt32, Int32) -> Int32

    private struct EntryPoints {
        let connection: DefaultConnection
        let setRadius: SetBlurRadius
    }

    /// Resolved once. `dlopen(nil, …)` asks the already-loaded global scope,
    /// so nothing new is loaded into the process; this only looks up two
    /// symbols that ship in CoreGraphics.
    private static let entryPoints: EntryPoints? = {
        guard let scope = dlopen(nil, RTLD_LAZY),
              let connection = dlsym(scope, "CGSDefaultConnectionForThread"),
              let setRadius = dlsym(scope, "CGSSetWindowBackgroundBlurRadius")
        else { return nil }
        return EntryPoints(
            connection: unsafeBitCast(connection, to: DefaultConnection.self),
            setRadius: unsafeBitCast(setRadius, to: SetBlurRadius.self)
        )
    }()

    /// False only if those private symbols are gone, which is the single case
    /// the `NSVisualEffectView` fallback exists for.
    static var isAvailable: Bool { entryPoints != nil }

    static func setRadius(_ radius: Int32, on window: NSWindow) {
        guard let entryPoints else { return }
        _ = entryPoints.setRadius(
            entryPoints.connection(),
            UInt32(truncatingIfNeeded: window.windowNumber),
            radius
        )
    }
}

/// The window's own corner radius, resolved at runtime.
///
/// AppKit publishes no corner radius. `NSWindow` has never exposed one, the
/// frame view's layer does not carry it, and macOS 26's concentric shapes
/// resolve against a SwiftUI container shape that an `NSHostingView` added
/// from AppKit does not have. What is left is the private `_cornerRadius`,
/// read through KVC behind a `responds(to:)` check — the same value Ghostty
/// reads, for the same reason: to give a window-level glass layer the window's
/// shape.
///
/// The guard matters more here than for the blur symbol, because a wrong
/// answer is worse than no answer. A missing radius costs the user glass and
/// leaves the blur, which the window clips itself; a radius that does not match
/// the window mis-clips the glass into a visible seam along the edge. So this
/// returns nil rather than a guess, and the plan reads nil as "not glass".
@MainActor
private enum WindowCornerRadius {
    /// Private, so it is named once and guarded before it is read.
    private static let key = "_cornerRadius"

    static func resolve(for window: NSWindow) -> CGFloat? {
        guard window.responds(to: Selector(key)) else { return nil }
        return window.value(forKey: key) as? CGFloat
    }
}

/// The chat window's background, in three independent layers.
///
/// 1. Opacity — how much of the desktop shows through. Continuous, and it owns
///    show-through by itself. No treatment is ever scaled by it.
/// 2. Treatment — a frosted blur by default, Liquid Glass if the user ticks
///    the box. A mode, not a position on the opacity dial, and never both.
/// 3. Content — untouched by either, because it is drawn above both.
///
/// This view owns the window configuration because the scene is a plain
/// SwiftUI `Window` with no controller and no delegate: reaching `view.window`
/// from a representable is how this app already talks to its window. It
/// configures the one window it is installed in and puts every property back
/// when it leaves, so this is ownership rather than a broadcast over
/// `NSApplication.shared.windows`.
struct WindowBackdrop: NSViewRepresentable {
    /// How solid the background is, 0...1.
    let opacity: Double

    /// Swaps the frosted blur for Liquid Glass.
    let usesLiquidGlass: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> WindowBackdropView {
        let view = WindowBackdropView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: WindowBackdropView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: WindowBackdropView) {
        view.apply(
            opacity: opacity,
            usesLiquidGlass: usesLiquidGlass,
            reduceTransparency: reduceTransparency
        )
    }
}

/// Draws the backdrop and configures the window it lands in.
@MainActor
final class WindowBackdropView: NSView {
    private var opacity: Double = 1
    private var usesLiquidGlass = false
    private var reduceTransparency = false

    /// The window's own settings, captured before the first change so that
    /// leaving puts them back. A window handed back to AppKit still
    /// translucent would outlive this view.
    private struct WindowBaseline {
        let isOpaque: Bool
        let backgroundColor: NSColor
    }

    private var baseline: WindowBaseline?

    /// The blur radius last pushed to the window server, so a SwiftUI
    /// re-evaluation that changes nothing does not repeat the call.
    private var appliedRadius: Int32?

    /// The dlsym-missing fallback, and nothing else. It *replaces* the
    /// coloured fill rather than sitting under it: a translucent fill over a
    /// vibrancy view would be two tints over the same desktop pixels, which is
    /// the defect this whole background was rebuilt to remove.
    private var fallbackMaterial: NSVisualEffectView?

    /// The opt-in Liquid Glass layer. It carries the colour itself, so the
    /// fill goes clear whenever this exists. It is below the content because
    /// this whole view is: SwiftUI installs it as the content's background.
    private var glassLayer: GlassBackdropHostingView?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Decoration only: never take a click away from the content above it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func apply(opacity: Double, usesLiquidGlass: Bool, reduceTransparency: Bool) {
        self.opacity = opacity
        self.usesLiquidGlass = usesLiquidGlass
        self.reduceTransparency = reduceTransparency
        sync()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Restore while the window reference still exists; by the time
        // `viewDidMoveToWindow` runs it is gone.
        if newWindow == nil {
            restoreWindow()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A different window has none of our state on it yet.
        appliedRadius = nil
        observeWindowChanges()
        sync()
    }

    /// The fill is a dynamic system colour, so a theme switch has to re-resolve
    /// it rather than keep the CGColor it was born with.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sync()
    }

    private var plan: WindowBackdropPlan {
        WindowBackdropPlan(
            opacity: opacity,
            usesLiquidGlass: usesLiquidGlass,
            reduceTransparency: reduceTransparency,
            isFullScreen: window?.styleMask.contains(.fullScreen) ?? false,
            // Re-read every time rather than cached: the radius belongs to the
            // window, and a window can hand this view a different one.
            windowCornerRadius: window.flatMap {
                WindowCornerRadius.resolve(for: $0)
            }
        )
    }

    private func sync() {
        let plan = self.plan
        // The one case where the coloured fill steps aside for a vibrancy
        // view: the private blur symbol is missing, so a public material has
        // to be the frost, and a translucent fill over it would be a second
        // tint.
        let usesFallbackMaterial = plan.treatment == .blur
            && !WindowBackgroundBlur.isAvailable

        syncWindow(plan)
        syncFill(plan, suppressed: usesFallbackMaterial)
        syncFallbackMaterial(active: usesFallbackMaterial)
        syncTitlebar(plan)
        syncGlass(plan)
    }

    private func syncWindow(_ plan: WindowBackdropPlan) {
        guard let window else { return }

        if baseline == nil {
            baseline = WindowBaseline(
                isOpaque: window.isOpaque,
                backgroundColor: window.backgroundColor
            )
        }

        let isOpaque = plan.treatment == .opaque
        // Not `.clear` for the translucent case. A hairline-alpha white keeps
        // the window compositing translucently while leaving all of the
        // visible colour to the fill; Ghostty settled on this exact value
        // because `.clear` reads differently from Terminal.app.
        let backgroundColor: NSColor = isOpaque
            ? .windowBackgroundColor
            : .white.withAlphaComponent(0.001)

        // Assign only on change. SwiftUI re-evaluates this view for reasons
        // that have nothing to do with the backdrop, and both of these
        // invalidate the window.
        if window.isOpaque != isOpaque {
            window.isOpaque = isOpaque
        }
        if window.backgroundColor != backgroundColor {
            window.backgroundColor = backgroundColor
        }

        // The blur is a treatment, not a modifier of the others: set for
        // `.blur`, cleared for everything else. That is how blur and glass
        // stay mutually exclusive, and it matches Ghostty skipping the call
        // whenever glass is active or the window is opaque. Guarded on the
        // last value pushed because this one is a round trip to the window
        // server, not a property assignment.
        guard WindowBackgroundBlur.isAvailable else { return }
        let radius = plan.treatment == .blur
            ? WindowBackgroundBlur.defaultRadius
            : 0
        guard appliedRadius != radius else { return }
        WindowBackgroundBlur.setRadius(radius, on: window)
        appliedRadius = radius
    }

    private func restoreWindow() {
        guard let window else { return }

        NotificationCenter.default.removeObserver(self, name: nil, object: window)
        restoreTitlebar()

        guard let baseline else { return }
        if WindowBackgroundBlur.isAvailable {
            WindowBackgroundBlur.setRadius(0, on: window)
            appliedRadius = nil
        }
        window.isOpaque = baseline.isOpaque
        window.backgroundColor = baseline.backgroundColor
        self.baseline = nil
    }

    /// The window events that change the plan, or quietly undo it.
    ///
    /// Fullscreen changes what is behind the window, so it changes the
    /// treatment, and there is no view-level hook for it. Becoming main is
    /// Ghostty's own resync point: macOS rebuilds titlebar views around
    /// activation, and the rebuilt ones arrive with their opaque backing
    /// restored.
    private func observeWindowChanges() {
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeMainNotification
        ] {
            center.removeObserver(self, name: name, object: window)
            center.addObserver(
                self,
                selector: #selector(windowStateDidChange),
                name: name,
                object: window
            )
        }
    }

    @objc private func windowStateDidChange() {
        sync()
    }

    private func syncFill(_ plan: WindowBackdropPlan, suppressed: Bool) {
        let alpha = suppressed ? 0 : plan.fillOpacity
        guard alpha > 0 else {
            layer?.backgroundColor = nil
            return
        }

        // Resolve the dynamic colour against this view's own appearance, so
        // light and dark each get their own window background rather than
        // whichever one happened to be current when the layer was made.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(alpha)
                .cgColor
        }
    }

    private func syncFallbackMaterial(active: Bool) {
        guard active else {
            fallbackMaterial?.removeFromSuperview()
            fallbackMaterial = nil
            return
        }
        guard fallbackMaterial == nil else { return }

        let view = NSVisualEffectView()
        // "The material to show under a window's background": the thinnest
        // window-level material AppKit ships, and the closest public stand-in
        // for a plain desktop blur that imposes no tint of its own.
        view.material = .underWindowBackground
        // Behind-window because this is the bottom of the window; the only
        // thing beneath it to blur is the desktop.
        view.blendingMode = .behindWindow
        // Always active, never `followsWindowActiveState`: an inactive backdrop
        // collapses to a flat fill, and a window that greys the moment it loses
        // focus is a bug this app has already fixed once.
        view.state = .active
        pin(view)
        fallbackMaterial = view
    }

    private func syncGlass(_ plan: WindowBackdropPlan) {
        guard case let .glass(cornerRadius) = plan.treatment else {
            glassLayer?.removeFromSuperview()
            glassLayer = nil
            return
        }

        let backdrop = GlassBackdrop(
            opacity: plan.opacity,
            cornerRadius: cornerRadius
        )
        if let glassLayer {
            // Compared, not just assigned, because `sync()` now runs on window
            // activation too: an unchanged backdrop must not cost a SwiftUI
            // update of a window-sized glass layer.
            if glassLayer.rootView != backdrop {
                glassLayer.rootView = backdrop
            }
            return
        }
        let host = GlassBackdropHostingView.make(rootView: backdrop)
        pin(host)
        glassLayer = host
    }

    /// The titlebar views this view has changed, and what they were.
    ///
    /// Weak because they are AppKit's, not ours: macOS rebuilds the titlebar
    /// around activation and fullscreen, and a strong reference here would keep
    /// a discarded one alive purely so it could be restored.
    private struct TitlebarBaseline {
        weak var view: NSView?
        let wantedLayer: Bool
        let backgroundColor: CGColor?
        weak var backgroundView: NSView?
        let backgroundViewWasHidden: Bool
    }

    private var titlebarBaseline: TitlebarBaseline?

    /// Ghostty's titlebar handling, ported to a view rather than an
    /// `NSWindow` subclass: clear the titlebar's own layer, and hide
    /// `NSTitlebarBackgroundView` outright because, in Ghostty's words, "this
    /// has multiple subviews that force a background color".
    ///
    /// Without it the treatment stops at the titlebar. The toolbar's own
    /// backing is already hidden in SwiftUI, but the titlebar behind it still
    /// paints, so the top of the window reads as an opaque band with an edge
    /// line across it.
    ///
    /// The blur already reaches the titlebar, but that does not clear the
    /// native backing painted above the transcript. The same private traversal
    /// therefore applies to both translucent treatments.
    private func syncTitlebar(_ plan: WindowBackdropPlan) {
        switch plan.treatment {
        case .glass, .blur:
            break
        case .opaque:
            restoreTitlebar()
            return
        }
        guard let container = titlebarContainer,
              let titlebarView = container.firstDescendant(
                  withClassName: "NSTitlebarView"
              )
        else { return }

        // A rebuilt titlebar is a different view. Re-clearing the old one would
        // leave the new one opaque, so a changed identity means putting the old
        // values back and capturing the new ones.
        if let titlebarBaseline, titlebarBaseline.view !== titlebarView {
            restoreTitlebar()
        }

        let backgroundView = container.firstDescendant(
            withClassName: "NSTitlebarBackgroundView"
        )
        if titlebarBaseline == nil {
            titlebarBaseline = TitlebarBaseline(
                view: titlebarView,
                wantedLayer: titlebarView.wantsLayer,
                backgroundColor: titlebarView.layer?.backgroundColor,
                backgroundView: backgroundView,
                backgroundViewWasHidden: backgroundView?.isHidden ?? false
            )
        }

        titlebarView.wantsLayer = true
        // Re-asserted on every sync rather than set once: the search panel's
        // chrome hiding walks these same private views and restores what it
        // found, so the only durable state is the state that is re-checked.
        // Compared by alpha because clear *is* the absence of a tint, and that
        // is cheaper to ask than CGColor identity.
        if titlebarView.layer?.backgroundColor?.alpha != 0 {
            titlebarView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        if backgroundView?.isHidden == false {
            backgroundView?.isHidden = true
        }
    }

    private func restoreTitlebar() {
        guard let titlebarBaseline else { return }
        self.titlebarBaseline = nil
        titlebarBaseline.backgroundView?.isHidden =
            titlebarBaseline.backgroundViewWasHidden
        titlebarBaseline.view?.layer?.backgroundColor =
            titlebarBaseline.backgroundColor
        if !titlebarBaseline.wantedLayer {
            titlebarBaseline.view?.wantsLayer = false
        }
    }

    /// The titlebar's container, found from the window's frame view.
    ///
    /// Neither translucent treatment applies in native fullscreen — the plan
    /// forces the opaque path there — so unlike Ghostty this never has to go
    /// looking for the separate `NSToolbarFullScreenWindow` that owns the
    /// titlebar while a window is fullscreen.
    private var titlebarContainer: NSView? {
        window?.contentView?.superview?
            .firstDescendant(withClassName: "NSTitlebarContainerView")
    }

    /// Treatments are mutually exclusive, so there is never more than one of
    /// these, and it always spans the whole background.
    private func pin(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

/// The opt-in Liquid Glass backdrop. It carries the colour itself at the user's
/// opacity, mirroring Ghostty's glass container, which applies `glassEffect` to
/// the background colour at the configured opacity rather than laying glass
/// over a separate fill.
///
/// Glass is deliberately not the default. The Materials HIG is explicit —
/// "Don't use Liquid Glass in the content layer… Instead, use standard
/// materials for elements in the content layer, such as app backgrounds" — and
/// `Glass.regular` "adjusts the luminosity of background content", which is
/// right for a floating control and can wash a whole window of text. Behind a
/// tick, that cost is the user's own explicit choice; as a default it was the
/// grey this window was rebuilt to remove.
struct GlassBackdrop: View, Equatable {
    let opacity: Double

    /// The window's own corner radius. Nothing clips this layer, so its shape
    /// has to come from the window rather than be assumed.
    let cornerRadius: CGFloat

    var body: some View {
        // One shape, used twice, because `glassEffect(_:in:)` shapes the
        // material and not the content it is applied to. A full-bleed `Color`
        // under a rounded glass effect keeps its own square corners, which is
        // exactly the plate that showed at the window's rounded edge, so the
        // colour is clipped to the shape the glass is drawn in.
        //
        // Continuous corners, because that is the curve macOS draws window and
        // display corners with; a circular arc of the same radius would leave a
        // hairline of glass outside the frame at each corner.
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )
        Color(nsColor: .windowBackgroundColor)
            .opacity(opacity)
            .clipShape(shape)
            .glassEffect(.regular, in: shape)
    }
}

/// The glass layer's host: transparent, and full-bleed.
///
/// Two AppKit defaults stood between the glass and the window it is meant to
/// fill. `NSHostingView` is not documented to be see-through, and an opaque
/// host is licence for AppKit to skip drawing what is behind it — which here is
/// the desktop the whole treatment exists to show, while a host that paints its
/// own backing is a whitish plate over the sidebar and the transcript. And a
/// hosting view inherits the window's safe area, so the hosted glass would
/// start *below* the titlebar and lay its own top edge across it; the
/// documented `safeAreaRegions` is this app's existing lever for that, and the
/// same correction Ghostty makes with a negative top constraint.
private final class GlassBackdropHostingView: NSHostingView<GlassBackdrop> {
    /// Built through a factory rather than an initializer. `NSHostingView`
    /// declares `init(rootView:)` itself, and a subclass that overrides it has
    /// to guess whether SwiftUI marked it `required`; this type adds no stored
    /// state, so inheriting that initializer and configuring the finished view
    /// is the version that cannot be wrong.
    static func make(rootView: GlassBackdrop) -> GlassBackdropHostingView {
        let host = GlassBackdropHostingView(rootView: rootView)
        host.safeAreaRegions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = nil
        host.layer?.isOpaque = false
        return host
    }

    override var isOpaque: Bool { false }

    /// Decoration only, like the view that owns it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private extension NSView {
    /// The first descendant with the given AppKit class name.
    ///
    /// By name because every view this reaches for is private —
    /// `NSTitlebarContainerView` and its background view have no public symbol
    /// to name — and Ghostty walks the same hierarchy the same way. A miss is
    /// ordinary rather than exceptional: every caller reads nil as "leave the
    /// titlebar alone".
    func firstDescendant(withClassName name: String) -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == name {
                return subview
            }
            if let found = subview.firstDescendant(withClassName: name) {
                return found
            }
        }
        return nil
    }
}
