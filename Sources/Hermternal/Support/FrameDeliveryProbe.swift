import AppKit
import QuartzCore
import HermternalCore
import SwiftUI

/// A zero-sized AppKit host for the frame-delivery instrument. The host owns
/// the platform callback and event monitor; Core owns samples and statistics.
/// It never writes SwiftUI or observable state from a display callback.
struct FrameDeliveryProbe: NSViewRepresentable {
    let capability: any DebugModuleCapability

    func makeNSView(context: Context) -> FrameDeliveryProbeView {
        FrameDeliveryProbeView(capability: capability)
    }

    func updateNSView(_ view: FrameDeliveryProbeView, context: Context) {
        view.update(capability: capability)
    }
}

@MainActor
final class FrameDeliveryProbeView: NSView {
    private let callbackSelector = #selector(displayLinkDidFire(_:))
    private var capability: any DebugModuleCapability
    private var displayLinkHandle: CADisplayLink?
    private var scrollMonitor: Any?
    private var clickMonitor: Any?
    private var previousPresentedAtNanoseconds: UInt64?
    private var firstScrollAtNanoseconds: UInt64?
    private var gestureLatencyReported = false
    private var lastScrollAtNanoseconds: UInt64?
    private var pendingClickAtNanoseconds: UInt64?
    private var clickSurface: FrameDeliverySurface = .unknown
    private var scrollSurface: FrameDeliverySurface = .unknown
    // A scroll gesture is considered active for 200 ms after its last event.
    // This bounded tail captures the display callback after the final input
    // without turning idle display cadence into a scrolling measurement.
    private static let gestureGraceNanoseconds: UInt64 = 200_000_000

    init(capability: any DebugModuleCapability) {
        self.capability = capability
        super.init(frame: .zero)
        // Keep the host in the window's view tree: AppKit suspends a display
        // link whose view is hidden. It has no drawing and is one point wide.
        isHidden = false
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(capability: any DebugModuleCapability) {
        self.capability = capability
        if capability.isEnabled(.frameDelivery) {
            startIfPossible()
        } else {
            stop()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startIfPossible()
        } else {
            stop()
        }
    }

    private func startIfPossible() {
        guard window != nil,
              capability.isEnabled(.frameDelivery),
              displayLinkHandle == nil
        else { return }

        // NSView.displayLink(target:selector:) is the AppKit API introduced in
        // macOS 14. It follows the display hosting this view and is suspended
        // when the view is hidden or off-display.
        displayLinkHandle = self.displayLink(target: self, selector: callbackSelector)
        displayLinkHandle?.add(to: .main, forMode: .common)
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.observeScroll(event)
            return event
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.observeMouseDown(event)
            return event
        }
    }

    private func stop() {
        displayLinkHandle?.invalidate()
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        displayLinkHandle = nil
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        previousPresentedAtNanoseconds = nil
        pendingClickAtNanoseconds = nil
        clickSurface = .unknown
        firstScrollAtNanoseconds = nil
        gestureLatencyReported = false
        lastScrollAtNanoseconds = nil
        scrollSurface = .unknown
    }

    private func observeScroll(_ event: NSEvent) {
        guard capability.isEnabled(.frameDelivery) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let startsNewGesture = firstScrollAtNanoseconds == nil
            || (lastScrollAtNanoseconds.map { now &- $0 > Self.gestureGraceNanoseconds } ?? true)
            || event.phase == .began
        if startsNewGesture {
            firstScrollAtNanoseconds = now
            previousPresentedAtNanoseconds = nil
            gestureLatencyReported = false
            scrollSurface = .unknown
        }
        // Keep the gesture's source surface through momentum; if its first
        // event did not hit a known scroll view, remain unknown rather than
        // guessing from the pointer's later position.
        lastScrollAtNanoseconds = now
        let eventSurface = surface(for: event)
        if eventSurface != .unknown {
            scrollSurface = eventSurface
        }
    }
    /// Arms a separate click endpoint for a sidebar mouse-down. It does not
    /// change the scroll gesture state or its frame-interval stream.
    private func observeMouseDown(_ event: NSEvent) {
        guard capability.isEnabled(.frameDelivery),
              surface(for: event) == .sidebar
        else {
            pendingClickAtNanoseconds = nil
            clickSurface = .unknown
            return
        }
        pendingClickAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        clickSurface = .sidebar
    }

    /// The callback is intentionally measurement-only: a clock read and one
    /// value write into Core's bounded ring. Statistics are sorted later by
    /// ``DebugFrameDeliveryMetrics`` when Settings requests a snapshot.
    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        guard capability.isEnabled(.frameDelivery) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let scrollActive = lastScrollAtNanoseconds.map {
            now &- $0 <= Self.gestureGraceNanoseconds
        } ?? false
        let clickPending = pendingClickAtNanoseconds != nil
        guard scrollActive || clickPending else {
            previousPresentedAtNanoseconds = nil
            firstScrollAtNanoseconds = nil
            gestureLatencyReported = false
            return
        }

        let interval = scrollActive ? previousPresentedAtNanoseconds.map { now &- $0 } : nil
        if scrollActive {
            previousPresentedAtNanoseconds = now
        } else {
            previousPresentedAtNanoseconds = nil
        }
        let refreshInterval = max(
            1,
            UInt64(max(0, link.targetTimestamp - link.timestamp) * 1_000_000_000)
        )
        let gestureLatency = !gestureLatencyReported
            ? firstScrollAtNanoseconds.map { now >= $0 ? now - $0 : 0 }
            : nil
        let clickLatency = pendingClickAtNanoseconds.map {
            now >= $0 ? now - $0 : 0
        }
        capability.record(
            FrameDeliverySample(
                presentedAtNanoseconds: now,
                intervalNanoseconds: interval,
                refreshIntervalNanoseconds: refreshInterval,
                surface: clickPending ? clickSurface : scrollSurface,
                gestureLatencyNanoseconds: gestureLatency,
                clickLatencyNanoseconds: clickLatency
            )
        )
        gestureLatencyReported = true
        pendingClickAtNanoseconds = nil
        clickSurface = .unknown
    }

    private func surface(for event: NSEvent) -> FrameDeliverySurface {
        guard let eventWindow = event.window,
              let contentView = eventWindow.contentView,
              let hitView = contentView.hitTest(event.locationInWindow)
        else { return .unknown }

        var current: NSView? = hitView
        while let view = current {
            if let scrollView = view.enclosingScrollView {
                let documentType = scrollView.documentView.map { String(describing: type(of: $0)) } ?? ""
                if scrollView.documentView is NSOutlineView || documentType.contains("Outline") {
                    return .sidebar
                }
                if scrollView.documentView is NSTableView || documentType.contains("Table") {
                    return .transcript
                }
            }
            current = view.superview
        }
        return .unknown
    }
}
