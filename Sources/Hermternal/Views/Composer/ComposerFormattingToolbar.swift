import HermternalCore
import SwiftUI

/// The floating formatting toolbar of the composer editor.
///
/// The strip appears over the message field while text is selected, and it
/// points at the line that holds the selection. It is the only formatting
/// affordance the composer has: the Format control and the row it opened are
/// gone, so nothing takes composer height for a set of actions that only a
/// selection can use.
///
/// The surface is Liquid Glass, and it is the same composition the composer
/// panel and the search panel already draw: `glassEffect(.regular
/// .interactive(), in:)`. That effect samples in-window content, which is
/// what a strip over live text needs — verified on macOS 26.6.2 by a probe
/// that floated this capsule over an `NSTextView`, where the glyphs under the
/// capsule refract. A SwiftUI `Material` samples behind the window and could
/// not do this.
///
/// Reduce Transparency replaces the glass with one opaque standard material,
/// because a strip over text has to stay legible when the reader asked the
/// system for less translucency.
///
/// Five items fit the strip. The rest scroll, and the system draws the
/// scroller. Every item is one action the old Format row also had.
struct ComposerFormattingToolbar: View {
    let mode: ComposerEditorMode
    let placement: ComposerFormattingToolbarPlacement
    let isSummoned: Bool
    /// Rises on every keyboard summon, so a second summon focuses the first
    /// item again without the strip leaving the screen.
    let summonGeneration: Int
    let onAction: (ComposerFormattingToolbarAction) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @FocusState private var focusedAction: ComposerFormattingToolbarAction?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: ComposerFormattingToolbarLayout.itemSpacing) {
                ForEach(ComposerFormattingToolbarCatalog.items) { item in
                    itemButton(item)
                }
            }
        }
        // The system owns the scroller. A horizontal overlay scroller that
        // appears while the reader scrolls is the macOS answer here, and this
        // states it rather than leaving it to a default that could change.
        .scrollIndicators(.automatic, axes: .horizontal)
        .frame(
            width: ComposerFormattingToolbarLayout.contentWidth,
            height: ComposerFormattingToolbarLayout.itemHeight
        )
        .padding(.horizontal, ComposerFormattingToolbarLayout.horizontalPadding)
        .padding(.vertical, ComposerFormattingToolbarLayout.verticalPadding)
        .modifier(ComposerFormattingToolbarSurface(isOpaque: reduceTransparency))
        // The platform's own glass arrival. The strip reads as a material
        // that forms, rather than a picture that fades in.
        .glassEffectTransition(reduceMotion ? .identity : .materialize)
        .transition(transition)
        .onAppear { focusFirstItemIfSummoned() }
        .onChange(of: summonGeneration) { _, _ in focusFirstItemIfSummoned() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formatting")
        .accessibilityIdentifier("composer-formatting-toolbar")
    }

    /// The strip grows from the line it points at.
    ///
    /// Enter and exit take the same path, and the scale starts near one, so
    /// the strip never appears out of nothing. Reduced motion drops the
    /// travel and shows the strip at once.
    private var transition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .scale(
            scale: ComposerFormattingToolbarMotion.scale,
            anchor: placement == .above ? .bottom : .top
        )
        .combined(with: .opacity)
    }

    private func itemButton(_ item: ComposerFormattingToolbarItem) -> some View {
        // The source item states what it would do, so its title and glyph
        // follow the mode the editor is in now.
        let isSourceItem = item.action == .toggleSource
        let title = isSourceItem
            ? ComposerFormattingToolbarCatalog.sourceTitle(for: mode)
            : item.title
        let symbolName = isSourceItem
            ? ComposerFormattingToolbarCatalog.sourceSymbolName(for: mode)
            : item.symbolName
        return Button {
            onAction(item.action)
        } label: {
            Image(systemName: symbolName)
                // The strip is denser than the control row, and sits in the
                // same height class as the attachment chip row, so it takes
                // the chip glyph step rather than adding a third size.
                .font(ComposerIconMetrics.chip)
                .frame(
                    width: ComposerFormattingToolbarLayout.itemWidth,
                    height: ComposerFormattingToolbarLayout.itemHeight
                )
        }
        .buttonStyle(.borderless)
        .modifier(ComposerFormattingToolbarShortcut(item: item))
        // The strip joins the keyboard loop only while it was summoned from
        // the keyboard. A pointer selection must not add ten tab stops to the
        // composer.
        .focusable(isSummoned)
        .focused($focusedAction, equals: item.action)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(item.identifier)
    }

    private func focusFirstItemIfSummoned() {
        guard isSummoned else { return }
        focusedAction = ComposerFormattingToolbarCatalog.items.first?.action
    }
}

/// The surface under the strip, and the one fallback it has.
///
/// Reduce Transparency asks for less translucency, and this states the
/// answer rather than depending on how the glass effect adapts: one opaque
/// standard material in the same shape, so the strip keeps its geometry and
/// loses only the translucency.
private struct ComposerFormattingToolbarSurface: ViewModifier {
    let isOpaque: Bool

    @ViewBuilder func body(content: Content) -> some View {
        let shape = Capsule(style: .continuous)
        if isOpaque {
            content.background(.regularMaterial, in: shape)
        } else {
            content.glassEffect(.regular.interactive(), in: shape)
        }
    }
}

/// Applies the key equivalent the catalog states for one item.
///
/// The catalog holds a character and a modifier set, because Core has no view
/// layer. This is the one place that turns those into a `KeyboardShortcut`.
/// An item with no key equivalent never enters the key equivalent table.
private struct ComposerFormattingToolbarShortcut: ViewModifier {
    let item: ComposerFormattingToolbarItem

    @ViewBuilder func body(content: Content) -> some View {
        if let key = item.key {
            content.keyboardShortcut(
                KeyEquivalent(key),
                modifiers: Self.modifiers(item.modifiers)
            )
        } else {
            content
        }
    }

    private static func modifiers(
        _ modifiers: ComposerFormattingToolbarItem.Modifiers
    ) -> EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
}
