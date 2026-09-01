import Foundation
import Testing

@testable import HermternalCore

/// The rules of the composer's floating formatting toolbar.
///
/// The toolbar has one state machine and one piece of arithmetic, and both
/// are pure, so the behaviour a reader sees can be stated without a window.
struct ComposerFormattingToolbarPolicyTests {
    // MARK: - The state machine

    @Test("a selection shows the toolbar and an empty selection hides it")
    func selectionDrivesVisibility() {
        var state = ComposerFormattingToolbarState()
        #expect(!state.isVisible)
        let shown = state.selectionChanged(isEmpty: false, isFocused: true)
        #expect(shown)
        #expect(state.isVisible)
        #expect(state.trigger == .selection)
        // A second selection changes nothing the caller has to write.
        let repeated = state.selectionChanged(isEmpty: false, isFocused: true)
        #expect(!repeated)
        let emptied = state.selectionChanged(isEmpty: true, isFocused: true)
        #expect(emptied)
        #expect(!state.isVisible)
    }

    @Test("an unfocused field never shows the toolbar")
    func selectionWithoutFocusStaysHidden() {
        var state = ComposerFormattingToolbarState()
        let changed = state.selectionChanged(isEmpty: false, isFocused: false)
        #expect(!changed)
        #expect(!state.isVisible)
    }

    @Test("focus loss hides the toolbar and focus alone never shows it")
    func focusLossHidesTheToolbar() {
        var state = ComposerFormattingToolbarState()
        state.selectionChanged(isEmpty: false, isFocused: true)
        let lost = state.focusChanged(isFocused: false)
        #expect(lost)
        #expect(!state.isVisible)
        let gained = state.focusChanged(isFocused: true)
        #expect(!gained)
        #expect(!state.isVisible)
    }

    @Test("Escape closes the toolbar once, and reports whether it did")
    func escapeClosesOnce() {
        var state = ComposerFormattingToolbarState()
        // Nothing to close: Escape belongs to the next handler.
        let idle = state.escaped()
        #expect(!idle)
        state.selectionChanged(isEmpty: false, isFocused: true)
        let closed = state.escaped()
        #expect(closed)
        #expect(!state.isVisible)
        let again = state.escaped()
        #expect(!again)
    }

    @Test("the keyboard summon shows the toolbar with no selection")
    func summonShowsTheToolbar() {
        var state = ComposerFormattingToolbarState()
        let summoned = state.summoned()
        #expect(summoned)
        #expect(state.isVisible)
        #expect(state.isSummoned)
        // A caret move arrives as an empty selection, and dismisses it.
        let moved = state.selectionChanged(isEmpty: true, isFocused: true)
        #expect(moved)
        #expect(!state.isVisible)
    }

    @Test("a selection replaces a summon as the reason the toolbar is up")
    func selectionReplacesSummon() {
        var state = ComposerFormattingToolbarState()
        state.summoned()
        let changed = state.selectionChanged(isEmpty: false, isFocused: true)
        #expect(changed)
        #expect(state.isVisible)
        #expect(!state.isSummoned)
    }

    @Test("a read-only route refuses the toolbar and closes an open one")
    func readOnlyRouteRefusesTheToolbar() {
        var state = ComposerFormattingToolbarState()
        state.selectionChanged(isEmpty: false, isFocused: true)
        let disabled = state.setEnabled(false)
        #expect(disabled)
        #expect(!state.isVisible)
        let refusedSelection = state.selectionChanged(isEmpty: false, isFocused: true)
        #expect(!refusedSelection)
        let refusedSummon = state.summoned()
        #expect(!refusedSummon)
        // Enabling alone shows nothing. The next selection does.
        let enabled = state.setEnabled(true)
        #expect(!enabled)
        let shown = state.selectionChanged(isEmpty: false, isFocused: true)
        #expect(shown)
    }

    @Test("a selection scrolled out of the band takes the toolbar with it")
    func lostAnchorHidesTheToolbar() {
        var state = ComposerFormattingToolbarState()
        state.selectionChanged(isEmpty: false, isFocused: true)
        let lost = state.anchorLost()
        #expect(lost)
        #expect(!state.isVisible)
    }

    // MARK: - Placement

    @Test("the toolbar rests above the selection whenever the band has room")
    func placementPrefersAbove() {
        let placement = ComposerFormattingToolbarLayout.placement(
            selectionTop: 80,
            selectionBottom: 96,
            viewportHeight: 168
        )
        #expect(placement == .above)
        let originY = ComposerFormattingToolbarLayout.originY(
            placement: placement,
            selectionTop: 80,
            selectionBottom: 96,
            viewportHeight: 168
        )
        #expect(
            originY
                == 80 - ComposerFormattingToolbarLayout.gap
                - ComposerFormattingToolbarLayout.height
        )
    }

    @Test("a selection on the first line puts the toolbar below it")
    func placementFallsBackToBelow() {
        // The first line leaves no room above, and an eight line field has
        // room below.
        let placement = ComposerFormattingToolbarLayout.placement(
            selectionTop: 2,
            selectionBottom: 18,
            viewportHeight: 168
        )
        #expect(placement == .below)
        let originY = ComposerFormattingToolbarLayout.originY(
            placement: placement,
            selectionTop: 2,
            selectionBottom: 18,
            viewportHeight: 168
        )
        #expect(originY == 18 + ComposerFormattingToolbarLayout.gap)
    }

    @Test("a one line field holds the toolbar inside the band")
    func placementClampsInsideAShortBand() {
        // The field's own minimum is the shortest band the composer ever
        // draws, and it is shorter than the strip plus its gap. No side is
        // fully clear then, so the side with more room wins and the origin is
        // held inside the band. The strip covers the selected line, which is
        // the line the reader just chose, and it leaves with the selection.
        let viewportHeight = ComposerEditorHeightPolicy.minimum
        let selectionTop: Double = 7
        let selectionBottom: Double = 24
        let placement = ComposerFormattingToolbarLayout.placement(
            selectionTop: selectionTop,
            selectionBottom: selectionBottom,
            viewportHeight: viewportHeight
        )
        #expect(placement == .below)
        let originY = ComposerFormattingToolbarLayout.originY(
            placement: placement,
            selectionTop: selectionTop,
            selectionBottom: selectionBottom,
            viewportHeight: viewportHeight
        )
        #expect(originY >= 0)
        #expect(originY + ComposerFormattingToolbarLayout.height <= viewportHeight)
    }

    @Test("the toolbar centres on the selection and never leaves the field")
    func originXCentresAndClamps() {
        let width = ComposerFormattingToolbarLayout.width
        let centred = ComposerFormattingToolbarLayout.originX(
            selectionCenterX: 300,
            viewportWidth: 600
        )
        #expect(centred == 300 - width / 2)
        // A selection at the leading edge cannot push the strip outside.
        #expect(
            ComposerFormattingToolbarLayout.originX(
                selectionCenterX: 4,
                viewportWidth: 600
            ) == 0
        )
        let trailing = ComposerFormattingToolbarLayout.originX(
            selectionCenterX: 596,
            viewportWidth: 600
        )
        #expect(trailing == 600 - width)
        // A field narrower than the strip pins it at the leading edge.
        #expect(
            ComposerFormattingToolbarLayout.originX(
                selectionCenterX: 40,
                viewportWidth: width - 20
            ) == 0
        )
    }

    @Test("a selection outside the visible band has no anchor")
    func anchorVisibility() {
        #expect(ComposerFormattingToolbarLayout.anchorIsVisible(
            selectionTop: 10,
            selectionBottom: 26,
            viewportHeight: 168
        ))
        #expect(!ComposerFormattingToolbarLayout.anchorIsVisible(
            selectionTop: -40,
            selectionBottom: -24,
            viewportHeight: 168
        ))
        #expect(!ComposerFormattingToolbarLayout.anchorIsVisible(
            selectionTop: 200,
            selectionBottom: 216,
            viewportHeight: 168
        ))
    }

    @Test("the strip is exactly five items wide")
    func stripWidthHoldsFiveItems() {
        let layout = ComposerFormattingToolbarLayout.self
        let visible = Double(ComposerFormattingToolbarCatalog.visibleItemCount)
        #expect(
            layout.contentWidth
                == visible * layout.itemWidth + (visible - 1) * layout.itemSpacing
        )
        #expect(layout.width == layout.contentWidth + layout.horizontalPadding * 2)
        #expect(layout.height == layout.itemHeight + layout.verticalPadding * 2)
    }

    // MARK: - The catalog

    @Test("the five visible items are the ones the spec names")
    func visibleItemsAreTheSpecifiedFive() {
        let visible = ComposerFormattingToolbarCatalog.items
            .prefix(ComposerFormattingToolbarCatalog.visibleItemCount)
            .map(\.action)
        #expect(visible == [
            .format(.strong),
            .format(.emphasis),
            .format(.inlineCode),
            .format(.link),
            .format(.strikethrough)
        ])
    }

    @Test("the tail holds every remaining action of the deleted Format row")
    func tailHoldsTheRemainingActions() {
        let tail = ComposerFormattingToolbarCatalog.items
            .dropFirst(ComposerFormattingToolbarCatalog.visibleItemCount)
            .map(\.action)
        #expect(tail == [
            .format(.heading),
            .format(.unorderedList),
            .format(.orderedList),
            .format(.quote),
            .format(.fencedCode),
            .toggleSource
        ])
    }

    @Test("every formatting command the editor understands is reachable")
    func everyFormatIsReachable() {
        let reachable = Set(
            ComposerFormattingToolbarCatalog.items.compactMap { item -> ComposerEditorFormat? in
                guard case let .format(format) = item.action else { return nil }
                return format
            }
        )
        #expect(reachable == Set(ComposerEditorFormat.allCases))
    }

    @Test("no two items claim the same key equivalent or identifier")
    func itemsAreDistinct() {
        let items = ComposerFormattingToolbarCatalog.items
        let identifiers = Set(items.map(\.identifier))
        #expect(identifiers.count == items.count)
        let shortcuts = items.compactMap { item -> String? in
            guard let key = item.key else { return nil }
            return "\(key)-\(item.modifiers.rawValue)"
        }
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test("the source item states the mode it would move to")
    func sourceItemStatesItsDestination() {
        #expect(ComposerFormattingToolbarCatalog.sourceTitle(for: .wysiwyg) == "Source")
        #expect(
            ComposerFormattingToolbarCatalog.sourceTitle(for: .source)
                == "Show Formatted Text"
        )
        #expect(
            ComposerFormattingToolbarCatalog.sourceSymbolName(for: .wysiwyg)
                != ComposerFormattingToolbarCatalog.sourceSymbolName(for: .source)
        )
    }

    // MARK: - Formatting

    @Test("the two new commands write the Markdown they claim")
    func newCommandsWriteTheirMarkdown() {
        let strike = ComposerEditorFormatter.apply(
            .strikethrough,
            source: "gone",
            selectedRange: 0..<4
        )
        #expect(strike.source == "~~gone~~")
        #expect(strike.selectedRange == 2..<6)

        let numbered = ComposerEditorFormatter.apply(
            .orderedList,
            source: "first",
            selectedRange: 0..<5
        )
        #expect(numbered.source == "1. first")
        #expect(numbered.selectedRange == 3..<8)
    }

    // MARK: - Motion

    @Test("reduced motion runs the same path at duration zero")
    func motionPolicy() {
        #expect(ComposerFormattingToolbarMotion.duration(reducesMotion: true) == 0)
        #expect(
            ComposerFormattingToolbarMotion.duration(reducesMotion: false)
                == ComposerFormattingToolbarMotion.response
        )
        // A pop, not a jump: nothing arrives from nothing.
        #expect(ComposerFormattingToolbarMotion.scale > 0.9)
        #expect(ComposerFormattingToolbarMotion.scale < 1)
        // Fast enough for a surface a reader meets on every selection.
        #expect(ComposerFormattingToolbarMotion.response <= 0.2)
    }
}
