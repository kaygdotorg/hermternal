import AppKit
import HermternalCore
import SwiftUI
import Testing

@testable import Hermternal

/// The composer field, with the toolbar controller the app gives it.
///
/// The controller is injected so a test can watch what the observation path
/// did. Everything else is the composition `ComposerView` builds: the same
/// `HStack`, the same `ZStack`, and no frame imposing a height.
private struct ComposerToolbarHarness: View {
    let store: ComposerToolbarHarnessStore
    let toolbar: ComposerFormattingToolbarController

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                ComposerMarkdownEditor(
                    source: Binding(
                        get: { store.text },
                        set: { store.text = $0 }
                    ),
                    mode: Binding(
                        get: { store.mode },
                        set: { store.mode = $0 }
                    ),
                    isFocused: Binding(
                        get: { store.isFocused },
                        set: { store.isFocused = $0 }
                    ),
                    isEditable: true,
                    focusRequest: 0,
                    formatRequest: store.formatRequest,
                    toolbar: toolbar,
                    onSubmit: {},
                    onEscape: { toolbar.handleEscape() },
                    onFormatHandled: { store.formatRequest = nil },
                    typingProbeOwner: ObjectIdentifier(store)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
@Observable
private final class ComposerToolbarHarnessStore {
    var text = ""
    var mode: ComposerEditorMode = .wysiwyg
    var isFocused = false
    var formatRequest: ComposerEditorFormat?
}

/// One mounted field, its window, and the controller that watches it.
@MainActor
private struct MountedField {
    let window: NSWindow
    let hosting: NSHostingView<AnyView>
    let store: ComposerToolbarHarnessStore
    let toolbar: ComposerFormattingToolbarController
    let textView: NSTextView

    func settle() async {
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()
    }

    /// Lets the coalesced update run, and nothing else.
    ///
    /// A forced layout pass here would enter the measurement, and the layout
    /// of a whole hosting view is not what the show path costs.
    func drainCoalescedUpdate() async {
        await Task.yield()
        await Task.yield()
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

@MainActor
private func mountField(text: String) async throws -> MountedField {
    _ = NSApplication.shared
    let store = ComposerToolbarHarnessStore()
    store.text = text
    let toolbar = ComposerFormattingToolbarController()
    let hosting = NSHostingView(
        rootView: AnyView(ComposerToolbarHarness(store: store, toolbar: toolbar))
    )
    hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
    let window = NSWindow(
        contentRect: hosting.frame,
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()
    let textView = try #require(firstEditorTextView(in: hosting))
    #expect(window.makeFirstResponder(textView))
    return MountedField(
        window: window,
        hosting: hosting,
        store: store,
        toolbar: toolbar,
        textView: textView
    )
}

@MainActor
private func firstEditorTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
        if let found = firstEditorTextView(in: subview) { return found }
    }
    return nil
}

/// Typing must not reach the toolbar at all.
///
/// A keystroke moves the caret, so AppKit posts one selection change for it
/// and the controller is on the typing path whether it wants to be. It has to
/// answer that notification with one length read and nothing else: no
/// scheduled work, no published placement, and therefore no SwiftUI
/// invalidation.
///
/// The controller's own counters carry this, and no global counter does, so
/// the answer is the same however many tests the runner starts at once.
@Test("Typing with no selection schedules no toolbar work")
@MainActor
func typingWithNoSelectionSchedulesNoToolbarWork() async throws {
    let field = try await mountField(text: "")
    defer { field.close() }

    let message = "Hermes, state the one rule that keeps a floating toolbar off "
        + "the typing path."
    for character in message {
        field.textView.insertText(
            String(character),
            replacementRange: field.textView.selectedRange()
        )
        await field.settle()
    }

    print(
        "COMPOSER_TOOLBAR_TYPING keystrokes=\(message.count)"
            + " observedSelectionChanges=\(field.toolbar.observedSelectionChanges)"
            + " scheduledUpdates=\(field.toolbar.scheduledUpdates)"
    )
    // The observer ran, so the measurement is of the real path.
    #expect(field.toolbar.observedSelectionChanges >= message.count)
    // And it did nothing: this is the zero delta.
    #expect(field.toolbar.scheduledUpdates == 0)
    #expect(field.toolbar.presentation == nil)
    #expect(!field.toolbar.isVisible)
}

/// The typing path has to cost the same with the toolbar as without it.
///
/// One harness types the same message twice: once with the observer live, and
/// once with it detached, which is the composer as it was before the toolbar
/// existed. `ComposerTypingProbe` counts the layout work of each pass, and the
/// two counts have to match, because a keystroke never reaches the toolbar.
///
/// The probe records one composer. This comparison still wants the process
/// to itself so a first-mount warm-up cannot land in only one of the two
/// passes:
///
///     HERMTERNAL_TOOLBAR_DELTA=1 swift test --filter typingCostsTheSameWithTheToolbar
///
/// It is therefore not part of an unattended run. The contract it defends is
/// held by `typingWithNoSelectionSchedulesNoToolbarWork`, which needs no
/// probe.
@Test(
    "Typing costs the same with the floating toolbar as without it",
    .enabled(
        if: ProcessInfo.processInfo.environment["HERMTERNAL_TOOLBAR_DELTA"] == "1"
    )
)
@MainActor
func typingCostsTheSameWithTheToolbar() async throws {
    let message = "Hermes, name the rule that keeps this strip off the typing path."

    func typingSnapshot(observing: Bool) async throws -> ComposerTypingProbe.Snapshot {
        let field = try await mountField(text: "")
        defer { field.close() }
        if !observing {
            field.toolbar.detach()
        }
        ComposerTypingProbe.begin(owner: field.store)
        defer { _ = ComposerTypingProbe.finish() }
        for character in message {
            field.textView.insertText(
                String(character),
                replacementRange: field.textView.selectedRange()
            )
            ComposerTypingProbe.noteKeystroke(from: field.store)
            await field.settle()
        }
        #expect(field.toolbar.scheduledUpdates == 0)
        return ComposerTypingProbe.snapshot
    }

    // The observing pass runs first, so a first-mount warm-up cannot land
    // only in the pass it would flatter.
    let attached = try await typingSnapshot(observing: true)
    let detached = try await typingSnapshot(observing: false)

    print(
        "COMPOSER_TOOLBAR_DELTA keystrokes=\(attached.keystrokes)/\(detached.keystrokes)"
            + " sizeThatFits=\(attached.sizeThatFitsCount)/\(detached.sizeThatFitsCount)"
            + " synchronizeColumn=\(attached.synchronizeColumnCount)"
            + "/\(detached.synchronizeColumnCount)"
            + " heightChanges=\(attached.heightChangeCount)/\(detached.heightChangeCount)"
            + " caretScrolls=\(attached.caretScrollCount)/\(detached.caretScrollCount)"
            + " sizeThatFitsUs=\(attached.sizeThatFitsNanos / 1000)"
            + "/\(detached.sizeThatFitsNanos / 1000)"
    )
    #expect(attached.keystrokes == detached.keystrokes)
    #expect(attached.sizeThatFitsCount == detached.sizeThatFitsCount)
    #expect(attached.synchronizeColumnCount == detached.synchronizeColumnCount)
    #expect(attached.heightChangeCount == detached.heightChangeCount)
    #expect(attached.caretScrollCount == detached.caretScrollCount)
}

/// A selection shows the strip, and emptying it takes the strip away.
@Test("A selection shows the floating toolbar and an empty one hides it")
@MainActor
func selectionShowsAndHidesTheFloatingToolbar() async throws {
    let field = try await mountField(text: "Hermes reads the composer field.")
    defer { field.close() }

    field.textView.setSelectedRange(NSRange(location: 0, length: 6))
    await field.settle()
    let shown = try #require(field.toolbar.presentation)
    #expect(field.toolbar.isVisible)
    #expect(!shown.isSummoned)
    print(
        "COMPOSER_TOOLBAR_SHOW originX=\(shown.originX) originY=\(shown.originY)"
            + " placement=\(shown.placement.rawValue)"
            + " showLatencyUs=\(field.toolbar.lastShowLatencyNanoseconds / 1000)"
    )
    // The strip is inside the field it belongs to.
    let band = try #require(field.textView.enclosingScrollView).contentView.bounds
    #expect(shown.originX >= 0)
    #expect(shown.originX + ComposerFormattingToolbarLayout.width <= Double(band.width) + 0.5)
    #expect(shown.originY >= 0)
    #expect(shown.originY + ComposerFormattingToolbarLayout.height <= Double(band.height) + 0.5)

    field.textView.setSelectedRange(NSRange(location: 6, length: 0))
    await field.settle()
    #expect(field.toolbar.presentation == nil)
}

/// The show has to keep up with the gesture that caused it.
///
/// The show path is one coalesced main-actor turn plus one placement, and the
/// placement is the part the toolbar owns. This measures that part.
///
/// The end-to-end number, which holds the turn as well, is printed rather
/// than asserted: this runner starts many `@MainActor` tests at once, and a
/// main actor that another test is holding lengthens the turn by tens of
/// milliseconds. Run the suite with `--no-parallel` to read a quiet number.
@Test("Placing the floating toolbar costs well under one display frame")
@MainActor
func placingTheToolbarCostsUnderOneFrame() async throws {
    let field = try await mountField(text: "Hermes reads the composer field.")
    defer { field.close() }

    // One warm pass. The first selection of a mounted field pays for the
    // layout manager's first glyph generation, which no later one repeats.
    field.textView.setSelectedRange(NSRange(location: 0, length: 6))
    await field.settle()
    #expect(field.toolbar.presentation != nil)

    var work: [UInt64] = []
    var endToEnd: [UInt64] = []
    for step in 0..<8 {
        field.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await field.drainCoalescedUpdate()
        field.textView.setSelectedRange(NSRange(location: step, length: 6))
        await field.drainCoalescedUpdate()
        #expect(field.toolbar.presentation != nil)
        work.append(field.toolbar.lastPlacementWorkNanoseconds)
        endToEnd.append(field.toolbar.lastShowLatencyNanoseconds)
    }
    let worstWork = work.max() ?? 0
    print(
        "COMPOSER_TOOLBAR_LATENCY workUs="
            + work.map { String($0 / 1000) }.joined(separator: ",")
            + " worstWorkUs=\(worstWork / 1000)"
            + " endToEndUs="
            + endToEnd.map { String($0 / 1000) }.joined(separator: ",")
    )
    // 16.6ms is one frame at 60Hz. One placement may not spend a tenth of it.
    #expect(worstWork < 1_600_000)
}

/// A drag across a paragraph posts many selection changes. The toolbar has to
/// answer them with one placement, not one for each.
@Test("A burst of selection changes places the floating toolbar once")
@MainActor
func aBurstOfSelectionChangesPlacesTheToolbarOnce() async throws {
    let field = try await mountField(text: "Hermes reads the composer field.")
    defer { field.close() }

    let before = field.toolbar.scheduledUpdates
    for length in 1...12 {
        field.textView.setSelectedRange(NSRange(location: 0, length: length))
    }
    await field.drainCoalescedUpdate()
    let scheduled = field.toolbar.scheduledUpdates - before
    print(
        "COMPOSER_TOOLBAR_COALESCE selectionChanges=12 scheduledUpdates=\(scheduled)"
    )
    #expect(scheduled == 1)
    let shown = try #require(field.toolbar.presentation)
    // The one placement is for the selection the burst ended on.
    #expect(shown.originX >= 0)
}

/// The strip rests above the selected line when the band has room, and below
/// it when the selection is on the first line.
@Test("The floating toolbar sits above the selection, or below when it cannot")
@MainActor
func placementFollowsTheSelectedLine() async throws {
    let field = try await mountField(
        text: "one line\ntwo line\nthree line\nfour line\nfive line"
    )
    defer { field.close() }

    // The first line has nothing above it inside the band.
    field.textView.setSelectedRange(NSRange(location: 0, length: 3))
    await field.settle()
    let first = try #require(field.toolbar.presentation)
    #expect(first.placement == .below)

    // A later line has room above it.
    let text = field.textView.string as NSString
    let fourth = text.range(of: "four")
    field.textView.setSelectedRange(fourth)
    await field.settle()
    let later = try #require(field.toolbar.presentation)
    #expect(later.placement == .above)
    print(
        "COMPOSER_TOOLBAR_PLACEMENT first=\(first.placement.rawValue)"
            + " firstY=\(first.originY) later=\(later.placement.rawValue)"
            + " laterY=\(later.originY)"
    )
    #expect(later.originY < first.originY)
}

/// Focus loss and Escape both close the strip, and Escape reports that it
/// used the key press so the composer's own cancel does not also run.
@Test("Focus loss and Escape close the floating toolbar")
@MainActor
func focusLossAndEscapeCloseTheToolbar() async throws {
    let field = try await mountField(text: "Hermes reads the composer field.")
    defer { field.close() }

    field.textView.setSelectedRange(NSRange(location: 0, length: 6))
    await field.settle()
    #expect(field.toolbar.presentation != nil)
    #expect(field.toolbar.handleEscape())
    #expect(field.toolbar.presentation == nil)
    // Nothing left to close, so the next handler gets the key press.
    #expect(!field.toolbar.handleEscape())

    field.textView.setSelectedRange(NSRange(location: 0, length: 6))
    await field.settle()
    #expect(field.toolbar.presentation != nil)
    field.toolbar.noteFocusChange(false)
    #expect(field.toolbar.presentation == nil)
}

/// The keyboard summon shows the strip at the caret, with no selection.
@Test("The keyboard summon shows the floating toolbar at the caret")
@MainActor
func keyboardSummonShowsTheToolbarAtTheCaret() async throws {
    let field = try await mountField(text: "Hermes reads the composer field.")
    defer { field.close() }

    field.textView.setSelectedRange(NSRange(location: 12, length: 0))
    await field.settle()
    #expect(field.toolbar.presentation == nil)

    field.toolbar.summon()
    let summoned = try #require(field.toolbar.presentation)
    #expect(summoned.isSummoned)
    #expect(field.toolbar.isSummoned)
    #expect(summoned.summonGeneration == 1)

    // A second summon focuses the first item again.
    field.toolbar.summon()
    let again = try #require(field.toolbar.presentation)
    #expect(again.summonGeneration == 2)

    // Moving the caret dismisses a summoned strip.
    field.textView.setSelectedRange(NSRange(location: 4, length: 0))
    await field.settle()
    #expect(field.toolbar.presentation == nil)
}

/// A read-only route refuses formatting, so the strip never appears there.
@Test("A read-only composer never shows the floating toolbar")
@MainActor
func readOnlyComposerNeverShowsTheToolbar() async throws {
    let field = try await mountField(text: "Hermes reads the composer field.")
    defer { field.close() }

    field.toolbar.setEnabled(false)
    field.textView.setSelectedRange(NSRange(location: 0, length: 6))
    await field.settle()
    #expect(field.toolbar.presentation == nil)
    field.toolbar.summon()
    #expect(field.toolbar.presentation == nil)
}

/// Every toolbar action has to reach the editor and change the source.
///
/// The toolbar states an action, the composer turns it into the editor's
/// format request, and `ComposerEditorFormatter` writes the Markdown. This
/// walks the whole catalog through that one route.
@Test("Every floating toolbar action reaches the editor")
@MainActor
func everyToolbarActionReachesTheEditor() async throws {
    for item in ComposerFormattingToolbarCatalog.items {
        let field = try await mountField(text: "target")
        field.textView.setSelectedRange(NSRange(location: 0, length: 6))
        await field.settle()

        switch item.action {
        case let .format(format):
            field.store.formatRequest = format
            await field.settle()
            #expect(
                field.store.text != "target",
                "\(item.identifier) changed no source"
            )
        case .toggleSource:
            field.store.mode = .source
            await field.settle()
            #expect(field.textView.string == field.store.text)
        }
        field.close()
    }
}

/// A numbered list has to draw its number.
///
/// The field renders Markdown, and the Numbered List item now writes `1. `.
/// A bullet in front of that would state a list the source does not hold, so
/// the rendered marker follows the item's own number.
@Test("The field draws the number of a numbered list item")
@MainActor
func numberedListDrawsItsNumber() async throws {
    let field = try await mountField(text: "1. first\n2. second")
    defer { field.close() }
    await field.settle()
    #expect(field.textView.string.contains("1. first"))
    #expect(field.textView.string.contains("2. second"))
    #expect(!field.textView.string.contains("• "))
}
