import Testing
@testable import HermternalCore

struct ComposerEditorStateTests {
    @Test("Markdown source round trips without normalization")
    func sourceRoundTrip() {
        let source = "# Title\n\n- one\n- **two**\n\n```swift\nlet value = 1\n```\n"
        let result = MarkdownDocument.parse(source)
        #expect(result.error == nil)
        #expect(MarkdownDocument.serialize(result.document) == source)
        #expect(result.document.serializedSource == source)
    }

    @Test("invalid Source remains Source with a precise error")
    func invalidSourceStaysVisible() {
        var state = ComposerEditorState(source: "```swift\nlet value = 1", mode: .source)
        #expect(state.mode == .source)
        #expect(state.error?.message == "Unterminated fenced code block")
        let switched = state.setMode(.wysiwyg)
        #expect(switched == false)
        #expect(state.mode == .source)
        #expect(state.source == "```swift\nlet value = 1")
    }

    @Test("valid Source enters WYSIWYG and preserves exact source")
    func validModeTransition() {
        let source = "**keep**  \nline"
        var state = ComposerEditorState(source: source, mode: .source)
        let enteredWYSIWYG = state.setMode(.wysiwyg)
        #expect(enteredWYSIWYG)
        #expect(state.mode == .wysiwyg)
        #expect(state.source == source)
        #expect(state.error == nil)
        let enteredSource = state.setMode(.source)
        #expect(enteredSource)
        #expect(state.source == source)
    }

    @Test("formatting wraps a UTF-16 selection and keeps its selection")
    func formattingSelection() {
        let edit = ComposerEditorFormatter.apply(
            .emphasis,
            source: "hello",
            selectedRange: 1..<4
        )
        #expect(edit.source == "h*ell*o")
        #expect(edit.selectedRange == 2..<5)
    }

    @Test("heading formats the whole selected line without duplicating its text")
    func headingFormatting() {
        let edit = ComposerEditorFormatter.apply(
            .heading,
            source: "Title",
            selectedRange: 0..<5
        )
        #expect(edit.source == "# Title")
        #expect(edit.selectedRange == 2..<7)
        #expect(MarkdownDocument.parse(edit.source).error == nil)
    }

    @Test("formatting does not lose non-ASCII source")
    func unicodeFormatting() {
        let source = "こんにちは"
        let edit = ComposerEditorFormatter.apply(
            .inlineCode,
            source: source,
            selectedRange: 0..<5
        )
        #expect(edit.source == "`こんにちは`")
        #expect(edit.selectedRange == 1..<6)
    }

    @Test("editor height stays modest when empty and caps after eight lines")
    func editorHeightPolicy() {
        #expect(ComposerEditorHeightPolicy.height(for: 0) == ComposerEditorHeightPolicy.minimum)
        #expect(ComposerEditorHeightPolicy.height(for: 20) == 38)
        #expect(ComposerEditorHeightPolicy.height(for: 400) == ComposerEditorHeightPolicy.maximum)
    }

    @Test("repeated focus layout does not publish another height")
    func repeatedLayoutSuppressesHeightChanges() {
        let current = ComposerEditorHeightPolicy.height(for: 25)
        var changes: [Double] = []
        for measurement in [25.0, 25.1, 24.9, 25.2, 25.0] {
            if let next = ComposerEditorHeightPolicy.nextHeight(
                measuredContentHeight: measurement,
                currentHeight: current
            ) {
                changes.append(next)
            }
        }
        #expect(current == 39)
        #expect(changes.isEmpty)
    }

    @Test("one added line publishes one bounded height change")
    func addedLinePublishesOneHeightChange() {
        let first = ComposerEditorHeightPolicy.nextHeight(
            measuredContentHeight: 25,
            currentHeight: ComposerEditorHeightPolicy.minimum
        )
        #expect(first == 39)
        let second = ComposerEditorHeightPolicy.nextHeight(
            measuredContentHeight: 42,
            currentHeight: first
        )
        #expect(second == 56)
        #expect((second ?? 0) <= ComposerEditorHeightPolicy.maximum)
    }

    @Test("empty editor always uses the minimum height")
    func emptyEditorHeight() {
        #expect(ComposerEditorHeightPolicy.height(for: 0) == ComposerEditorHeightPolicy.minimum)
        #expect(ComposerEditorHeightPolicy.height(for: -20) == ComposerEditorHeightPolicy.minimum)
    }

    @Test("only a real column width may become the editor height")
    func onlyRealColumnWidthsMeasureTheEditor() {
        // The proposals SwiftUI uses to learn how flexible a leaf view is,
        // and the unspecified proposal the adapter maps to none of these.
        #expect(!ComposerEditorHeightPolicy.isLayoutWidth(0))
        #expect(!ComposerEditorHeightPolicy.isLayoutWidth(1))
        #expect(!ComposerEditorHeightPolicy.isLayoutWidth(.infinity))
        #expect(!ComposerEditorHeightPolicy.isLayoutWidth(.nan))
        #expect(!ComposerEditorHeightPolicy.isLayoutWidth(-360))
        // A column the composer gives the message field.
        #expect(ComposerEditorHeightPolicy.isLayoutWidth(360))
        #expect(ComposerEditorHeightPolicy.shouldMeasureHeight(proposedWidth: 714, occupiedWidth: 714))
        #expect(!ComposerEditorHeightPolicy.shouldMeasureHeight(proposedWidth: 196.5, occupiedWidth: 714))
        #expect(!ComposerEditorHeightPolicy.shouldMeasureHeight(proposedWidth: 4, occupiedWidth: 714))
        #expect(!ComposerEditorHeightPolicy.shouldMeasureHeight(proposedWidth: 32, occupiedWidth: 714))
        #expect(!ComposerEditorHeightPolicy.shouldMeasureHeight(proposedWidth: 714, occupiedWidth: 0))

        // Why a probe may not be measured: the same one line of text answers
        // with the two ends of the range. A zero width breaks the line after
        // every glyph and reaches the cap, an infinite width reports one line,
        // and accepting either as the height alternated the composer between
        // them for as long as the draft held text.
        let oneLine: Double = 16
        #expect(
            ComposerEditorHeightPolicy.height(for: oneLine * 24)
                == ComposerEditorHeightPolicy.maximum
        )
        #expect(
            ComposerEditorHeightPolicy.height(for: oneLine)
                == ComposerEditorHeightPolicy.minimum
        )
    }

    @Test("the editor publishes only a real focus change")
    func focusPublicationPolicy() {
        #expect(ComposerEditorInteractionPolicy.shouldPublishFocusChange(
            from: false,
            to: true
        ))
        #expect(!ComposerEditorInteractionPolicy.shouldPublishFocusChange(
            from: true,
            to: true
        ))
    }
}
