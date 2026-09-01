import Foundation

/// One action the floating formatting toolbar can run.
///
/// Every case names work the composer already does. `format` reaches
/// `ComposerEditorFormatter`, and `toggleSource` reaches the editor mode.
/// The toolbar therefore adds no formatting rule of its own.
public enum ComposerFormattingToolbarAction: Equatable, Hashable, Sendable {
    case format(ComposerEditorFormat)
    case toggleSource
}

/// One item in the toolbar strip.
///
/// The item carries its own glyph, title, identifier, and key equivalent, so
/// the strip is a list rather than a hand-written row of controls. The key
/// equivalent is stated as a character and a modifier set, because Core has
/// no view layer to hold a `KeyboardShortcut`.
public struct ComposerFormattingToolbarItem: Equatable, Hashable, Sendable, Identifiable {
    /// The modifiers a key equivalent needs. One flag per modifier the app
    /// uses today, so no platform type enters Core.
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
    }

    public let action: ComposerFormattingToolbarAction
    public let title: String
    public let symbolName: String
    public let identifier: String
    public let key: Character?
    public let modifiers: Modifiers

    public var id: ComposerFormattingToolbarAction { action }

    public init(
        action: ComposerFormattingToolbarAction,
        title: String,
        symbolName: String,
        identifier: String,
        key: Character? = nil,
        modifiers: Modifiers = []
    ) {
        self.action = action
        self.title = title
        self.symbolName = symbolName
        self.identifier = identifier
        self.key = key
        self.modifiers = modifiers
    }
}

/// The items the toolbar shows, in the one order it shows them.
///
/// The first `visibleItemCount` items are the actions a message needs most
/// often, and they fit the strip without a scroll. The tail holds the block
/// level actions and the source toggle, which the old Format row also held.
/// Nothing else was in that row, so the cutover loses no action.
///
/// The key equivalents are the ones the Format row carried, so a person who
/// learned them keeps them. They are live while the toolbar is on screen,
/// which is when a selection exists and a formatting action has a target.
public enum ComposerFormattingToolbarCatalog {
    /// How many items the strip shows before the reader scrolls.
    public static let visibleItemCount = 5

    public static let items: [ComposerFormattingToolbarItem] = [
        ComposerFormattingToolbarItem(
            action: .format(.strong),
            title: "Bold",
            symbolName: "bold",
            identifier: "composer-toolbar-bold",
            key: "b",
            modifiers: .command
        ),
        ComposerFormattingToolbarItem(
            action: .format(.emphasis),
            title: "Italic",
            symbolName: "italic",
            identifier: "composer-toolbar-italic",
            key: "i",
            modifiers: .command
        ),
        ComposerFormattingToolbarItem(
            action: .format(.inlineCode),
            title: "Code",
            symbolName: "chevron.left.forwardslash.chevron.right",
            identifier: "composer-toolbar-inline-code",
            key: "`",
            modifiers: .command
        ),
        ComposerFormattingToolbarItem(
            action: .format(.link),
            title: "Link",
            symbolName: "link",
            identifier: "composer-toolbar-link",
            key: "k",
            modifiers: .command
        ),
        ComposerFormattingToolbarItem(
            action: .format(.strikethrough),
            title: "Strikethrough",
            symbolName: "strikethrough",
            identifier: "composer-toolbar-strikethrough",
            key: "x",
            modifiers: [.command, .shift]
        ),
        ComposerFormattingToolbarItem(
            action: .format(.heading),
            title: "Heading",
            symbolName: "textformat.size",
            identifier: "composer-toolbar-heading",
            key: "1",
            modifiers: [.command, .shift]
        ),
        ComposerFormattingToolbarItem(
            action: .format(.unorderedList),
            title: "Bulleted List",
            symbolName: "list.bullet",
            identifier: "composer-toolbar-list",
            key: "8",
            modifiers: [.command, .shift]
        ),
        ComposerFormattingToolbarItem(
            action: .format(.orderedList),
            title: "Numbered List",
            symbolName: "list.number",
            identifier: "composer-toolbar-numbered-list",
            key: "7",
            modifiers: [.command, .shift]
        ),
        ComposerFormattingToolbarItem(
            action: .format(.quote),
            title: "Quote",
            symbolName: "text.quote",
            identifier: "composer-toolbar-quote",
            key: ">",
            modifiers: [.command, .shift]
        ),
        ComposerFormattingToolbarItem(
            action: .format(.fencedCode),
            title: "Code Block",
            symbolName: "curlybraces",
            identifier: "composer-toolbar-code-block"
        ),
        ComposerFormattingToolbarItem(
            action: .toggleSource,
            title: "Source",
            symbolName: "doc.plaintext",
            identifier: "composer-toolbar-source",
            key: "m",
            modifiers: [.command, .shift]
        )
    ]

    /// The title of the source item for the mode the editor is in now.
    ///
    /// The item states what it would do, which is the rule the Format row
    /// used, so the label never claims the mode the editor already shows.
    public static func sourceTitle(for mode: ComposerEditorMode) -> String {
        mode == .source ? "Show Formatted Text" : "Source"
    }

    /// The glyph of the source item for the mode the editor is in now.
    public static func sourceSymbolName(for mode: ComposerEditorMode) -> String {
        mode == .source ? "doc.richtext" : "doc.plaintext"
    }
}

/// Which side of the selection the toolbar rests on.
public enum ComposerFormattingToolbarPlacement: String, Equatable, Hashable, Sendable {
    case above
    case below
}

/// The metrics and the arithmetic that place the strip.
///
/// Every value is a point count in the editor's own visible band, whose
/// origin is the top leading corner. The functions are pure, so a test can
/// state the placement of a selection without a window.
public enum ComposerFormattingToolbarLayout {
    /// One item's hit target. Two points wider than the glyph box below it,
    /// because a control that is only as wide as its glyph is hard to hit.
    public static let itemWidth: Double = 30
    public static let itemHeight: Double = 24
    public static let itemSpacing: Double = 2
    public static let horizontalPadding: Double = 6
    public static let verticalPadding: Double = 4

    /// The distance the strip keeps from the selected line.
    ///
    /// Enough that the glass edge never touches a glyph, small enough that
    /// the strip still reads as belonging to that line.
    public static let gap: Double = 6

    public static var height: Double { itemHeight + verticalPadding * 2 }

    /// The width of the scrolling viewport: exactly `visibleItemCount` items.
    public static var contentWidth: Double {
        let count = Double(ComposerFormattingToolbarCatalog.visibleItemCount)
        return count * itemWidth + (count - 1) * itemSpacing
    }

    /// The width of the whole strip, glass included.
    public static var width: Double { contentWidth + horizontalPadding * 2 }

    /// Picks the side of the selection the strip rests on.
    ///
    /// Above is the answer whenever the band has room for the strip and its
    /// gap. Below is the answer when it does not. A one line field is shorter
    /// than the strip and its gap, so it has no fully clear side: the side
    /// with more room wins, and `originY` holds the strip inside the band.
    /// The strip then covers the line the reader just selected, and it leaves
    /// with the selection. Nothing may draw outside the field, because the
    /// transcript is directly above the composer panel.
    public static func placement(
        selectionTop: Double,
        selectionBottom: Double,
        viewportHeight: Double
    ) -> ComposerFormattingToolbarPlacement {
        let needed = height + gap
        let roomAbove = selectionTop
        let roomBelow = viewportHeight - selectionBottom
        if roomAbove >= needed { return .above }
        if roomBelow >= needed { return .below }
        return roomAbove >= roomBelow ? .above : .below
    }

    /// The top of the strip, held inside the band.
    public static func originY(
        placement: ComposerFormattingToolbarPlacement,
        selectionTop: Double,
        selectionBottom: Double,
        viewportHeight: Double
    ) -> Double {
        let raw = placement == .above
            ? selectionTop - gap - height
            : selectionBottom + gap
        return min(max(0, raw), max(0, viewportHeight - height))
    }

    /// The leading edge of the strip: centred on the selection, held inside
    /// the band, so the strip never reaches past the field it belongs to.
    public static func originX(
        selectionCenterX: Double,
        viewportWidth: Double
    ) -> Double {
        let raw = selectionCenterX - width / 2
        return min(max(0, raw), max(0, viewportWidth - width))
    }

    /// True while any part of the selected text is inside the visible band.
    ///
    /// A selection scrolled out of the band has nothing to point at, and a
    /// strip that stayed would name a line the reader cannot see.
    public static func anchorIsVisible(
        selectionTop: Double,
        selectionBottom: Double,
        viewportHeight: Double
    ) -> Bool {
        selectionBottom > 0 && selectionTop < viewportHeight
    }
}

/// The one reason the toolbar is on screen.
public enum ComposerFormattingToolbarTrigger: String, Equatable, Hashable, Sendable {
    /// The reader selected text.
    case selection
    /// The reader asked for the toolbar from the keyboard.
    case summon
}

/// When the floating toolbar is on screen, and why.
///
/// The toolbar appears for a selection in the composer editor, and for the
/// one keyboard summon. It leaves when the selection empties, when the field
/// loses focus, when the reader presses Escape, and when the composer route
/// refuses editing. Every mutation reports whether the answer changed, so the
/// caller writes view state only for a real change.
public struct ComposerFormattingToolbarState: Equatable, Sendable {
    public private(set) var trigger: ComposerFormattingToolbarTrigger?
    public private(set) var isEnabled: Bool

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
        self.trigger = nil
    }

    public var isVisible: Bool { trigger != nil }

    /// True while the toolbar is on screen because of the keyboard summon.
    /// The summoned toolbar takes the first item's focus.
    public var isSummoned: Bool { trigger == .summon }

    /// The editor reported a new selection.
    ///
    /// A non-empty selection in a focused field shows the toolbar. An empty
    /// selection hides it, which is also what dismisses a summoned toolbar
    /// once the reader moves the caret or types.
    @discardableResult
    public mutating func selectionChanged(isEmpty: Bool, isFocused: Bool) -> Bool {
        guard isEnabled, isFocused, !isEmpty else { return set(nil) }
        return set(.selection)
    }

    @discardableResult
    public mutating func focusChanged(isFocused: Bool) -> Bool {
        isFocused ? false : set(nil)
    }

    /// Escape closes the toolbar. The result states whether Escape did that
    /// work, so the caller only consumes the key press when it did.
    @discardableResult
    public mutating func escaped() -> Bool {
        set(nil)
    }

    /// The keyboard summon. It shows the toolbar at the caret, with or
    /// without a selection, provided the composer accepts edits.
    @discardableResult
    public mutating func summoned() -> Bool {
        guard isEnabled else { return false }
        return set(.summon)
    }

    /// The selection left the visible band, so the toolbar has no anchor.
    @discardableResult
    public mutating func anchorLost() -> Bool {
        set(nil)
    }

    /// A read-only route refuses formatting, so the toolbar cannot show.
    @discardableResult
    public mutating func setEnabled(_ enabled: Bool) -> Bool {
        guard isEnabled != enabled else { return false }
        isEnabled = enabled
        return enabled ? false : set(nil)
    }

    private mutating func set(_ next: ComposerFormattingToolbarTrigger?) -> Bool {
        guard trigger != next else { return false }
        trigger = next
        return true
    }
}

/// The one motion the toolbar has.
///
/// A pop is right here and a travel is not: the strip belongs to the line the
/// reader just selected, so it grows from that line rather than sliding in
/// from somewhere else. The scale starts near one, because nothing in view
/// arrives from nothing.
///
/// Reduced motion drops the animation and keeps the same path at duration
/// zero, matching `TranscriptMotion.duration(reducesMotion:)`.
public enum ComposerFormattingToolbarMotion {
    /// The one duration the toolbar animates for, in seconds.
    public static let response: Double = 0.14

    /// The scale the strip enters and leaves at.
    public static let scale: Double = 0.96

    public static func duration(reducesMotion: Bool) -> Double {
        reducesMotion ? 0 : response
    }
}
