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
                    formatRequest: nil,
                    onSubmit: {},
                    onEscape: { false },
                    onFormatHandled: {}
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
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
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

@MainActor
private func firstTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
        if let found = firstTextView(in: subview) { return found }
    }
    return nil
}
