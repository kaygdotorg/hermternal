import AppKit
import CoreText
import HermternalCore
import SwiftUI

/// One colour, resolved on the main actor for one effective appearance.
///
/// A dynamic catalog colour such as `NSColor.labelColor` has no value of its
/// own: it resolves against the appearance that is *current for drawing*, and
/// that appearance only exists on the main actor. Off the main actor the same
/// colour answers for whatever appearance happens to be current — Aqua — which
/// is how black text reached a dark transcript.
///
/// Carrying sRGB components instead of an `NSColor` lets off-main preparation
/// apply a concrete, already-correct colour without resolving anything. That is
/// what keeps shaping off the main actor and appearance-correct at the same
/// time.
private struct BlockInk: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Resolves `color` against the appearance currently set for drawing.
    ///
    /// Callers must already be inside
    /// `NSAppearance.performAsCurrentDrawingAppearance(_:)`; see
    /// `BlockRenderStyle.resolved(for:)`, which is the only caller.
    init(_ color: NSColor) {
        // Catalog, dynamic, and component colours all convert. A pattern
        // colour cannot, and this palette holds none; the mid grey keeps a
        // future pattern colour visible in both appearances rather than
        // letting it fall back to AppKit's opaque black default.
        guard let srgb = color.usingColorSpace(.sRGB) else {
            self.init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            return
        }
        self.init(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent),
            alpha: Double(srgb.alphaComponent)
        )
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }

    var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}

/// A deterministic 64-bit FNV-1a digest over a palette.
///
/// `Hasher` is seeded per process, which is fine for a dictionary but reads
/// poorly inside a cache key that is compared and logged. This gives the same
/// digest for the same palette every time.
private struct BlockStyleDigest {
    private var value: UInt64 = 14_695_981_039_346_656_037

    mutating func combine(_ number: Double) {
        var bits = number.bitPattern
        for _ in 0..<8 {
            value = (value ^ (bits & 0xFF)) &* 1_099_511_628_211
            bits >>= 8
        }
    }

    mutating func combine(_ ink: BlockInk) {
        combine(ink.red)
        combine(ink.green)
        combine(ink.blue)
        combine(ink.alpha)
    }

    mutating func combine(_ text: String) {
        for byte in text.utf8 {
            value = (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    var hexadecimal: String {
        String(value, radix: 16)
    }
}

/// Every appearance-dependent and type-scale value that off-main block
/// preparation needs, resolved once on the main actor.
///
/// The colours mirror the SwiftUI transcript one for one rather than inventing
/// a second palette: `MarkdownBlocks` draws prose at `.primary` with
/// `.secondary` list markers, `TranscriptCodeBlock` draws on
/// `.background.secondary` inside a `.separator` border, `MessageRow` tints the
/// user bubble with `.tint.opacity(0.16)` over `.primary` text, and
/// `FindTextHighlighting` marks the first match in a segment orange and the
/// rest yellow. Point sizes come from the same text styles
/// `MessageTypography` names, so the two renderers share one type scale
/// instead of two lists of numbers.
private struct BlockRenderStyle: Hashable, Sendable {
    /// Bumped whenever the drawn attributes or the measurement change, so a
    /// height cached by an older algorithm is never reused. Version 1 drew an
    /// unstyled string and measured a bare font.
    static let rendererVersion = 2

    /// `MessageRow`'s user bubble: `.padding(.vertical, 10)`.
    static let userVerticalInset: CGFloat = 10
    /// The assistant and system rows' own vertical rhythm.
    static let assistantVerticalInset: CGFloat = 8
    /// `TranscriptCodeBlock`'s `.padding(10)` around the body.
    static let codeVerticalInset: CGFloat = 10
    static let codeHorizontalInset: CGFloat = 10
    /// `TranscriptCodeBlock`'s header: `.padding(.vertical, 6)`.
    static let codeHeaderPadding: CGFloat = 6
    /// The header's `Divider()`.
    static let codeDividerHeight: CGFloat = 1
    /// `.strokeBorder(.separator, lineWidth: 0.5)`.
    static let codeBorderWidth: CGFloat = 0.5
    /// `FindHighlightedMessage`'s `.strokeBorder(.orange.opacity(0.8), lineWidth: 1)`.
    static let findBorderWidth: CGFloat = 1

    let appearanceName: String
    let isDark: Bool

    /// `.primary`, set once by `MarkdownBlocks` for the whole reply.
    let label: BlockInk
    /// `.secondary`: list markers, the code header, a system message.
    let secondaryLabel: BlockInk
    /// `TranscriptCodeBlock` sets no foreground of its own, so its body
    /// inherits `MarkdownBlocks`'s `.primary`.
    let codeForeground: BlockInk
    /// `.background.secondary`.
    let codeBackground: BlockInk
    /// `.separator`.
    let codeBorder: BlockInk
    /// `Divider().opacity(0.5)`.
    let codeDivider: BlockInk
    /// `.tint.opacity(0.16)`.
    let userBubble: BlockInk
    /// `.primary` inside the bubble: role is carried by the tint and the
    /// alignment, never by dimming text.
    let userBubbleForeground: BlockInk
    /// The tint, which is what `Text` draws a Markdown link in.
    let link: BlockInk
    /// The Markdown parser has no quote segment, so the SwiftUI transcript
    /// draws `> …` as prose. Matching it means the same primary label.
    let quote: BlockInk
    /// `FindTextHighlighting`'s `.yellow`.
    let findMatch: BlockInk
    /// `FindTextHighlighting`'s `.orange`, used for the first match in a block.
    let findActiveMatch: BlockInk
    /// `FindHighlightedMessage`'s `Color.orange.opacity(0.12)`.
    let findActiveRow: BlockInk
    /// `FindHighlightedMessage`'s `.orange.opacity(0.8)` border.
    let findActiveBorder: BlockInk
    /// `AssistantMark`'s `.tint`, which only the symbol fallback uses.
    let assistantMark: BlockInk

    /// `.body`.
    let bodySize: Double
    /// `.title2`, `.title3`, `.headline` — the 17/15/13 scale
    /// `MessageTypography.headingFont` names.
    let headingSizes: [Double]
    /// `.callout`, as `TranscriptCodeBlock` uses for its body.
    let codeSize: Double
    /// `.caption2`, as `TranscriptCodeBlock` uses for its language label.
    let codeLabelSize: Double
    /// `.caption`, as `MessageRow` uses for a system message.
    let systemSize: Double

    /// The layout key's appearance component.
    ///
    /// It carries the resolved palette, not only the appearance name, so an
    /// accent-colour change or an Increase Contrast change invalidates
    /// prepared content exactly the way a light-to-dark switch does.
    let appearanceSignature: String
    /// The layout key's font component: the type scale plus the metrics that
    /// decide where a line breaks.
    let fontSignature: String

    @MainActor
    static func current() -> BlockRenderStyle {
        resolved(for: NSApplication.shared.effectiveAppearance)
    }

    @MainActor
    static func resolved(for appearance: NSAppearance) -> BlockRenderStyle {
        let name = appearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue
            ?? NSAppearance.Name.aqua.rawValue
        var palette: BlockRenderStyle?
        // Resolving inside the drawing appearance is the whole fix: outside it
        // every dynamic colour below answers for the process-wide current
        // appearance rather than for this view's.
        appearance.performAsCurrentDrawingAppearance {
            palette = BlockRenderStyle(appearanceName: name)
        }
        // `performAsCurrentDrawingAppearance` runs its body synchronously, so
        // the second construction is unreachable and exists only so the
        // palette is never optional.
        return palette ?? BlockRenderStyle(appearanceName: name)
    }

    private init(appearanceName: String) {
        self.appearanceName = appearanceName
        isDark = appearanceName == NSAppearance.Name.darkAqua.rawValue

        let label = BlockInk(.labelColor)
        let secondaryLabel = BlockInk(.secondaryLabelColor)
        // The app already spells SwiftUI's secondary background level as
        // `controlBackgroundColor` for its own cards; see `ToastPresenter`.
        let codeBackground = BlockInk(.controlBackgroundColor)
        let codeBorder = BlockInk(.separatorColor)
        let codeDivider = BlockInk(NSColor.separatorColor.withAlphaComponent(0.5))
        // The transcript sets no tint of its own, so `.tint` is the accent.
        let userBubble = BlockInk(NSColor.controlAccentColor.withAlphaComponent(0.16))
        let link = BlockInk(.controlAccentColor)
        let findMatch = BlockInk(.systemYellow)
        let findActiveMatch = BlockInk(.systemOrange)
        let findActiveRow = BlockInk(NSColor.systemOrange.withAlphaComponent(0.12))
        let findActiveBorder = BlockInk(NSColor.systemOrange.withAlphaComponent(0.8))

        self.label = label
        self.secondaryLabel = secondaryLabel
        codeForeground = label
        self.codeBackground = codeBackground
        self.codeBorder = codeBorder
        self.codeDivider = codeDivider
        self.userBubble = userBubble
        userBubbleForeground = label
        self.link = link
        quote = label
        self.findMatch = findMatch
        self.findActiveMatch = findActiveMatch
        self.findActiveRow = findActiveRow
        self.findActiveBorder = findActiveBorder
        assistantMark = link

        let bodySize = Double(NSFont.preferredFont(forTextStyle: .body).pointSize)
        let headingSizes = [
            Double(NSFont.preferredFont(forTextStyle: .title2).pointSize),
            Double(NSFont.preferredFont(forTextStyle: .title3).pointSize),
            Double(NSFont.preferredFont(forTextStyle: .headline).pointSize)
        ]
        let codeSize = Double(NSFont.preferredFont(forTextStyle: .callout).pointSize)
        let codeLabelSize = Double(NSFont.preferredFont(forTextStyle: .caption2).pointSize)
        let systemSize = Double(NSFont.preferredFont(forTextStyle: .caption1).pointSize)
        self.bodySize = bodySize
        self.headingSizes = headingSizes
        self.codeSize = codeSize
        self.codeLabelSize = codeLabelSize
        self.systemSize = systemSize

        var appearanceDigest = BlockStyleDigest()
        appearanceDigest.combine(appearanceName)
        for ink in [
            label, secondaryLabel, codeBackground, codeBorder, codeDivider,
            userBubble, link, findMatch, findActiveMatch, findActiveRow,
            findActiveBorder
        ] {
            appearanceDigest.combine(ink)
        }
        appearanceSignature = "\(appearanceName)#\(appearanceDigest.hexadecimal)"

        var fontDigest = BlockStyleDigest()
        for size in [bodySize, codeSize, codeLabelSize, systemSize] + headingSizes {
            fontDigest.combine(size)
        }
        for metric in [
            MessageTypography.bodyLineSpacing,
            MessageTypography.listIndent,
            MessageTypography.markerColumn,
            MessageTypography.markerGap
        ] {
            fontDigest.combine(Double(metric))
        }
        fontSignature = "block-\(fontDigest.hexadecimal)"
    }
}

private extension BlockRenderStyle {
    /// Fonts are built from plain point sizes, so an off-main builder never
    /// asks AppKit to resolve a text style or a font descriptor collection.
    var bodyFont: NSFont { .systemFont(ofSize: CGFloat(bodySize)) }

    /// `MessageTypography.headingFont`: `.title2`/`.title3` at semibold, then
    /// `.headline`, which is already semibold.
    func headingFont(_ level: Int) -> NSFont {
        let index = min(max(level, 1), headingSizes.count) - 1
        return .systemFont(ofSize: CGFloat(headingSizes[index]), weight: .semibold)
    }

    /// `.monospacedDigit()`, so ordinals right-align on a stable digit width.
    var ordinalFont: NSFont {
        .monospacedDigitSystemFont(ofSize: CGFloat(bodySize), weight: .regular)
    }

    var codeFont: NSFont {
        .monospacedSystemFont(ofSize: CGFloat(codeSize), weight: .regular)
    }

    /// `.caption2.weight(.medium)`.
    var codeLabelFont: NSFont {
        .systemFont(ofSize: CGFloat(codeLabelSize), weight: .medium)
    }

    var systemTextFont: NSFont { .systemFont(ofSize: CGFloat(systemSize)) }

    func inlineCodeFont(matching font: NSFont) -> NSFont {
        .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
    }

    /// The band above a fenced body: a caption2 label with 6pt of padding on
    /// each side of it. The row and the measurement both read this, so the
    /// reserved space and the drawn chrome cannot disagree.
    var codeHeaderHeight: CGFloat {
        let font = codeLabelFont
        return ceil(font.ascender - font.descender + font.leading)
            + Self.codeHeaderPadding * 2
    }
}

/// An immutable attributed value built away from the main actor, with the
/// geometry its height must be measured against.
///
/// `NSAttributedString` is not `Sendable`, but this one is created inside the
/// preparation closure, never mutated afterwards, and only read once it reaches
/// the main actor, where the row copies it into its own text storage. The box
/// states that invariant rather than forcing the value to be rebuilt on the
/// main actor, which is the work this renderer exists to avoid.
private struct BlockPreparedText: @unchecked Sendable {
    /// The value the row draws.
    let value: NSAttributedString
    /// The part of `value` that wraps inside the measure. A list marker sits in
    /// its own fixed column and never takes part in line breaking.
    let measuredRange: NSRange
    /// Points removed from the proposed width before wrapping: a list item's
    /// depth indent plus its marker column.
    let wrapInset: CGFloat
    /// The leading the drawn paragraph style adds between wrapped lines.
    let lineSpacing: CGFloat
    /// The fenced body a copy action puts on the pasteboard, or `nil`.
    let copyText: String?
}

/// One block's immutable prepared value.
private struct BlockPrepared: Sendable {
    let key: BlockLayoutKey
    /// `TranscriptBlock.id`, which locates the row this value belongs to.
    let blockID: String
    let text: String
    let content: BlockPreparedText
    let measuredHeight: CGFloat
}

/// What one block needs off the main actor, captured while still on it.
private struct BlockPlan: Sendable {
    let key: BlockLayoutKey
    let role: Role
    /// `MarkdownMessage` skips segmentation while deltas land, so a streaming
    /// reply is plain body text with no block structure.
    let isPlainText: Bool
}

/// Builds a block's drawn attributes and measures it, entirely off the main
/// actor.
///
/// Every colour comes from a `BlockRenderStyle` that the main actor resolved
/// for the current appearance, and every font is constructed from a plain point
/// size. Nothing here reads a dynamic colour, a view, an appearance, or a
/// TextKit layout manager.
private enum BlockText {
    /// A generous finite bound for the measurement path. Core Text dislikes an
    /// infinite proposal, and no single block can approach this.
    private static let measurementCeiling: CGFloat = 1_000_000

    static func prepare(
        block: TranscriptBlock,
        messageText: String,
        plan: BlockPlan,
        style: BlockRenderStyle
    ) -> BlockPrepared {
        let text = slice(messageText, range: block.sourceRange)
        let prepared = attributedText(
            kind: block.kind,
            source: text,
            role: plan.role,
            isPlainText: plan.isPlainText,
            style: style
        )
        return BlockPrepared(
            key: plan.key,
            blockID: block.id,
            text: text,
            content: prepared,
            measuredHeight: measuredHeight(
                prepared,
                kind: block.kind,
                role: plan.role,
                width: plan.key.representativeWidth,
                style: style
            )
        )
    }

    static func attributedText(
        kind: TranscriptBlock.Kind,
        source: String,
        role: Role,
        isPlainText: Bool,
        style: BlockRenderStyle
    ) -> BlockPreparedText {
        switch role {
        case .user:
            // `MessageRow` draws a user message with `Text(message.text)`:
            // body type at `.primary`, no Markdown, leading-aligned inside a
            // trailing-aligned bubble.
            return paragraph(
                AttributedString(source),
                font: style.bodyFont,
                color: style.userBubbleForeground,
                lineSpacing: MessageTypography.bodyLineSpacing,
                alignment: .natural,
                style: style
            )
        case .system:
            return paragraph(
                AttributedString(source),
                font: style.systemTextFont,
                color: style.secondaryLabel,
                lineSpacing: 0,
                alignment: .center,
                style: style
            )
        case .assistant:
            break
        }

        if isPlainText {
            return paragraph(
                AttributedString(source),
                font: style.bodyFont,
                color: style.label,
                lineSpacing: MessageTypography.bodyLineSpacing,
                alignment: .natural,
                style: style
            )
        }

        if kind == .code {
            return code(source, style: style, stripsFence: true)
        }

        guard let segment = MarkdownSegment.parse(source).first else {
            return paragraph(
                AttributedString(source),
                font: style.bodyFont,
                color: style.label,
                lineSpacing: MessageTypography.bodyLineSpacing,
                alignment: .natural,
                style: style
            )
        }

        switch segment {
        case .heading(_, let level, let content):
            // `MessageTypography.headingFont`/`headingTracking`, with no added
            // leading: a heading is tighter than the body it introduces.
            return paragraph(
                content,
                font: style.headingFont(level),
                color: style.label,
                lineSpacing: 0,
                alignment: .natural,
                tracking: MessageTypography.headingTracking(level),
                style: style
            )
        case .prose(_, let content):
            return paragraph(
                content,
                font: style.bodyFont,
                color: kind == .quote ? style.quote : style.label,
                lineSpacing: MessageTypography.bodyLineSpacing,
                alignment: .natural,
                style: style
            )
        case .bullet(_, _, let depth, let content):
            return listItem(
                content,
                marker: MessageTypography.bulletGlyph(depth),
                markerFont: style.bodyFont,
                depth: depth,
                isOrdinal: false,
                style: style
            )
        case .numbered(_, let marker, let number, let depth, let content):
            return listItem(
                content,
                marker: ordinal(number, marker: marker),
                markerFont: style.ordinalFont,
                depth: depth,
                isOrdinal: true,
                style: style
            )
        case .code(_, _, let body):
            return code(body, style: style, stripsFence: false)
        }
    }

    /// The cheap value a row draws before its prepared value arrives.
    ///
    /// It skips Markdown entirely but takes its font and colour from the same
    /// palette, so an unprepared row is plain rather than unreadable.
    static func fallback(
        _ source: String,
        kind: TranscriptBlock.Kind,
        role: Role,
        style: BlockRenderStyle
    ) -> BlockPreparedText {
        switch role {
        case .system:
            return paragraph(
                AttributedString(source),
                font: style.systemTextFont,
                color: style.secondaryLabel,
                lineSpacing: 0,
                alignment: .center,
                style: style
            )
        case .user, .assistant:
            break
        }
        if kind == .code {
            return code(source, style: style, stripsFence: true)
        }
        return paragraph(
            AttributedString(source),
            font: style.bodyFont,
            color: role == .user ? style.userBubbleForeground : style.label,
            lineSpacing: MessageTypography.bodyLineSpacing,
            alignment: .natural,
            style: style
        )
    }

    static func measuredHeight(
        _ prepared: BlockPreparedText,
        kind: TranscriptBlock.Kind,
        role: Role,
        width: CGFloat,
        style: BlockRenderStyle
    ) -> CGFloat {
        let chrome = kind == .code
            ? style.codeHeaderHeight
                + BlockRenderStyle.codeDividerHeight
                + BlockRenderStyle.codeVerticalInset * 2
            : (role == .user
                ? BlockRenderStyle.userVerticalInset
                : BlockRenderStyle.assistantVerticalInset) * 2
        guard prepared.value.length > 0 else { return max(1, chrome) }

        let measured = prepared.measuredRange.length == prepared.value.length
            ? prepared.value
            : prepared.value.attributedSubstring(from: prepared.measuredRange)
        let wrapWidth = max(1, width - prepared.wrapInset)
        let framesetter = CTFramesetterCreateWithAttributedString(measured)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: wrapWidth, height: measurementCeiling),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var height: CGFloat = 0
        for line in lines {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            height += ceil(ascent + descent + leading)
        }
        // Line spacing is added here rather than left to the paragraph style:
        // `NSParagraphStyle` and `CTParagraphStyle` are not interchangeable, so
        // the framesetter is asked only for glyph lines and the leading the
        // drawn paragraph style adds is accounted for explicitly. Core Text
        // does honour `.font`, which is toll-free bridged with `CTFont`.
        if lines.count > 1 {
            height += prepared.lineSpacing * CGFloat(lines.count - 1)
        }
        return max(1, ceil(height) + chrome)
    }

    /// Applies a bold or italic variant of `base`, or `base` itself.
    static func font(_ base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        guard bold || italic else { return base }
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    static func slice(_ text: String, range: Range<Int>) -> String {
        let ns = text as NSString
        let lower = max(0, min(ns.length, range.lowerBound))
        let upper = max(lower, min(ns.length, range.upperBound))
        return ns.substring(with: NSRange(location: lower, length: upper - lower))
    }

    private static func paragraph(
        _ content: AttributedString,
        font: NSFont,
        color: BlockInk,
        lineSpacing: CGFloat,
        alignment: NSTextAlignment,
        tracking: CGFloat = 0,
        style: BlockRenderStyle
    ) -> BlockPreparedText {
        let result = NSMutableAttributedString()
        append(content, to: result, font: font, color: color, style: style)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.alignment = alignment
        let whole = NSRange(location: 0, length: result.length)
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: whole)
        if tracking != 0, result.length > 0 {
            result.addAttribute(.tracking, value: tracking, range: whole)
        }
        return BlockPreparedText(
            value: result,
            measuredRange: whole,
            wrapInset: 0,
            lineSpacing: lineSpacing,
            copyText: nil
        )
    }

    /// `MarkdownBlocks.listRow`: the marker sits in its own fixed column on the
    /// first text baseline, and wrapped lines align under the item's text
    /// rather than under its marker.
    private static func listItem(
        _ content: AttributedString,
        marker: String,
        markerFont: NSFont,
        depth: Int,
        isOrdinal: Bool,
        style: BlockRenderStyle
    ) -> BlockPreparedText {
        let indent = CGFloat(min(depth, MessageTypography.maxListDepth))
            * MessageTypography.listIndent
        let column = indent + MessageTypography.markerColumn
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = MessageTypography.bodyLineSpacing
        paragraphStyle.alignment = .natural
        paragraphStyle.firstLineHeadIndent = indent
        paragraphStyle.headIndent = column
        paragraphStyle.tabStops = isOrdinal
            // An ordinal right-aligns `markerGap` short of the text column, so
            // the delimiters line up down the list.
            ? [
                NSTextTab(
                    textAlignment: .right,
                    location: column - MessageTypography.markerGap
                ),
                NSTextTab(textAlignment: .left, location: column)
            ]
            : [NSTextTab(textAlignment: .left, location: column)]

        let result = NSMutableAttributedString()
        // A marker is structure, not prose, so it recedes to `.secondary`
        // while the item's own text stays at `.primary`.
        result.append(NSAttributedString(
            string: isOrdinal ? "\t\(marker)\t" : "\(marker)\t",
            attributes: [
                .font: markerFont,
                .foregroundColor: style.secondaryLabel.nsColor
            ]
        ))
        let contentStart = result.length
        append(content, to: result, font: style.bodyFont, color: style.label, style: style)
        result.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: result.length)
        )
        return BlockPreparedText(
            value: result,
            measuredRange: NSRange(
                location: contentStart,
                length: result.length - contentStart
            ),
            wrapInset: column,
            lineSpacing: MessageTypography.bodyLineSpacing,
            copyText: nil
        )
    }

    private static func code(
        _ source: String,
        style: BlockRenderStyle,
        stripsFence: Bool
    ) -> BlockPreparedText {
        let body = stripsFence ? codeBody(from: source) : source
        let paragraphStyle = NSMutableParagraphStyle()
        // `TranscriptCodeBlock` puts its body in a horizontal scroll view and
        // never wraps. A block row has no scroller of its own, so a long line
        // wraps by character instead: wrapping on words would leave a wide
        // ragged gap in a code listing, and clipping would lose the text.
        paragraphStyle.lineBreakMode = .byCharWrapping
        let value = NSAttributedString(string: body, attributes: [
            .font: style.codeFont,
            .foregroundColor: style.codeForeground.nsColor,
            .paragraphStyle: paragraphStyle
        ])
        return BlockPreparedText(
            value: value,
            measuredRange: NSRange(location: 0, length: value.length),
            wrapInset: 0,
            lineSpacing: 0,
            copyText: body
        )
    }

    /// A fenced block's body without its delimiters.
    ///
    /// `TranscriptBlockSegmenter` gives a code block a source range spanning
    /// the opening fence through the closing one, while `TranscriptCodeBlock`
    /// draws only the body and puts the info string in its header.
    private static func codeBody(from source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeFirst()
        }
        // A fence that has not closed yet leaves no trailing delimiter to drop.
        if !lines.isEmpty,
           lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// Mirrors `MarkdownBlocks.ordinal`, keeping the author's delimiter so
    /// `3)` stays `3)` and `3.` stays `3.`.
    private static func ordinal(_ number: Int, marker: String) -> String {
        let delimiter = marker.last.map { $0 == ")" ? ")" : "." } ?? "."
        return "\(number)\(delimiter)"
    }

    /// Translates one parsed inline run into real drawing attributes.
    ///
    /// `MarkdownSegment` produces Foundation `inlinePresentationIntent` runs
    /// and no colours or fonts at all. TextKit does not interpret that intent,
    /// so emphasis, inline code, strikethrough, and links are turned into
    /// concrete attributes here — and every run gets an explicit foreground
    /// colour, because `NSAttributedString`'s default foreground is black.
    private static func append(
        _ content: AttributedString,
        to result: NSMutableAttributedString,
        font baseFont: NSFont,
        color: BlockInk,
        style: BlockRenderStyle
    ) {
        for run in content.runs {
            let text = String(content[run.range].characters)
            guard !text.isEmpty else { continue }
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [:]
            attributes[.font] = intent.contains(.code)
                ? style.inlineCodeFont(matching: baseFont)
                : Self.font(
                    baseFont,
                    bold: intent.contains(.stronglyEmphasized),
                    italic: intent.contains(.emphasized)
                )
            if let link = run.link {
                // `Text` draws a Markdown link in the current tint and does
                // not underline it.
                attributes[.foregroundColor] = style.link.nsColor
                attributes[.link] = link
            } else {
                attributes[.foregroundColor] = color.nsColor
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = color.nsColor
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
    }
}

/// A block-oriented AppKit transcript. The table owns only visible row views;
/// source text remains in `TranscriptRendererInput.messages` and is sliced by
/// each block's UTF-16 range.
struct BlockTranscriptView: NSViewRepresentable {
    let input: TranscriptRendererInput

    init(input: TranscriptRendererInput) {
        self.input = input
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    func makeNSView(context: Context) -> BlockTranscriptContainerView {
        context.coordinator.makeContainer()
    }

    @MainActor
    func updateNSView(_ nsView: BlockTranscriptContainerView, context: Context) {
        context.coordinator.update(container: nsView, input: input)
    }

    static func dismantleNSView(
        _ nsView: BlockTranscriptContainerView,
        coordinator: Coordinator
    ) {
        coordinator.dismantle(container: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private struct Row {
            let block: TranscriptBlock
            let message: ChatMessage
            let messageIndex: Int
            let text: String
        }

        private let preparation = BlockPreparationCoordinator(laneCount: 4)
        private let layoutCache = BlockLayoutCache()
        private let selection = BlockSelectionCoordinator()
        private var prepared: [BlockLayoutKey: BlockPrepared] = [:]
        /// Resolved once per appearance on the main actor. Every off-main
        /// builder reads its colours from here, so nothing off the main actor
        /// asks a dynamic colour for a value it cannot resolve.
        ///
        /// It is `lazy` so that nothing resolves during `init`, which
        /// `NSObject` does not isolate to the main actor. `makeContainer`
        /// resolves it against the table's own appearance, and
        /// `viewDidChangeEffectiveAppearance` keeps it current after that.
        private lazy var style: BlockRenderStyle = .current()
        private var rows: [Row] = []
        /// Row position by block identity, so a prepared result finds its row
        /// without scanning every row and rebuilding every key.
        private var rowIndexByBlockID: [String: Int] = [:]
        private var blocks: [TranscriptBlock] = []
        private var messages: [ChatMessage] = []
        private var messageTextByID: [String: String] = [:]
        private var routeIdentity = ""
        private var isReadOnly = false
        private var isStreaming = false
        private var findQuery = ""
        private var findMatches: [TranscriptMatch] = []
        private var activeFindIndex: Int?
        private var pendingMessageID: MessageIdentity?
        private var hasMoreOlderMessages = false
        private var onRequestOlder: () -> Void = {}
        private var onCopyCode: (String) -> Void = { _ in }
        private weak var container: BlockTranscriptContainerView?
        private weak var tableView: NSTableView?
        private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
        private var generation = 0
        /// Eight rows keeps a small amount of rich content ready during a
        /// wheel tick without shaping blocks outside the visible neighborhood.
        private let overdrawRows = 8

        func makeContainer() -> BlockTranscriptContainerView {
            let table = BlockTranscriptTableView()
            table.delegate = self
            table.dataSource = self
            table.headerView = nil
            table.intercellSpacing = .zero
            table.selectionHighlightStyle = .none
            table.allowsEmptySelection = true
            table.allowsMultipleSelection = false
            table.rowSizeStyle = .custom
            table.setAccessibilityElement(false)
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.backgroundColor = .clear
            table.addTableColumn(NSTableColumn(identifier: .init("block-transcript")))

            let result = BlockTranscriptContainerView(tableView: table)
            container = result
            tableView = table
            result.onAppearanceChange = { [weak self] in
                self?.appearanceDidChange()
            }
            let scrollToken = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: table.enclosingScrollView?.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.prepareVisibleBlocks()
                self.requestOlderIfNeeded()
            }
            observers.append((NotificationCenter.default, scrollToken))
            // The accent colour and Increase Contrast both change the palette
            // without changing the effective appearance, so they have to
            // invalidate prepared colours the way a light-to-dark switch does.
            let colorToken = NotificationCenter.default.addObserver(
                forName: NSColor.systemColorsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.appearanceDidChange()
            }
            observers.append((NotificationCenter.default, colorToken))
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            let accessibilityToken = workspaceCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.appearanceDidChange()
            }
            observers.append((workspaceCenter, accessibilityToken))
            // Resolved before the first row is configured, so the opening
            // frame already draws in the right appearance rather than waiting
            // for an appearance change that may never come.
            style = BlockRenderStyle.resolved(for: table.effectiveAppearance)
            return result
        }

        func update(container: BlockTranscriptContainerView, input: TranscriptRendererInput) {
            let routeChanged = routeIdentity != input.routeIdentity
            if routeChanged {
                generation &+= 1
                preparation.cancel()
                prepared.removeAll(keepingCapacity: true)
                layoutCacheResetForRoute()
                selection.clear()
            }
            let oldRows = rows
            let oldBlocks = blocks
            let oldMessages = messages

            container.onPaint = input.onPaint
            self.container = container
            self.tableView = container.tableView
            self.routeIdentity = input.routeIdentity
            self.isReadOnly = input.isReadOnly
            self.isStreaming = input.isStreaming
            self.findQuery = input.findQuery
            self.findMatches = input.findMatches
            self.activeFindIndex = input.activeFindIndex
            self.hasMoreOlderMessages = input.window.hasMoreOlderMessages
            self.onRequestOlder = input.onRequestOlder
            self.onCopyCode = input.onCopyCode
            self.messages = input.messages
            self.messageTextByID = Dictionary(uniqueKeysWithValues: input.messages.map {
                (messageID(for: $0), $0.text)
            })

            let incomingBlocks = input.blocks.isEmpty
                ? input.messages.flatMap { TranscriptBlockSegmenter.blocks(for: $0) }
                : input.blocks
            let nextBlocks = reconciledBlocks(
                oldBlocks: oldBlocks,
                oldMessages: oldMessages,
                newBlocks: incomingBlocks,
                newMessages: input.messages
            )
            self.blocks = nextBlocks
            self.rows = makeRows(from: nextBlocks, messages: input.messages)
            var rowIndexes: [String: Int] = [:]
            rowIndexes.reserveCapacity(rows.count)
            for (index, row) in rows.enumerated() {
                rowIndexes[row.block.id] = index
            }
            self.rowIndexByBlockID = rowIndexes
            updateAccessibility(in: container)

            let changed = changedRowIndexes(oldRows: oldRows, newRows: rows)
            container.tableView.isHidden = rows.isEmpty
            if routeChanged || oldRows.isEmpty && !rows.isEmpty {
                container.tableView.noteNumberOfRowsChanged()
                container.layoutTableDocument()
            } else if !changed.isEmpty {
                container.tableView.noteNumberOfRowsChanged()
                container.tableView.reloadData(
                    forRowIndexes: changed,
                    columnIndexes: IndexSet(integer: 0)
                )
                container.layoutTableDocument()
            }
            prepareVisibleBlocks()
            schedulePositioning(routeChanged: routeChanged)
        }

        func dismantle(container: BlockTranscriptContainerView) {
            generation &+= 1
            preparation.cancel()
            container.onAppearanceChange = nil
            container.tableView.delegate = nil
            container.tableView.dataSource = nil
            for observer in observers {
                observer.center.removeObserver(observer.token)
            }
            observers.removeAll()
            if self.container === container {
                self.container = nil
                tableView = nil
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard rows.indices.contains(row),
                  let view = tableView.makeView(
                    withIdentifier: BlockTranscriptRowView.identifier,
                    owner: self
                  ) as? BlockTranscriptRowView
            else { return nil }
            let value = rows[row]
            let key = layoutKey(for: value.block, message: value.message, tableView: tableView)
            let preparedValue = prepared[key]
            let messageStart = row == 0 || rows[row - 1].message.id != value.message.id
            let messageEnd = row == rows.count - 1 || rows[row + 1].message.id != value.message.id
            let sourceMatches = findQuery.isEmpty ? [] : findMatches
                .filter { $0.messageIndex == value.messageIndex }
                .map(\.range)
            let active = activeFindIndex.map {
                findMatches.indices.contains($0)
                    && findMatches[$0].messageIndex == value.messageIndex
            } ?? false
            view.configure(
                block: value.block,
                message: value.message,
                sourceText: value.text,
                prepared: preparedValue,
                style: style,
                isFirstInMessage: messageStart,
                isLastInMessage: messageEnd,
                findRanges: sourceMatches,
                isFindActive: active,
                selection: selection,
                allBlocks: blocks,
                messageText: { [weak self] id in self?.messageTextByID[id] },
                onCopyCode: onCopyCode
            )
            return view
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 24 }
            let value = rows[row]
            let key = layoutKey(for: value.block, message: value.message, tableView: tableView)
            if let cached = layoutCache.value(for: key) {
                return cached.measuredHeight
            }
            return BlockHeightEstimator.estimatedHeight(
                for: value.block,
                width: contentWidth(for: value.message, in: tableView)
            )
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false
        }

        /// Re-resolves the palette and redraws with it.
        ///
        /// Prepared values carry concrete colours, so none of them survive a
        /// palette change; bumping the generation also rejects results that
        /// were already in flight against the old palette. The new palette
        /// changes `BlockLayoutKey.appearanceMode`, so the next
        /// `prepareVisibleBlocks` misses the prepared map and shapes again.
        private func appearanceDidChange() {
            guard let tableView else { return }
            let next = BlockRenderStyle.resolved(for: tableView.effectiveAppearance)
            guard next != style else { return }
            style = next
            generation &+= 1
            preparation.cancel()
            prepared.removeAll(keepingCapacity: true)
            let current = generation
            // Deferred one turn: this can arrive inside AppKit's own
            // appearance pass, and reloading a table view from inside that
            // pass re-enters layout.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current, let tableView = self.tableView else {
                    return
                }
                tableView.reloadData()
                if tableView.numberOfRows > 0 {
                    tableView.noteHeightOfRows(
                        withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows)
                    )
                }
                self.container?.layoutTableDocument()
                self.prepareVisibleBlocks()
            }
        }

        private func reconciledBlocks(
            oldBlocks: [TranscriptBlock],
            oldMessages: [ChatMessage],
            newBlocks: [TranscriptBlock],
            newMessages: [ChatMessage]
        ) -> [TranscriptBlock] {
            guard let oldMessage = oldMessages.last,
                  let newMessage = newMessages.last,
                  oldMessage.id == newMessage.id,
                  oldMessage.text != newMessage.text,
                  newMessage.text.utf16.starts(with: oldMessage.text.utf16),
                  !oldBlocks.isEmpty
            else { return newBlocks }
            // Only the final logical block is re-segmented. The caller's blocks
            // remain authoritative, while this path preserves the segmenter's
            // unchanged prefix and gives us the precise changed suffix.
            let previous = oldBlocks.filter { $0.messageID == messageID(for: oldMessage) }
            let result = TranscriptBlockSegmenter.resegment(
                previous: previous,
                previousMessage: oldMessage,
                message: newMessage
            )
            let prefix = oldBlocks.prefix(while: {
                $0.messageID != messageID(for: oldMessage)
            })
            return Array(prefix) + result.blocks
        }

        private func makeRows(from blocks: [TranscriptBlock], messages: [ChatMessage]) -> [Row] {
            var byID: [String: ChatMessage] = [:]
            var indices: [String: Int] = [:]
            for (index, message) in messages.enumerated() {
                byID[messageID(for: message)] = message
                indices[messageID(for: message)] = index
            }
            return blocks.compactMap { block in
                guard let message = byID[block.messageID], let index = indices[block.messageID] else { return nil }
                return Row(
                    block: block,
                    message: message,
                    messageIndex: index,
                    text: BlockText.slice(message.text, range: block.sourceRange)
                )
            }
        }

        private func changedRowIndexes(oldRows: [Row], newRows: [Row]) -> IndexSet {
            var result = IndexSet()
            let count = max(oldRows.count, newRows.count)
            for index in 0..<count {
                guard newRows.indices.contains(index) else { continue }
                guard !oldRows.indices.contains(index)
                    || oldRows[index].block != newRows[index].block
                    || oldRows[index].message.role != newRows[index].message.role
                    || oldRows[index].message.isStreaming != newRows[index].message.isStreaming
                else { continue }
                result.insert(index)
            }
            return result
        }

        /// The single authority for a block's cache identity.
        ///
        /// `appearanceMode` carries the resolved palette, and `fontSignature`
        /// carries the type scale plus the role and the plain-text flag,
        /// because the same text draws differently in a user bubble, in a
        /// streaming reply, and in a finished reply.
        private func layoutKey(
            for block: TranscriptBlock,
            message: ChatMessage,
            tableView: NSTableView
        ) -> BlockLayoutKey {
            BlockLayoutKey(
                contentHash: block.contentHash,
                width: contentWidth(for: message, in: tableView),
                fontSignature: "\(style.fontSignature)|\(message.role.rawValue)"
                    + "|plain=\(message.isStreaming)",
                displayScaleBits: Double(displayScale(for: tableView)).bitPattern,
                appearanceMode: style.appearanceSignature,
                localeIdentifier: Locale.current.identifier,
                rendererVersion: BlockRenderStyle.rendererVersion
            )
        }

        private func prepareVisibleBlocks() {
            guard let tableView, !rows.isEmpty else { return }
            let visible = tableView.rows(in: visibleRect(for: tableView))
            guard visible.location != NSNotFound else { return }
            let lower = max(0, visible.location - overdrawRows)
            let upper = min(rows.count, visible.location + visible.length + overdrawRows)
            var candidates: [TranscriptBlock] = []
            var plans: [String: BlockPlan] = [:]
            for row in rows[lower..<upper] {
                let key = layoutKey(for: row.block, message: row.message, tableView: tableView)
                guard prepared[key] == nil, plans[row.block.id] == nil else { continue }
                candidates.append(row.block)
                plans[row.block.id] = BlockPlan(
                    key: key,
                    role: row.message.role,
                    isPlainText: row.message.isStreaming
                )
            }
            guard !candidates.isEmpty else { return }
            let requestGeneration = generation
            Task { [weak self] in
                guard let self else { return }
                await self.preparation.prepare(
                    candidates,
                    preparation: { [messageTextByID, plans, style] (block: TranscriptBlock) -> BlockPrepared? in
                        guard !Task.isCancelled,
                              let source = messageTextByID[block.messageID],
                              let plan = plans[block.id]
                        else { return nil }
                        return BlockText.prepare(
                            block: block,
                            messageText: source,
                            plan: plan,
                            style: style
                        )
                    },
                    onResult: { [weak self] (result: BlockPrepared) in
                        await MainActor.run {
                            guard let self, self.generation == requestGeneration else { return }
                            self.accept(result)
                        }
                    }
                )
            }
        }

        private func accept(_ result: BlockPrepared) {
            let oldHeight = layoutCache.value(for: result.key)?.measuredHeight
            prepared[result.key] = result
            layoutCache.insert(
                preparedContent: result.text,
                measuredHeight: result.measuredHeight,
                for: result.key
            )
            guard let tableView,
                  let row = rowIndexByBlockID[result.blockID],
                  rows.indices.contains(row),
                  layoutKey(
                      for: rows[row].block,
                      message: rows[row].message,
                      tableView: tableView
                  ) == result.key
            else { return }
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            guard oldHeight != result.measuredHeight else { return }
            let visible = visibleRect(for: tableView)
            let boundary = tableView.rows(in: visible).location
            // The boundary is sampled from the clip view at correction time,
            // never cached from an earlier update. Rows above it are left alone
            // so the cursor does not jump while a rich layout arrives.
            guard boundary != NSNotFound, row >= boundary else { return }
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            container?.layoutTableDocument()
        }

        private func visibleRect(for tableView: NSTableView) -> NSRect {
            guard let clip = tableView.enclosingScrollView?.contentView else { return tableView.bounds }
            return tableView.convert(clip.bounds, from: clip)
        }

        private func contentWidth(for message: ChatMessage, in tableView: NSTableView) -> CGFloat {
            let tableWidth = tableView.enclosingScrollView?.contentView.bounds.width ?? tableView.bounds.width
            let outer = max(1, tableWidth - 44)
            switch message.role {
            case .assistant:
                return min(outer - MessageTypography.bubblePadding * 2, MessageTypography.readingMeasure)
            case .user:
                return min(outer - MessageTypography.bubblePadding * 2, MessageTypography.userBubbleMeasure - MessageTypography.bubblePadding * 2)
            case .system:
                return outer
            }
        }

        private func displayScale(for tableView: NSTableView) -> CGFloat {
            tableView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        }

        private func requestOlderIfNeeded() {
            guard hasMoreOlderMessages,
                  let tableView,
                  let scroll = tableView.enclosingScrollView,
                  scroll.contentView.bounds.origin.y <= 1
            else { return }
            onRequestOlder()
        }

        private func schedulePositioning(routeChanged: Bool) {
            let current = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current, let tableView else { return }
                tableView.layoutSubtreeIfNeeded()
                if let pending = pendingMessageID,
                   let index = rows.firstIndex(where: { $0.message.id == pending }) {
                    tableView.scrollRowToVisible(index)
                } else if routeChanged || isStreaming, !isReadOnly, !rows.isEmpty {
                    let clip = tableView.enclosingScrollView?.contentView
                    clip?.scroll(to: NSPoint(x: 0, y: max(0, tableView.bounds.height - (clip?.bounds.height ?? 0))))
                    if let clip { tableView.enclosingScrollView?.reflectScrolledClipView(clip) }
                }
            }
        }

        private func updateAccessibility(in container: BlockTranscriptContainerView) {
            container.messageElements = Dictionary(grouping: rows, by: { $0.message.id }).values.map {
                BlockMessageAccessibilityElement(
                    label: $0.first?.message.text ?? "",
                    blocks: $0.map { BlockAccessibilityElement(label: $0.text) }
                )
            }
        }


        private func layoutCacheResetForRoute() {
            // Cache keys include content, route-independent layout inputs, and
            // therefore remain safe across routes. Prepared AppKit values do not.
        }

        private func messageID(for message: ChatMessage) -> String {
            Self.messageID(for: message)
        }

        private static func messageID(for message: ChatMessage) -> String {
            switch message.id {
            case .server(let id): return String(id.rawValue)
            case .provisional(let id): return id.uuidString
            }
        }
    }
}

@MainActor
private final class BlockTranscriptTableView: NSTableView {
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        super.makeView(withIdentifier: identifier, owner: owner)
            ?? (identifier == BlockTranscriptRowView.identifier ? BlockTranscriptRowView() : nil)
    }
}

@MainActor
private final class BlockTranscriptRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BlockTranscriptRow")
    /// The row's own drawn surface: the user bubble's tint, or a fenced
    /// block's card. It tracks the text view's frame rather than the cell's,
    /// so a bubble hugs its column instead of banding the whole row.
    private let surface = NSView()
    private let textView = BlockTranscriptTextView()
    private let assistantMark = NSImageView()
    private let languageLabel = NSTextField(labelWithString: "")
    private let headerDivider = NSView()
    private let copyButton = NSButton()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    /// Reserves the fenced header band above the code itself.
    private var textTop: NSLayoutConstraint!
    private var labelCenterY: NSLayoutConstraint!
    private var dividerTop: NSLayoutConstraint!
    private var messageRole: Role = .assistant
    private var position: BlockTextPosition?
    private weak var selection: BlockSelectionCoordinator?
    private var allBlocks: [TranscriptBlock] = []
    private var messageText: (String) -> String? = { _ in nil }
    private var onCopyCode: (String) -> Void = { _ in }
    private var copiedCode = ""
    private var copyPointSize: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.wantsLayer = true
        // SwiftUI draws both the bubble and the code card with `.continuous`.
        surface.layer?.cornerCurve = .continuous
        surface.setAccessibilityElement(false)
        addSubview(surface)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.onBegin = { [weak self] offset in self?.reportBegin(offset) }
        textView.onExtend = { [weak self] offset in self?.reportExtend(offset) }
        addSubview(textView)

        languageLabel.translatesAutoresizingMaskIntoConstraints = false
        languageLabel.isSelectable = false
        languageLabel.drawsBackground = false
        languageLabel.setAccessibilityElement(false)
        addSubview(languageLabel)

        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        headerDivider.wantsLayer = true
        headerDivider.setAccessibilityElement(false)
        addSubview(headerDivider)

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        // `TranscriptCodeBlock` uses a plain, secondary, image-only button.
        copyButton.title = ""
        copyButton.isBordered = false
        copyButton.imagePosition = .imageOnly
        copyButton.target = self
        copyButton.action = #selector(copyCodeAction)
        copyButton.toolTip = "Copy"
        copyButton.setAccessibilityLabel("Copy code")
        addSubview(copyButton)

        assistantMark.translatesAutoresizingMaskIntoConstraints = false
        assistantMark.imageScaling = .scaleProportionallyUpOrDown
        assistantMark.setAccessibilityElement(false)
        addSubview(assistantMark)

        leading = textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48)
        trailing = textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24)
        textTop = textView.topAnchor.constraint(equalTo: topAnchor)
        labelCenterY = languageLabel.centerYAnchor.constraint(equalTo: surface.topAnchor)
        dividerTop = headerDivider.topAnchor.constraint(equalTo: surface.topAnchor)
        NSLayoutConstraint.activate([
            leading,
            trailing,
            textTop,
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            languageLabel.leadingAnchor.constraint(
                equalTo: surface.leadingAnchor,
                constant: BlockRenderStyle.codeHorizontalInset
            ),
            labelCenterY,
            dividerTop,
            headerDivider.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            headerDivider.heightAnchor.constraint(
                equalToConstant: BlockRenderStyle.codeDividerHeight
            ),
            copyButton.trailingAnchor.constraint(
                equalTo: surface.trailingAnchor,
                constant: -BlockRenderStyle.codeHorizontalInset
            ),
            copyButton.centerYAnchor.constraint(equalTo: languageLabel.centerYAnchor),
            assistantMark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            assistantMark.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            assistantMark.widthAnchor.constraint(equalToConstant: 20),
            assistantMark.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    fileprivate func configure(
        block: TranscriptBlock,
        message: ChatMessage,
        sourceText: String,
        prepared: BlockPrepared?,
        style: BlockRenderStyle,
        isFirstInMessage: Bool,
        isLastInMessage: Bool,
        findRanges: [Range<Int>],
        isFindActive: Bool,
        selection: BlockSelectionCoordinator,
        allBlocks: [TranscriptBlock],
        messageText: @escaping (String) -> String?,
        onCopyCode: @escaping (String) -> Void
    ) {
        self.messageRole = message.role
        self.selection = selection
        self.allBlocks = allBlocks
        self.messageText = messageText
        self.onCopyCode = onCopyCode
        self.position = BlockTextPosition(
            messageID: block.messageID,
            blockIndex: block.blockIndex,
            utf16Offset: 0
        )
        textView.position = position
        textView.selectionHandler = self

        let isCode = block.kind == .code
        let content = prepared?.content ?? BlockText.fallback(
            sourceText,
            kind: block.kind,
            role: message.role,
            style: style
        )
        copiedCode = content.copyText ?? ""
        textView.textContainerInset = NSSize(
            width: isCode
                ? BlockRenderStyle.codeHorizontalInset
                : MessageTypography.bubblePadding,
            height: isCode
                ? BlockRenderStyle.codeVerticalInset
                : (message.role == .user
                    ? BlockRenderStyle.userVerticalInset
                    : BlockRenderStyle.assistantVerticalInset)
        )
        // A link's drawn attributes come from the palette, so the text view
        // cannot repaint it in AppKit's default blue underline.
        textView.linkTextAttributes = [
            .foregroundColor: style.link.nsColor,
            .cursor: NSCursor.pointingHand
        ]
        textView.textStorage?.setAttributedString(content.value)
        applyFindMarks(findRanges, block: block, sourceText: sourceText, style: style)

        assistantMark.isHidden = message.role != .assistant || !isFirstInMessage
        if !assistantMark.isHidden {
            assistantMark.image = BlockAssistantMark.image(isDark: style.isDark)
            // Only the symbol fallback is a template image; the drawings carry
            // their own appearance, exactly as `AssistantMark` selects them.
            assistantMark.contentTintColor = style.assistantMark.nsColor
        }

        languageLabel.isHidden = !isCode
        headerDivider.isHidden = !isCode
        copyButton.isHidden = !isCode
        if isCode {
            languageLabel.stringValue = TranscriptCodeBlock.label(for: block.language ?? "")
            languageLabel.font = style.codeLabelFont
            languageLabel.textColor = style.secondaryLabel.nsColor
            headerDivider.layer?.backgroundColor = style.codeDivider.cgColor
            copyPointSize = CGFloat(style.codeLabelSize)
            copyButton.contentTintColor = style.secondaryLabel.nsColor
            copyButton.image = Self.copyImage(pointSize: copyPointSize, copied: false)
            labelCenterY.constant = style.codeHeaderHeight / 2
            dividerTop.constant = style.codeHeaderHeight
            textTop.constant = style.codeHeaderHeight + BlockRenderStyle.codeDividerHeight
        } else {
            textTop.constant = 0
        }

        applySurface(
            role: message.role,
            isCode: isCode,
            isFindActive: isFindActive,
            isFirstInMessage: isFirstInMessage,
            isLastInMessage: isLastInMessage,
            style: style
        )
        setAccessibilityLabel(sourceText)
    }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width - 44)
        let outer = min(width, messageRole == .user ? MessageTypography.userBubbleMeasure : MessageTypography.readingMeasure)
        if messageRole == .user {
            leading.constant = max(60, bounds.width - 24 - outer)
            trailing.constant = -24
        } else {
            leading.constant = messageRole == .assistant ? 48 : 20
            trailing.constant = -max(20, bounds.width - leading.constant - outer)
        }
    }

    /// The row's background, border, and corner treatment.
    ///
    /// `MessageRow` tints a user bubble, `TranscriptCodeBlock` draws a bordered
    /// card, and `FindHighlightedMessage` tints and outlines the active
    /// message. A row that already carries a translucent fill takes only the
    /// find outline, because two translucent fills would paint twice what
    /// SwiftUI paints once.
    private func applySurface(
        role: Role,
        isCode: Bool,
        isFindActive: Bool,
        isFirstInMessage: Bool,
        isLastInMessage: Bool,
        style: BlockRenderStyle
    ) {
        let background: BlockInk?
        let radius: CGFloat
        if isCode {
            background = style.codeBackground
            radius = AppShapeScale.compact
        } else if role == .user {
            background = style.userBubble
            radius = AppShapeScale.toast
        } else {
            background = isFindActive ? style.findActiveRow : nil
            radius = isFindActive ? AppShapeScale.row : 0
        }
        var corners: CACornerMask = []
        if isFirstInMessage { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if isLastInMessage { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        surface.layer?.backgroundColor = background?.cgColor ?? NSColor.clear.cgColor
        surface.layer?.cornerRadius = radius
        surface.layer?.maskedCorners = corners
        if isFindActive {
            surface.layer?.borderWidth = BlockRenderStyle.findBorderWidth
            surface.layer?.borderColor = style.findActiveBorder.cgColor
        } else if isCode {
            surface.layer?.borderWidth = BlockRenderStyle.codeBorderWidth
            surface.layer?.borderColor = style.codeBorder.cgColor
        } else {
            surface.layer?.borderWidth = 0
            surface.layer?.borderColor = NSColor.clear.cgColor
        }
    }

    /// Marks find hits the way `MarkdownBlocks` does: the first match inside a
    /// block is orange, the rest yellow, and every one of them is emphasised.
    ///
    /// The drawn string is not the source — Markdown markers are gone and a
    /// list marker has been added — so the ranges are projected through the
    /// same helper the SwiftUI transcript uses.
    private func applyFindMarks(
        _ findRanges: [Range<Int>],
        block: TranscriptBlock,
        sourceText: String,
        style: BlockRenderStyle
    ) {
        guard !findRanges.isEmpty, let storage = textView.textStorage, storage.length > 0 else {
            return
        }
        let local = findRanges.compactMap { range -> Range<Int>? in
            guard block.sourceRange.contains(range.lowerBound) else { return nil }
            let lower = range.lowerBound - block.sourceRange.lowerBound
            let upper = min(range.upperBound, block.sourceRange.upperBound)
                - block.sourceRange.lowerBound
            guard upper > lower else { return nil }
            return lower..<upper
        }
        guard !local.isEmpty else { return }
        let projected = FindTextHighlighting.project(
            local,
            from: sourceText,
            to: storage.string
        )
        guard !projected.isEmpty else { return }
        storage.beginEditing()
        for (offset, range) in projected.enumerated() {
            guard range.lowerBound >= 0, range.upperBound <= storage.length else { continue }
            let marked = NSRange(
                location: range.lowerBound,
                length: range.upperBound - range.lowerBound
            )
            storage.addAttribute(
                .foregroundColor,
                value: (offset == 0 ? style.findActiveMatch : style.findMatch).nsColor,
                range: marked
            )
            // Collected first: adding an attribute inside `enumerateAttribute`
            // rewrites the run boundaries the enumeration is walking.
            var emphasised: [(range: NSRange, font: NSFont)] = []
            storage.enumerateAttribute(.font, in: marked, options: []) { value, subrange, _ in
                guard let font = value as? NSFont else { return }
                emphasised.append((subrange, BlockText.font(font, bold: true, italic: false)))
            }
            for run in emphasised {
                storage.addAttribute(.font, value: run.font, range: run.range)
            }
        }
        storage.endEditing()
    }

    private static func copyImage(pointSize: CGFloat, copied: Bool) -> NSImage? {
        let name = copied ? "checkmark" : "doc.on.doc"
        return NSImage(systemSymbolName: name, accessibilityDescription: "Copy code")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            )
    }

    private func reportBegin(_ offset: Int) {
        guard let position, let selection else { return }
        selection.begin(at: position.withOffset(offset))
    }

    private func reportExtend(_ offset: Int) {
        guard let position, let selection else { return }
        selection.extend(to: position.withOffset(offset))
    }

    fileprivate func copySelection() {
        guard let selection, let range = selection.selectedRange else { return }
        let plain = selection.plainText(for: range, blocks: allBlocks, messageText: messageText)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain, forType: .string)
    }

    fileprivate func copyCode() {
        guard !copiedCode.isEmpty else { return }
        onCopyCode(copiedCode)
    }

    @objc private func copyCodeAction() {
        copyCode()
        copyButton.image = Self.copyImage(pointSize: copyPointSize, copied: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self else { return }
            self.copyButton.image = Self.copyImage(pointSize: self.copyPointSize, copied: false)
        }
    }
}

/// The app mark drawings an assistant row shows.
///
/// `ChatView`'s `HermternalMark` is file-private to the SwiftUI transcript, so
/// this renderer loads the same two resources rather than substituting a
/// different glyph. Each is decoded at most once; main-actor isolation is what
/// makes a `static let` of a non-`Sendable` `NSImage` legal.
@MainActor
private enum BlockAssistantMark {
    static func image(isDark: Bool) -> NSImage? {
        (isDark ? dark : light) ?? fallback
    }

    private static let light = load("HermternalMarkLight")
    private static let dark = load("HermternalMarkDark")
    /// `AssistantMark`'s own fallback, for a process running without its
    /// bundle resources. It is a template image, so it takes the tint.
    private static let fallback = NSImage(
        systemSymbolName: "sparkle",
        accessibilityDescription: "Hermternal"
    )

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else {
            Log.error("Missing bundle resource \(name).png")
            return nil
        }
        return image
    }
}

@MainActor
private final class BlockTranscriptTextView: NSTextView {
    var position: BlockTextPosition?
    var onBegin: (Int) -> Void = { _ in }
    var onExtend: (Int) -> Void = { _ in }
    weak var selectionHandler: BlockTranscriptRowView?

    override func mouseDown(with event: NSEvent) {
        onBegin(offset(for: event))
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        onExtend(offset(for: event))
        super.mouseDragged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            selectionHandler?.copySelection()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func offset(for event: NSEvent) -> Int {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndex(for: point)
        return max(0, min(string.utf16.count, index))
    }

}

private extension BlockTextPosition {
    func withOffset(_ offset: Int) -> BlockTextPosition {
        BlockTextPosition(messageID: messageID, blockIndex: blockIndex, utf16Offset: offset)
    }
}

@MainActor
final class BlockTranscriptContainerView: NSView {
    let tableView: NSTableView
    private let scrollView = NSScrollView()
    private var lastDocumentWidth: CGFloat = 0
    fileprivate var messageElements: [BlockMessageAccessibilityElement] = []
    var onPaint: ((UInt64) -> Void)?
    /// Called when the effective appearance changes, so the coordinator can
    /// re-resolve its palette and redraw the visible rows with it.
    var onAppearanceChange: (() -> Void)?

    init(tableView: NSTableView) {
        self.tableView = tableView
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.setAccessibilityElement(false)
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        tableView.translatesAutoresizingMaskIntoConstraints = true
        tableView.autoresizingMask = [.width]
        tableView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        scrollView.documentView = tableView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layoutTableDocument()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    /// Updates the document frame after row-count, width, or corrected-height
    /// changes. Width invalidation starts at the visible boundary so resize
    /// estimates cannot move content above the cursor.
    func layoutTableDocument() {
        let width = max(1, scrollView.contentView.bounds.width)
        let widthChanged = abs(lastDocumentWidth - width) > 0.5
        lastDocumentWidth = width
        if widthChanged {
            let visibleRect = tableView.enclosingScrollView.map {
                tableView.convert($0.contentView.bounds, from: $0.contentView)
            } ?? tableView.bounds
            let boundary = tableView.rows(in: visibleRect).location
            let start = boundary == NSNotFound ? 0 : boundary
            if start < tableView.numberOfRows {
                tableView.noteHeightOfRows(
                    withIndexesChanged: IndexSet(integersIn: start..<tableView.numberOfRows)
                )
            }
        }
        tableView.frame.size.width = width
        tableView.frame.size.height = max(1, tableView.fittingSize.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let timestamp = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            self?.onPaint?(timestamp)
        }
    }

    override func accessibilityChildren() -> [Any] {
        messageElements
    }
}

@MainActor
fileprivate final class BlockMessageAccessibilityElement: NSView {
    private let spokenLabel: String
    private let childElements: [BlockAccessibilityElement]

    init(label: String, blocks: [BlockAccessibilityElement]) {
        spokenLabel = label
        childElements = blocks
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityLabel() -> String? { spokenLabel }
    override func accessibilityChildren() -> [Any] { childElements }
}

@MainActor
fileprivate final class BlockAccessibilityElement: NSView {
    private let spokenLabel: String

    init(label: String) {
        spokenLabel = label
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityLabel() -> String? { spokenLabel }
}
