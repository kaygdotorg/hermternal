import AppKit
import HermternalCore
import Observation

/// Watches the composer editor's selection and places the floating toolbar.
///
/// The controller is the whole observation path. It holds one notification
/// observer on the editor's own text view, and it does no other work: no
/// timer, no display link, and no per-frame tracking.
///
/// Typing is the path that must cost nothing. A keystroke moves the caret,
/// and AppKit posts one selection change for it, so this class is on the
/// typing path whether it wants to be. `selectionDidChange` therefore reads
/// one length, finds an empty selection under a hidden toolbar, and returns.
/// It writes no observed property, schedules no work, and forces no layout,
/// so SwiftUI never re-runs the composer body for a keystroke.
/// Defended by typingWithNoSelectionSchedulesNoToolbarWork.
///
/// Real work is coalesced onto the next main-actor turn. One drag across a
/// paragraph posts many selection changes, and AppKit posts them while it is
/// still laying the text out, so the geometry is read once the field settled.
@MainActor
@Observable
final class ComposerFormattingToolbarController {
    /// Where the strip sits, in the coordinate space of the editor's own
    /// view: points from its top leading corner.
    struct Presentation: Equatable {
        let originX: Double
        let originY: Double
        let placement: ComposerFormattingToolbarPlacement
        let isSummoned: Bool
        let summonGeneration: Int
    }

    /// The one observed property. Every other stored value is ignored by
    /// observation, so a counter or a timestamp can never invalidate a view.
    private(set) var presentation: Presentation?

    /// How many selection notifications the observer answered, including the
    /// ones it returned from at once. A test types with no selection and
    /// expects this to rise while `scheduledUpdates` stays at zero.
    @ObservationIgnored private(set) var observedSelectionChanges = 0

    /// How many times the observer scheduled the coalesced update.
    @ObservationIgnored private(set) var scheduledUpdates = 0

    /// The main-actor work one placement cost, in nanoseconds: the selection
    /// geometry, the arithmetic, and the published value. This is the number
    /// the show path owns.
    @ObservationIgnored private(set) var lastPlacementWorkNanoseconds: UInt64 = 0

    /// The whole show, from the notification that caused it to the published
    /// placement, in nanoseconds. It holds one coalesced main-actor turn as
    /// well, so a busy main actor lengthens it and a free one does not.
    @ObservationIgnored private(set) var lastShowLatencyNanoseconds: UInt64 = 0

    @ObservationIgnored private var state = ComposerFormattingToolbarState()
    @ObservationIgnored private weak var textView: NSTextView?
    @ObservationIgnored private let observers = ComposerToolbarObservers()
    @ObservationIgnored private var isUpdateScheduled = false
    @ObservationIgnored private var summonGeneration = 0
    @ObservationIgnored private var changeTimestamp: UInt64 = 0

    var isVisible: Bool { presentation != nil }

    var isSummoned: Bool { state.isSummoned }

    deinit {
        // `deinit` can run off the main actor, and the tokens live in a box
        // for that reason. NotificationCenter removal is thread safe, so this
        // is the one teardown a lost view cannot skip.
        observers.removeAll()
    }

    // MARK: - Attachment

    /// Observes one text view's selection.
    ///
    /// The editor adapter owns the text view, so it hands it over once at
    /// make time. A repeated call for the same view changes nothing, which is
    /// what makes the call safe from an update pass.
    func attach(to textView: NSTextView) {
        guard self.textView !== textView else { return }
        detach()
        self.textView = textView
        observers.add(NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: textView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.selectionDidChange()
            }
        })
        // A field that scrolls moves the selected line under the strip. The
        // clip view posts its bounds change only while it scrolls, so this
        // costs nothing while the text stands still.
        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            observers.add(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.selectionDidChange()
                }
            })
        }
    }

    func detach() {
        observers.removeAll()
        textView = nil
        state.escaped()
        publish(nil)
    }

    // MARK: - Events

    /// The editor gained or lost first responder.
    func noteFocusChange(_ isFocused: Bool) {
        guard state.focusChanged(isFocused: isFocused) else { return }
        publish(nil)
    }

    /// A read-only route refuses formatting, so the strip cannot show.
    func setEnabled(_ isEnabled: Bool) {
        guard state.setEnabled(isEnabled) else { return }
        publish(nil)
    }

    /// Escape closes the strip. The result states whether it did that work,
    /// so the editor only consumes the key press when it did.
    func handleEscape() -> Bool {
        guard state.escaped() else { return false }
        publish(nil)
        return true
    }

    /// The keyboard summon. It shows the strip at the caret and focuses the
    /// first item, and it never waits for the coalesced turn, because a menu
    /// command has to answer at once.
    func summon() {
        guard textView != nil else { return }
        changeTimestamp = DispatchTime.now().uptimeNanoseconds
        summonGeneration &+= 1
        state.summoned()
        update(isSummon: true)
    }

    // MARK: - Observation

    private func selectionDidChange() {
        observedSelectionChanges &+= 1
        guard let textView else { return }
        // The typing path. A caret with nothing selected, while no strip is
        // on screen, is every keystroke, and it ends here.
        if textView.selectedRange().length == 0, !state.isVisible { return }
        guard !isUpdateScheduled else { return }
        isUpdateScheduled = true
        scheduledUpdates &+= 1
        changeTimestamp = DispatchTime.now().uptimeNanoseconds
        Task { @MainActor [weak self] in
            self?.update(isSummon: false)
        }
    }

    /// Reads the selection once and publishes one placement for it.
    ///
    /// The summon carries its own reason, because the caret it opens on is an
    /// empty selection, which every other caller wants the strip to hide on.
    func update(isSummon: Bool = false) {
        isUpdateScheduled = false
        let workStart = DispatchTime.now().uptimeNanoseconds
        defer {
            lastPlacementWorkNanoseconds =
                DispatchTime.now().uptimeNanoseconds &- workStart
        }
        guard let textView,
              let scrollView = textView.enclosingScrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            publish(nil)
            return
        }
        let clipView = scrollView.contentView
        let range = textView.selectedRange()
        if !isSummon {
            state.selectionChanged(
                isEmpty: range.length == 0,
                isFocused: textView.window?.firstResponder === textView
            )
        }
        guard state.isVisible else {
            publish(nil)
            return
        }
        let selection = selectionRect(
            for: range,
            textView: textView,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        // Normalize both rectangles to the visible clip bounds. The clip view
        // changes its bounds origin during scrolling, and AppKit may use a
        // bottom-leading coordinate system, while the SwiftUI overlay starts
        // at the visible top-leading corner.
        let clipBounds = clipView.bounds
        let band = clipView.convert(clipBounds, to: scrollView)
        let scrollBounds = scrollView.bounds
        let bandTop = scrollView.isFlipped
            ? band.minY - scrollBounds.minY
            : scrollBounds.maxY - band.maxY
        let local = clipView.convert(selection, from: textView)
        let selectionTop: Double
        let selectionBottom: Double
        if clipView.isFlipped {
            selectionTop = Double(local.minY - clipBounds.minY)
            selectionBottom = Double(local.maxY - clipBounds.minY)
        } else {
            selectionTop = Double(clipBounds.maxY - local.maxY)
            selectionBottom = Double(clipBounds.maxY - local.minY)
        }
        let viewportHeight = Double(clipBounds.height)
        let viewportWidth = Double(clipBounds.width)
        guard ComposerFormattingToolbarLayout.anchorIsVisible(
            selectionTop: selectionTop,
            selectionBottom: selectionBottom,
            viewportHeight: viewportHeight
        ) else {
            state.anchorLost()
            publish(nil)
            return
        }
        let placement = ComposerFormattingToolbarLayout.placement(
            selectionTop: selectionTop,
            selectionBottom: selectionBottom,
            viewportHeight: viewportHeight
        )
        let originY = ComposerFormattingToolbarLayout.originY(
            placement: placement,
            selectionTop: selectionTop,
            selectionBottom: selectionBottom,
            viewportHeight: viewportHeight
        )
        let originX = ComposerFormattingToolbarLayout.originX(
            selectionCenterX: Double(local.midX - clipBounds.minX),
            viewportWidth: viewportWidth
        )
        publish(Presentation(
            originX: Double(band.minX) + originX,
            originY: Double(bandTop) + originY,
            placement: placement,
            isSummoned: state.isSummoned,
            summonGeneration: summonGeneration
        ))
    }

    /// The rectangle the selected text occupies, in the text view's space.
    ///
    /// A caret has no width, so the summon anchors on the line fragment that
    /// holds it. An empty document has no glyph to ask about, and AppKit's
    /// extra line fragment is the rectangle for that case.
    private func selectionRect(
        for range: NSRange,
        textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect {
        var rect: NSRect
        if layoutManager.numberOfGlyphs == 0 {
            rect = layoutManager.extraLineFragmentRect
        } else if range.length == 0 {
            let index = min(range.location, layoutManager.numberOfGlyphs - 1)
            rect = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: nil)
            let caret = layoutManager.location(forGlyphAt: index)
            rect.origin.x += caret.x
            rect.size.width = 0
        } else {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        }
        let origin = textView.textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }

    /// Writes the placement, and only when it changed.
    private func publish(_ next: Presentation?) {
        guard presentation != next else { return }
        let wasHidden = presentation == nil
        presentation = next
        if wasHidden, next != nil, changeTimestamp != 0 {
            lastShowLatencyNanoseconds =
                DispatchTime.now().uptimeNanoseconds &- changeTimestamp
        }
    }
}

/// The notification tokens of one controller.
///
/// The tokens live outside the actor because `deinit` can run anywhere, and
/// removal has to be possible from there. `NotificationCenter` is thread
/// safe, and nothing else reads this box, so the unchecked conformance
/// carries no shared mutable state past that one call.
private final class ComposerToolbarObservers: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    func removeAll() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
    }
}
