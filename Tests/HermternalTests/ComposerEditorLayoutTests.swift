import AppKit
import HermternalCore
import Observation
import SwiftUI
import Testing
@testable import Hermternal

/// The composition the composer gives its message field.
///
/// This is the field and nothing else: the same `ZStack`, the same
/// always-present placeholder, and no frame imposing a height, so a failure
/// here names the editor rather than a gateway-backed control. The enclosing
/// `HStack` is kept because it is what proposes a zero width and an infinite
/// width to the field during a layout pass.
private struct ComposerEditorHarness: View {
    let store: ComposerEditorHarnessStore
    /// The field always has a toolbar controller in the app, so the harness
    /// keeps one. These tests never show the strip; they watch the field.
    @State private var toolbar = ComposerFormattingToolbarController()

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
                    onEscape: { false },
                    onFormatHandled: { store.formatRequest = nil }
                )
                Text("Message Hermes…")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .padding(.top, 7)
                    .opacity(store.text.isEmpty ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
@Observable
private final class ComposerEditorHarnessStore {
    var text = ""
    var mode: ComposerEditorMode = .wysiwyg
    var isFocused = false
    var formatRequest: ComposerEditorFormat?
}

@Test("Typing keeps one editor, its first responder, and one bounded height")
@MainActor
func typingKeepsEditorIdentityFocusAndBoundedHeight() async throws {
    _ = NSApplication.shared
    let store = ComposerEditorHarnessStore()
    let hosting = NSHostingView(rootView: ComposerEditorHarness(store: store))
    hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
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
    defer {
        window.contentView = nil
        window.close()
    }
    hosting.layoutSubtreeIfNeeded()

    let editor = try #require(firstTextView(in: hosting))
    let identity = ObjectIdentifier(editor)
    #expect(window.makeFirstResponder(editor))

    // Long enough that this column wraps more than once, so the height has to
    // leave its first band without reaching the eight line cap.
    let message = "Hermes, name the composer flicker, its cause, and the one "
        + "layout rule that ends it, in a single plain sentence."
    var heights: [CGFloat] = []
    var lengths: [Int] = []
    for character in message {
        editor.insertText(String(character), replacementRange: editor.selectedRange())
        // One real layout pass. It asks the field for a minimum and a maximum
        // width before it asks for the column, and all three answers have to
        // be the height of the column. The yield lets any deferred main-actor
        // work land, which is where the height used to arrive from.
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()

        let live = try #require(firstTextView(in: hosting))
        // One editor, never replaced, so the caret and the undo stack survive
        // every character.
        #expect(ObjectIdentifier(live) == identity)
        #expect(window.firstResponder === live)
        lengths.append(live.string.count)
        let field = try #require(live.enclosingScrollView)
        heights.append(field.frame.height)
    }

    // Every pass saw exactly the characters entered so far. A replaced editor,
    // or a source round trip that re-read an empty draft, shows up here as a
    // pass that is short by one or empty outright.
    #expect(lengths == Array(1...message.count))

    let minimum = CGFloat(ComposerEditorHeightPolicy.minimum)
    let maximum = CGFloat(ComposerEditorHeightPolicy.maximum)
    let first = try #require(heights.first)
    let last = try #require(heights.last)
    #expect(heights.allSatisfy { $0 >= minimum && $0 <= maximum })
    // Characters are only added, so the height never shrinks. The probe-driven
    // oscillation appeared here as a drop back from the eight line cap.
    #expect(zip(heights, heights.dropFirst()).allSatisfy { $0.0 <= $0.1 })
    // One line of text reports one line, and a wrapped line reports the wrap
    // rather than the cap.
    #expect(abs(first - minimum) < 1)
    #expect(last > minimum)
    #expect(last < maximum)

    // The text is settled, so repeated layout passes must all report the one
    // height. This is the flicker itself: the composer alternated between the
    // minimum and the cap for as long as the draft held text.
    var settled: [CGFloat] = []
    for _ in 0..<6 {
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()
        let live = try #require(firstTextView(in: hosting))
        let field = try #require(live.enclosingScrollView)
        settled.append(field.frame.height)
    }
    #expect(Set(settled) == [last])
    #expect(window.firstResponder === editor)
    #expect(store.text.count == message.count)
}

/// The composer's own shape around the field.
///
/// The field sits above a control row whose fixed-width controls and trailing
/// `Spacer` give the panel a narrow ideal width, and the whole panel is a
/// bottom safe-area inset. That combination is what makes a layout pass apply
/// the panel its ideal width once before applying the width it occupies, which
/// is the pass the field used to keep.
private struct ComposerColumnHarness: View {
    let store: ComposerEditorHarnessStore

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ComposerEditorHarness(store: store)
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { _ in
                        Color.clear.frame(width: 28, height: 22)
                    }
                    Spacer(minLength: 8)
                    Text("glm-5.3-flash").lineLimit(1)
                    Text("Medium").lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }
}

/// The field has to wrap at the column it occupies.
///
/// Measurement writes the proposed width onto the text view, because the text
/// container tracks the text view and that is what makes the measured height
/// and the visible line breaks agree. Most of the widths a layout pass
/// proposes are probes though: measured on macOS 26.6.2, one pass over the
/// real composer proposed 0, 4, 32, 196.5 and 714 points, and the live field
/// kept 196.5 inside a 714pt column — a message wrapping after a third of the
/// line it had room for.
@Test("The message field wraps at the column it occupies, not at a probe width")
@MainActor
func editorWrapsAtTheColumnItOccupies() async throws {
    _ = NSApplication.shared
    let store = ComposerEditorHarnessStore()
    // Long enough that the wrap width is visible in the height as well.
    store.text = String(repeating: "Hermes names the column. ", count: 6)
    let hosting = NSHostingView(rootView: ComposerColumnHarness(store: store))
    hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 260)
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
    defer {
        window.contentView = nil
        window.close()
    }
    hosting.layoutSubtreeIfNeeded()

    // The measurements a host runs for its own constraints, ordered after the
    // real layout. This is where the probe widths come from.
    _ = hosting.fittingSize
    _ = hosting.intrinsicContentSize
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()

    let textView = try #require(firstTextView(in: hosting))
    let field = try #require(textView.enclosingScrollView)
    // The column is genuinely wide, so a match below is not two small numbers
    // agreeing with each other.
    #expect(field.contentSize.width > 600)
    #expect(abs(textView.frame.width - field.contentSize.width) < 0.5)
    // And the text container followed, which is what decides the line breaks.
    let container = try #require(textView.textContainer)
    #expect(abs(container.size.width - field.contentSize.width) < 0.5)
}

/// Wrapped typing has to keep the caret in the visible band.
///
/// The field reports a bounded height to SwiftUI, but the document has to
/// grow with the laid-out text. If the document stays at the first line,
/// the next wrapped line is off the field and no amount of scrolling can
/// bring it back. After eight lines the field stops growing and scrolls.
@Test("Wrapped typing keeps the caret in view and lets overflow scroll")
@MainActor
func wrappedTypingKeepsCaretInViewAndLetsOverflowScroll() async throws {
    _ = NSApplication.shared
    let store = ComposerEditorHarnessStore()
    let hosting = NSHostingView(rootView: ComposerEditorHarness(store: store))
    hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 280)
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
    defer {
        window.contentView = nil
        window.close()
    }
    hosting.layoutSubtreeIfNeeded()

    let editor = try #require(firstTextView(in: hosting))
    #expect(window.makeFirstResponder(editor))

    // Short words in a 360pt column wrap well before eight lines.
    let wrapped = String(repeating: "composer wrap ", count: 24)
    editor.insertText(wrapped, replacementRange: editor.selectedRange())
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()

    let live = try #require(firstTextView(in: hosting))
    let field = try #require(live.enclosingScrollView)
    #expect(lineFragmentCount(in: live) >= 3)
    #expect(field.frame.height > CGFloat(ComposerEditorHeightPolicy.minimum))
    #expect(field.frame.height <= CGFloat(ComposerEditorHeightPolicy.maximum))
    #expect(documentContainsLaidOutText(live))
    #expect(visibleBandContainsInsertionLine(live))

    // Past the eight line cap the field stays at the cap, and the document
    // has to grow so the caret and the last line can scroll into view.
    let overflow = String(repeating: "\ncomposer wrap overflow", count: 16)
    live.insertText(overflow, replacementRange: live.selectedRange())
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()

    let overflowing = try #require(firstTextView(in: hosting))
    let overflowingField = try #require(overflowing.enclosingScrollView)
    let maximum = CGFloat(ComposerEditorHeightPolicy.maximum)
    #expect(abs(overflowingField.frame.height - maximum) < 1)
    #expect(documentContainsLaidOutText(overflowing))
    #expect(overflowing.frame.height > overflowingField.contentSize.height + 1)

    overflowing.scroll(NSPoint.zero)
    hosting.layoutSubtreeIfNeeded()
    #expect(!visibleBandContainsInsertionLine(overflowing))

    let bottom = NSPoint(
        x: 0,
        y: max(0, overflowing.frame.height - overflowingField.contentSize.height)
    )
    overflowing.scroll(bottom)
    hosting.layoutSubtreeIfNeeded()
    #expect(visibleBandContainsInsertionLine(overflowing))

    overflowing.scroll(NSPoint.zero)
    hosting.layoutSubtreeIfNeeded()
    overflowing.scrollRangeToVisible(overflowing.selectedRange())
    hosting.layoutSubtreeIfNeeded()
    #expect(visibleBandContainsInsertionLine(overflowing))
}

/// A graphic pasted into the field must not become Markdown source.
///
/// NSTextView can insert an NSTextAttachment whose character is U+FFFC.
/// That character is not a file, and sending it submits garbage. The field
/// keeps the surrounding text and refuses the graphic.
@Test("Pasted graphics do not enter Markdown source")
@MainActor
func pastedGraphicsDoNotEnterMarkdownSource() async throws {
    _ = NSApplication.shared
    let store = ComposerEditorHarnessStore()
    let hosting = NSHostingView(rootView: ComposerEditorHarness(store: store))
    hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
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
    defer {
        window.contentView = nil
        window.close()
    }
    hosting.layoutSubtreeIfNeeded()

    let editor = try #require(firstTextView(in: hosting))
    #expect(window.makeFirstResponder(editor))
    editor.insertText("before ", replacementRange: editor.selectedRange())
    let attachment = NSTextAttachment()
    attachment.image = NSImage(size: NSSize(width: 8, height: 8))
    editor.textStorage?.append(NSAttributedString(attachment: attachment))
    editor.insertText(" after", replacementRange: editor.selectedRange())
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()

    let live = try #require(firstTextView(in: hosting))
    #expect(!live.string.contains("\u{FFFC}"))
    #expect(!store.text.contains("\u{FFFC}"))
    #expect(store.text.contains("before"))
    #expect(store.text.contains("after"))
}

/// Format must be an undo step. Otherwise Cmd-Z undoes the last typed
/// characters against Markdown source and the patch drops characters.
@Test("Format then undo restores the typed source")
@MainActor
func formatThenUndoRestoresTypedSource() async throws {
    _ = NSApplication.shared
    let store = ComposerEditorHarnessStore()
    let hosting = NSHostingView(rootView: ComposerEditorHarness(store: store))
    hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
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
    defer {
        window.contentView = nil
        window.close()
    }
    hosting.layoutSubtreeIfNeeded()

    let editor = try #require(firstTextView(in: hosting))
    #expect(window.makeFirstResponder(editor))
    editor.insertText("hello world", replacementRange: editor.selectedRange())
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()
    editor.setSelectedRange(NSRange(location: 0, length: 5))
    store.formatRequest = .strong
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()

    let formatted = try #require(firstTextView(in: hosting))
    #expect(store.text == "**hello** world")
    #expect(formatted.string == "hello world")
    #expect(formatted.undoManager?.canUndo == true)
    formatted.undoManager?.undo()
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()

    let restored = try #require(firstTextView(in: hosting))
    #expect(restored.string == "hello world")
    #expect(store.text == "hello world")
}

@Test("WYSIWYG typing at a list bullet edits the item text")
@MainActor
func wysiwygListPrefixEditKeepsListSource() async throws {
    _ = NSApplication.shared
    let store = ComposerEditorHarnessStore()
    store.text = "- item"
    let hosting = NSHostingView(rootView: ComposerEditorHarness(store: store))
    hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
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
    defer {
        window.contentView = nil
        window.close()
    }
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()

    let editor = try #require(firstTextView(in: hosting))
    #expect(window.makeFirstResponder(editor))
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    editor.insertText("X", replacementRange: editor.selectedRange())
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()

    #expect(store.text.hasPrefix("- "))
    #expect(store.text.contains("X"))
    #expect(!store.text.hasPrefix("X-"))
}

@Test("WYSIWYG typing at a quote bar edits the quote text")
@MainActor
func wysiwygQuotePrefixEditKeepsQuoteSource() async throws {
    _ = NSApplication.shared
    let store = ComposerEditorHarnessStore()
    store.text = "> hello"
    let hosting = NSHostingView(rootView: ComposerEditorHarness(store: store))
    hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
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
    defer {
        window.contentView = nil
        window.close()
    }
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()

    let editor = try #require(firstTextView(in: hosting))
    #expect(window.makeFirstResponder(editor))
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    editor.insertText("X", replacementRange: editor.selectedRange())
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()

    #expect(store.text.hasPrefix("> "))
    #expect(store.text.contains("X"))
    #expect(!store.text.hasPrefix("X>"))
}

@Test("WYSIWYG insert after bold text stays inside that span")
@MainActor
func wysiwygInsertAfterBoldStaysInSpan() async throws {
    _ = NSApplication.shared
    let store = ComposerEditorHarnessStore()
    store.text = "**aa** aa"
    let hosting = NSHostingView(rootView: ComposerEditorHarness(store: store))
    hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
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
    defer {
        window.contentView = nil
        window.close()
    }
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()

    let editor = try #require(firstTextView(in: hosting))
    #expect(window.makeFirstResponder(editor))
    editor.setSelectedRange(NSRange(location: 2, length: 0))
    editor.insertText("x", replacementRange: editor.selectedRange())
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()

    #expect(store.text == "**aax** aa")
}


@MainActor
private func firstTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
        if let found = firstTextView(in: subview) { return found }
    }
    return nil
}

@MainActor
private func lineFragmentCount(in textView: NSTextView) -> Int {
    guard let layoutManager = textView.layoutManager else { return 0 }
    var count = 0
    var glyphIndex = 0
    let glyphCount = layoutManager.numberOfGlyphs
    while glyphIndex < glyphCount {
        var lineRange = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
        count += 1
        glyphIndex = NSMaxRange(lineRange)
    }
    return count
}

@MainActor
private func documentContainsLaidOutText(_ textView: NSTextView) -> Bool {
    guard let layoutManager = textView.layoutManager,
          let container = textView.textContainer else { return false }
    let used = layoutManager.usedRect(for: container)
    let needed = used.height + textView.textContainerInset.height * 2
    return textView.frame.height + 1 >= needed
}

@MainActor
private func insertionLineRect(in textView: NSTextView) -> NSRect {
    guard let layoutManager = textView.layoutManager else { return .zero }
    let length = (textView.string as NSString).length
    let origin = textView.textContainerOrigin
    if length == 0 || layoutManager.numberOfGlyphs == 0 {
        return layoutManager.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
    }
    let location = min(textView.selectedRange().location, length)
    if location >= length, layoutManager.extraLineFragmentRect.height > 0 {
        return layoutManager.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
    }
    let characterIndex = min(max(0, location), length - 1)
    let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
    var lineRange = NSRange()
    let rect = layoutManager.lineFragmentRect(
        forGlyphAt: min(glyphIndex, layoutManager.numberOfGlyphs - 1),
        effectiveRange: &lineRange
    )
    return rect.offsetBy(dx: origin.x, dy: origin.y)
}

@MainActor
private func visibleBandContainsInsertionLine(_ textView: NSTextView) -> Bool {
    let line = insertionLineRect(in: textView)
    let visible = textView.visibleRect.insetBy(dx: 0, dy: -1)
    return visible.maxY > line.minY && visible.minY < line.maxY
}

/// New-chat typing is the flicker path: route identity `new`, a live
/// ComposerView, and one character at a time.
///
/// Characters only grow the draft, so the field height never drops.
/// A wrap may raise the height once. Identical new-chat route republishes
/// must not prefetch inventory or scroll a caret that is already visible.
@Test("Typing on a new chat does not oscillate composer height")
@MainActor
func typingOnNewChatDoesNotOscillateHeight() async throws {
    _ = NSApplication.shared
    let model = makeNewChatComposerModel()
    let hosting = NSHostingView(rootView: ComposerView(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 280)
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
    defer {
        window.contentView = nil
        window.close()
    }
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()

    let editor = try #require(firstTextView(in: hosting))
    #expect(window.makeFirstResponder(editor))

    ComposerTypingProbe.begin(owner: model)
    defer { _ = ComposerTypingProbe.finish() }

    let message = "Hermes, name the composer flicker, its cause, and the one "
        + "layout rule that ends it, in a single plain sentence."
    var heights: [CGFloat] = []
    var wraps: [Int] = []
    for character in message {
        editor.insertText(String(character), replacementRange: editor.selectedRange())
        ComposerTypingProbe.noteKeystroke(from: model)
        model.update(route: model.route)
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()

        let live = try #require(firstTextView(in: hosting))
        let field = try #require(live.enclosingScrollView)
        heights.append(field.frame.height)
        wraps.append(lineFragmentCount(in: live))
    }

    #expect(model.text.count == message.count)
    let snapshot = ComposerTypingProbe.snapshot
    #expect(snapshot.keystrokes == message.count)
    let wrapSteps = zip(wraps, wraps.dropFirst()).filter { $0.1 > $0.0 }.count
    let heightDrops = zip(heights, heights.dropFirst()).filter { $0.1 + 0.5 < $0.0 }.count
    ComposerTypingProbe.log("new-chat-typing")
    print(
        "COMPOSER_TYPING_HEIGHTS unique=\(Set(heights.map { Int(($0 * 10).rounded()) }).count)"
            + " first=\(heights.first ?? -1) last=\(heights.last ?? -1)"
            + " wrapsFirst=\(wraps.first ?? -1) wrapsLast=\(wraps.last ?? -1)"
            + " wrapSteps=\(wrapSteps) heightDrops=\(heightDrops)"
    )
    #expect(heightDrops == 0)
    let appliedChanges = zip(heights, heights.dropFirst()).filter { $0.1 > $0.0 + 0.5 }.count
    #expect(appliedChanges <= wrapSteps)
    #expect(snapshot.heightChangeCount <= wrapSteps + 1)
    #expect(snapshot.prefetchCount == 0)
    #expect(snapshot.requestInventoryCount == 0)
    #expect(snapshot.caretScrollCount <= wrapSteps)
}



/// Parallel `swift test` mounts other composers in the same process.
/// Prefetch and inventory notes from those composers must not land in
/// this snapshot. Defended by typingOnNewChatDoesNotOscillateHeight.
@Test("Typing probe records only the composer under test")
@MainActor
func typingProbeRecordsOnlyTheComposerUnderTest() {
    let measured = makeNewChatComposerModel()
    let other = makeNewChatComposerModel()
    ComposerTypingProbe.begin(owner: measured)
    defer { _ = ComposerTypingProbe.finish() }

    _ = other.mount()
    other.update(route: ComposerRoute(identity: "other"))
    #expect(ComposerTypingProbe.snapshot.prefetchCount == 0)
    #expect(ComposerTypingProbe.snapshot.requestInventoryCount == 0)
    #expect(ComposerTypingProbe.snapshot.routeUpdateCount == 0)

    measured.update(route: measured.route)
    #expect(ComposerTypingProbe.snapshot.routeUpdateCount == 1)
    #expect(ComposerTypingProbe.snapshot.prefetchCount == 0)
    #expect(ComposerTypingProbe.snapshot.requestInventoryCount == 0)
}

@MainActor
private func makeNewChatComposerModel() -> ComposerModel {
    ComposerModel(
        route: ComposerRoute(identity: "new"),
        runtime: TypingRuntimeStub(),
        attachmentStaging: TypingAttachmentStub(),
        turn: nil
    )
}

private struct TypingRuntimeStub: SessionRuntimeControlling {
    func modelInventory(sessionID: String?, refresh: Bool) async throws -> ModelInventory {
        ModelInventory(providers: [])
    }

    func setModel(_ model: String, provider: String?, sessionID: String) async throws -> ModelSwitchOutcome {
        ModelSwitchOutcome(appliedValue: model, isDeferredToNextTurn: false)
    }

    func setReasoning(_ setting: ReasoningSetting, sessionID: String) async throws {}
}

private struct TypingAttachmentStub: AttachmentStaging {
    func stageBatch(
        _ steps: [ComposerStagingStep],
        sessionID: String,
        routeIdentity: String,
        progress: @escaping @Sendable (UUID, Int) -> Void,
        reusing receipts: [AttachmentStagingReceipt]
    ) async throws -> any AttachmentStagingTransaction {
        throw AttachmentStagingError.invalidRoute
    }
}
