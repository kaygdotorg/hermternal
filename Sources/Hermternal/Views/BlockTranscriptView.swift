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

private extension BlockInk {
    /// WCAG 2.1 relative luminance of the resolved sRGB components.
    ///
    /// https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
    var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red)
            + 0.7152 * channel(green)
            + 0.0722 * channel(blue)
    }

    /// WCAG 2.1 contrast ratio against `other`.
    ///
    /// Both operands must be opaque: the ratio is defined between two colours,
    /// and a partly transparent one has no luminance until it is composited
    /// over a backdrop this type does not know.
    ///
    /// https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio
    func contrast(with other: BlockInk) -> Double {
        let mine = relativeLuminance
        let theirs = other.relativeLuminance
        return (max(mine, theirs) + 0.05) / (min(mine, theirs) + 0.05)
    }

    static let opaqueWhite = BlockInk(red: 1, green: 1, blue: 1, alpha: 1)
    static let opaqueBlack = BlockInk(red: 0, green: 0, blue: 0, alpha: 1)
}

/// A user bubble's silhouette and fill.
///
/// The tail is the reason this exists. AppKit draws rounded rectangles, and
/// nothing in the system draws a Messages balloon, so the outline is
/// hand-rolled — but as one closed path rather than a rounded rect with a
/// separate wedge on top. Two stacked shapes share an edge along the join,
/// where both are antialiased: the coverage there compounds on an opaque fill
/// and shows a seam on any fill that is not, and the join moves whenever the
/// corner radius or the fill changes. One path has one silhouette and one
/// antialiased edge, whatever colour fills it.
///
/// Every tail measurement is a ratio of the corner radius, taken off a Retina
/// capture of a real sent bubble at an assumed 2x scale. The capture's bubble
/// was a 59px-tall capsule, so its corner radius was 29.5px = 14.75pt, and the
/// tail measured 10px = 5pt of drop, a tip 12px = 6pt inside the bubble's
/// widest point, and an underside rejoining the bottom edge 7px = 3.5pt past
/// the start of the corner. Ratios rather than points, because they survive a
/// wrong scale assumption; the reproduction tracks the capture's own outline to
/// within 3px of 29.5, or about 1pt at this radius.
///
/// Two things that assumption talk usually gets wrong, both measured rather
/// than assumed: the tail's tip stays *inside* the bubble's widest point rather
/// than poking past the trailing edge, so it needs no extra trailing room; and
/// the corners are circular arcs, because a single-line sent bubble is a
/// capsule, whose caps are semicircles by definition and where a continuous
/// curve would have nothing to improve on.
private struct BlockBubbleShape: Equatable {
    /// How far the tail drops below the bubble's bottom edge.
    static let riseRatio: CGFloat = 0.34
    /// How far inside the trailing edge the tip sits.
    static let tipRatio: CGFloat = 0.41
    /// How far past the corner's start the underside rejoins the bottom edge.
    static let tuckRatio: CGFloat = 0.12
    /// Where on the bottom-trailing corner the tail leaves the arc, measured
    /// from the trailing edge.
    ///
    /// This is the value a first attempt got wrong. Departing at the arc's
    /// *start* replaces the whole corner with the tail sweep, and at a 14pt
    /// radius that collapses into a chamfered corner with no tail in it. In the
    /// capture the outline tracks the corner arc to within a pixel until 26
    /// degrees above the arc's foot, so the corner still reads as a corner and
    /// the tail hangs off the end of it.
    static let departureAngle: CGFloat = 64 * .pi / 180

    let fill: BlockInk
    let radius: CGFloat
    /// A message's blocks are separate rows, so a bubble's caps belong to the
    /// message's first and last row and the rows between it are square-edged.
    let roundsTop: Bool
    let roundsBottom: Bool
    /// Exactly one row per message: the last one. The tail marks where the
    /// message ends, not where a block does.
    let hasTail: Bool

    /// Authored with y increasing *downward*, because that is how the shape
    /// reads: cap on top, tail underneath. The layer's own space runs the other
    /// way — measured, not assumed: a first cut authored against `maxY` drew the
    /// tail above the bubble's top edge — so `mirrored(in:)` is what actually
    /// hands a path to the layer.
    func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let top = roundsTop ? radius : 0
        let bottom = roundsBottom ? radius : 0
        let minX = rect.minX, maxX = rect.maxX
        let minY = rect.minY, maxY = rect.maxY
        let rise = radius * Self.riseRatio

        path.move(to: CGPoint(x: minX + top, y: minY))
        path.addLine(to: CGPoint(x: maxX - top, y: minY))
        path.addArc(
            tangent1End: CGPoint(x: maxX, y: minY),
            tangent2End: CGPoint(x: maxX, y: minY + top),
            radius: top
        )
        if hasTail {
            let corner = CGPoint(x: maxX - radius, y: maxY - radius)
            path.addLine(to: CGPoint(x: maxX, y: maxY - radius))
            // Angles run with the authored space: a point on the corner is
            // `corner + radius * (cos, sin)`, so 0 is the trailing edge and
            // .pi/2 is the arc's foot on the bottom edge.
            path.addArc(
                center: corner,
                radius: radius,
                startAngle: 0,
                endAngle: Self.departureAngle,
                clockwise: false
            )
            // Out to the tip, holding almost vertical: the capture's tail is a
            // narrow flick, not a diagonal cut across the corner.
            path.addQuadCurve(
                to: CGPoint(x: maxX - radius * Self.tipRatio, y: maxY + rise),
                control: CGPoint(x: maxX - radius * 0.5, y: maxY + rise * 0.15)
            )
            // The underside sweeps back under the bubble and meets the bottom
            // edge tangentially, so the tail reads as grown rather than glued.
            path.addQuadCurve(
                to: CGPoint(x: maxX - radius - radius * Self.tuckRatio, y: maxY),
                control: CGPoint(x: maxX - radius * 0.85, y: maxY + rise * 0.30)
            )
        } else {
            path.addLine(to: CGPoint(x: maxX, y: maxY - bottom))
            path.addArc(
                tangent1End: CGPoint(x: maxX, y: maxY),
                tangent2End: CGPoint(x: maxX - bottom, y: maxY),
                radius: bottom
            )
        }
        path.addLine(to: CGPoint(x: minX + bottom, y: maxY))
        path.addArc(
            tangent1End: CGPoint(x: minX, y: maxY),
            tangent2End: CGPoint(x: minX, y: maxY - bottom),
            radius: bottom
        )
        path.addLine(to: CGPoint(x: minX, y: minY + top))
        path.addArc(
            tangent1End: CGPoint(x: minX, y: minY),
            tangent2End: CGPoint(x: minX + top, y: minY),
            radius: top
        )
        path.closeSubpath()
        return path
    }

    /// The silhouette in the layer's own upward-y space.
    func mirrored(in rect: CGRect) -> CGPath {
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.maxY + rect.minY)
        // `path(in:)` closes its subpath, so the copy is a closed path too.
        return path(in: rect).copy(using: &flip) ?? path(in: rect)
    }
}

/// A row's drawn surface: a user bubble, a fenced card, or nothing.
///
/// The backing layer is a `CAShapeLayer` so a bubble can be one filled path.
/// A card stays on the layer's own rounded-rect drawing, which is what a card
/// is and is cheaper than a path; only the balloon needs geometry AppKit has no
/// API for.
@MainActor
private final class BlockSurfaceView: NSView {
    /// The bubble to fill, or `nil` for a card or a blank row.
    var bubble: BlockBubbleShape? {
        didSet {
            guard bubble != oldValue else { return }
            needsLayout = true
        }
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAShapeLayer()
        layer.masksToBounds = false
        // A shape layer's default fill is opaque black, and a row is recycled
        // into every role, so the fill is only ever set alongside a path.
        layer.fillColor = nil
        // Scrolling recycles rows constantly. An implicit path or fill
        // animation would morph one message's bubble into the next one's.
        layer.actions = ["path": NSNull(), "fillColor": NSNull()]
        return layer
    }

    /// The tail hangs below the bubble's bottom edge, which is also the row's,
    /// so neither this view nor its layer may clip. Measured, not assumed: with
    /// the default clipping the tail rendered flush with the bottom edge and
    /// read as a chamfered corner rather than a tail.
    override var clipsToBounds: Bool {
        get { false }
        set { _ = newValue }
    }

    override func layout() {
        super.layout()
        guard let shape = layer as? CAShapeLayer else { return }
        guard let bubble, bounds.width > 0, bounds.height > 0 else {
            shape.path = nil
            shape.fillColor = nil
            return
        }
        shape.fillColor = bubble.fill.cgColor
        shape.path = bubble.mirrored(in: bounds)
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
/// markers use the secondary label, code uses a secondary background and
/// separator border, a user block fills an opaque bubble, and Find marks
/// text with the resolved accent. Point sizes come from `MessageTypography`.
/// This keeps one type scale for every block role.
private struct BlockRenderStyle: Hashable, Sendable {
    /// Bumped whenever the drawn attributes or the measurement change, so a
    /// height cached by an older algorithm is never reused. Version 1 drew
    /// an unstyled string and measured a bare font.
    static let rendererVersion = 2

    /// The user block's bubble: `.padding(.vertical, 10)`.
    static let userVerticalInset: CGFloat = 10
    /// The assistant and system rows' own vertical rhythm.
    static let assistantVerticalInset: CGFloat = 8
    /// A code block's `.padding(10)` around the body.
    static let codeVerticalInset: CGFloat = 10
    static let codeHorizontalInset: CGFloat = 10
    /// A code block's header: `.padding(.vertical, 6)`.
    static let codeHeaderPadding: CGFloat = 6
    /// The header's `Divider()`.
    static let codeDividerHeight: CGFloat = 1
    /// `.strokeBorder(.separator, lineWidth: 0.5)`.
    static let codeBorderWidth: CGFloat = 0.5

    /// The assistant mark's square box.
    ///
    /// The drawing is 256x256 with ink filling 99% of its height and 70% of its
    /// width, so the box draws a glyph 23.7pt tall and 17.9pt wide. Measured
    /// against the first line it labels — 13pt body text, 16pt line height,
    /// 9.16pt cap height — that reads as a speaker's mark rather than a badge
    /// floating beside the answer. The previous 20pt box drew 19.8pt of ink,
    /// which the user found small next to the same line.
    static let assistantMarkSize: CGFloat = 24
    /// Where the mark's box starts, matching the leading a system row uses.
    static let assistantMarkLeading: CGFloat = 20
    /// The leading inset for an assistant row's text.
    ///
    /// The gutter and the glyph are separate values: growing the mark inside a
    /// fixed gutter would only close the gap on the mark's left. This is the
    /// mark's box (20 + 24 = 44), plus 11pt of optical space measured from the
    /// ink's right edge at 40.95 rather than from the box, less the 14pt of
    /// horizontal inset the text view adds on its own so the space is not
    /// counted twice. It was 48, which drew 25pt of optical gap; this draws 11.
    ///
    /// Every row of a message uses it, not only the row that draws the mark, so
    /// an answer stays optically aligned below its first paragraph. It is not
    /// an input to `contentWidth`, which reads only the table's width and the
    /// typography constants — so the reading measure is unchanged, the text
    /// simply starts further left, and no cached layout goes stale.
    static let assistantTextLeading: CGFloat = 38
    let appearanceName: String
    let isDark: Bool

    /// The primary label for prose and assistant blocks.
    let label: BlockInk
    /// The secondary label for list markers, code headers, and system messages.
    let secondaryLabel: BlockInk
    /// Code inherits the prose label.
    let codeForeground: BlockInk
    let codeBackground: BlockInk
    let codeBorder: BlockInk
    let codeDivider: BlockInk
    let userBubble: BlockInk
    let userBubbleForeground: BlockInk
    /// The wash behind text selected inside a user bubble.
    let userBubbleSelection: BlockInk
    let link: BlockInk
    let quote: BlockInk
    /// Find match colour from the system accent or the explicit override.
    let findMatch: BlockInk
    /// Active Find match colour from the same accent source.
    let findActiveMatch: BlockInk
    /// The accent used for native text selection.
    let selectionHighlight: BlockInk

    let bodySize: Double
    let headingSizes: [Double]
    let codeSize: Double
    let codeLabelSize: Double
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
        let accent = AccentColorStore.resolvedColor()
        // Messages fills a sent bubble with the platform's system blue and
        // sets white text on it, so the bubble reads as the user's own voice
        // rather than as a tint of whatever else the app is accented with.
        // `NSColor.systemBlue` *is* that blue by definition instead of by
        // transcription; measured on macOS 26.6.2 it resolves to #0088FF in
        // Aqua and #0091FF in Dark Aqua. When the user asks for the accent
        // instead, it comes from the same resolution above as every other tint
        // here, so an in-app override is honoured rather than ignored.
        let bubbleFill = BlockInk(
            UserBubbleFillStore.usesAccent() ? accent : NSColor.systemBlue
        )
        let bubbleForeground = Self.bubbleForeground(on: bubbleFill)
        let bubbleSelection = Self.bubbleSelection(behind: bubbleForeground)
        let link = BlockInk(accent)
        let findMatch = BlockInk(accent.withAlphaComponent(
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.72
        ))
        let findActiveMatch = BlockInk(accent)

        self.label = label
        self.secondaryLabel = secondaryLabel
        codeForeground = label
        self.codeBackground = codeBackground
        self.codeBorder = codeBorder
        self.codeDivider = codeDivider
        userBubble = bubbleFill
        userBubbleForeground = bubbleForeground
        userBubbleSelection = bubbleSelection
        self.link = link
        quote = label
        self.findMatch = findMatch
        self.findActiveMatch = findActiveMatch
        selectionHighlight = BlockInk(accent.withAlphaComponent(0.24))

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
            // The bubble's ink and its selection wash both vary independently
            // of the fill now: two different fills can want the same text
            // colour, and one fill can want two different ones depending on
            // Increase Contrast. Cached shaped text carries the resolved
            // colour, so all three belong in the key that invalidates it.
            userBubble, userBubbleForeground, userBubbleSelection,
            link, findMatch, findActiveMatch, selectionHighlight
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

    /// The bubble's text colour, chosen by measurement rather than assertion.
    ///
    /// Messages pairs white with the platform's system blue, and AppKit ships
    /// that same pairing itself: `alternateSelectedControlTextColor` is white
    /// on `selectedContentBackgroundColor`. Measured on macOS 26.6.2 white on
    /// system blue is 3.52:1 in Aqua and 3.23:1 in Dark Aqua — past WCAG 2.1's
    /// 3:1 bar for large and UI text, short of its 4.5:1 small-text bar. White
    /// is therefore the default, because that is what makes the transcript
    /// read as Messages.
    ///
    /// Two cases must not inherit that default. An accent the user picked can
    /// be any hue, including ones white disappears on, and Increase Contrast is
    /// an explicit request for more separation than Apple's own pairing gives.
    /// Both raise the floor to 4.5:1 and fall back to the darker ink, which is
    /// why this is computed from the fill instead of written down per
    /// appearance: neither the accent nor a future system blue is known here.
    private static func bubbleForeground(on fill: BlockInk) -> BlockInk {
        let floor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? 4.5
            : 3.0
        let onWhite = fill.contrast(with: .opaqueWhite)
        if onWhite >= floor { return .opaqueWhite }
        return onWhite >= fill.contrast(with: .opaqueBlack)
            ? .opaqueWhite
            : .opaqueBlack
    }

    /// The wash behind text selected inside a bubble.
    ///
    /// A selection has to register on an opaque fill without eating the text's
    /// own contrast, and washing the fill in its *own* text colour does exactly
    /// the wrong thing: white at 25% over system blue lands on #47A9FF, where
    /// white text falls to 2.50:1. The opposite ink darkens the fill instead,
    /// reaching #006ABF where white text rises to 5.50:1, so selecting text in
    /// a bubble makes it easier to read rather than harder.
    ///
    /// This is the transcript's one selection colour that is not the accent.
    /// Assistant and system rows still use `selectionHighlight`, and every Find
    /// mark is still accent-tinted; only the wash that lands *inside* an opaque
    /// bubble resolves against the bubble rather than against the window.
    private static func bubbleSelection(behind foreground: BlockInk) -> BlockInk {
        let level = foreground.relativeLuminance > 0.5 ? 0.0 : 1.0
        return BlockInk(red: level, green: level, blue: level, alpha: 0.25)
    }
}

private extension BlockRenderStyle {
    /// Fonts are built from plain point sizes, so an off-main builder never
    /// asks AppKit to resolve a text style or a font descriptor collection.
    var bodyFont: NSFont { .systemFont(ofSize: CGFloat(bodySize)) }

    /// Heading sizes use the `.title2`, `.title3`, and `.headline` scale.
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
    /// Streaming blocks use plain text while deltas land, so the renderer
    /// avoids reparsing the incomplete message.
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
            // User blocks use body text inside a trailing-aligned bubble.
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

        guard let segment = MarkdownSegment.parse(
            source,
            owner: .blockRowConfiguration
        ).first else {
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
            // Heading size and tracking have no added leading, so a heading
            // stays tighter than the body it introduces.
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

    static func thinking(style: BlockRenderStyle) -> BlockPreparedText {
        paragraph(
            AttributedString("•••"),
            font: style.bodyFont,
            color: style.secondaryLabel,
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
    /// A list block places its marker in a fixed column on the first text
    /// baseline. Wrapped lines align under the item text.
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
        // Code blocks do not scroll horizontally. Long lines wrap by
        // character so content remains visible in the table row.
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

    /// A code block's body without its delimiters. The source range spans the
    /// opening fence through the closing one.
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

    /// Keep the author's delimiter, so `3)` stays `3)` and `3.` stays `3)`.
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
/// source text remains in `TranscriptRendererInput.messages` and is sliced
/// only for visible row configuration or off-main preparation.
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
        let start = HermternalSwitchTrace.transcriptPhaseClock()
        // Two intervals, because they answer different questions: the update
        // bracket is our own work, and the commit bracket ends when Core
        // Animation actually presents. The gap between them is the ~60-85 ms
        // that no counter of ours could see, and the reason the sidebar's
        // selection plate may not appear until the transcript is done.
        let transcriptSignpost = SelectionLatencySignposts.beginTranscriptUpdate(
            sessionID: input.routeIdentity,
            generation: input.generation
        )
        let commitSignpost = SelectionLatencySignposts.beginCommit(
            sessionID: input.routeIdentity,
            generation: input.generation
        )
        if commitSignpost != nil {
            // Chain rather than replace: another completion block on this
            // transaction belongs to somebody else's work.
            let existing = CATransaction.completionBlock()
            CATransaction.setCompletionBlock {
                existing?()
                SelectionLatencySignposts.endCommit(
                    commitSignpost,
                    generation: input.generation
                )
            }
        }
        context.coordinator.update(container: nsView, input: input)
        SelectionLatencySignposts.endTranscriptUpdate(transcriptSignpost)
        guard let start else { return }
        let end = DispatchTime.now().uptimeNanoseconds
        HermternalSwitchTrace.transcriptPhaseUpdateNSView(start: start, end: end)
        HermternalSwitchTrace.transcriptPhaseUpdateEnded(at: end)
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
        /// A publication may arrive before SwiftUI lays out the hosted view.
        /// Keep it pending until a layout reports usable geometry.
        private var layoutWorkPending = false
        /// Last committed visible rows. SwiftUI can publish while the hosted
        /// table is between layout passes; the clip view is then zero-sized.
        /// Reusing this route-local range keeps later publications live.
        private var lastVisibleRowIndexes: IndexSet?
        /// Suppresses the container's layout callback while `update` is
        /// establishing a publication. The callback from that pass can still
        /// observe the old zero-sized geometry; only a later real layout may
        /// consume the pending reload.
        private var isUpdating = false
        /// Eight rows keeps a small amount of rich content ready during a
        /// wheel tick without shaping blocks outside the visible neighborhood.
        private let overdrawRows = 8
        /// A streaming block's body changes on every publication. Its cache
        /// identity is a cheap revision token rather than a second full pass
        /// over the accumulated message text.
        private var streamingRevision: UInt64 = 0
        private var streamingIdentityTokens: [String: UInt64] = [:]
        private var nextStreamingIdentityToken: UInt64 = 1

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
            result.onLayout = { [weak self] in
                self?.scheduleLayoutWork()
            }
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
            // Three signals change the palette without changing the effective
            // appearance, and all of them have to invalidate prepared colours
            // the way a light-to-dark switch does.
            //
            // The system's own colours changing, which macOS posts:
            let colorToken = NotificationCenter.default.addObserver(
                forName: NSColor.systemColorsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.appearanceDidChange()
            }
            observers.append((NotificationCenter.default, colorToken))
            // The app's own palette inputs — the accent override, and which
            // fill a user bubble takes — which only this app knows about:
            let paletteToken = NotificationCenter.default.addObserver(
                forName: AccentColorStore.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.appearanceDidChange()
            }
            observers.append((NotificationCenter.default, paletteToken))
            // And Increase Contrast, which flips the bubble's text colour:
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
            let diffStart = HermternalSwitchTrace.transcriptPhaseClock()
            let routeChanged = routeIdentity != input.routeIdentity
            if routeChanged {
                generation &+= 1
                preparation.cancel()
                lastVisibleRowIndexes = nil
                prepared.removeAll(keepingCapacity: true)
                layoutCacheResetForRoute()
                selection.clear()
                layoutWorkPending = false
            }
            let oldRows = rows
            let oldBlocks = blocks
            let oldMessages = messages
            isUpdating = true
            defer { isUpdating = false }

            container.onPaint = input.onPaint
            self.container = container
            self.tableView = container.tableView
            self.routeIdentity = input.routeIdentity
            self.isReadOnly = input.isReadOnly
            self.isStreaming = input.isStreaming
            self.findQuery = input.findQuery
            self.findMatches = input.findMatches
            self.activeFindIndex = input.activeFindIndex
            self.pendingMessageID = input.pendingMessageID
            self.hasMoreOlderMessages = input.window.hasMoreOlderMessages
            self.onRequestOlder = input.onRequestOlder
            self.onCopyCode = input.onCopyCode
            self.messages = input.messages
            self.messageTextByID = Dictionary(uniqueKeysWithValues: input.messages.map {
                (messageID(for: $0), $0.text)
            })
            if input.messages.contains(where: { $0.role == .assistant && $0.isStreaming }) {
                streamingRevision &+= 1
            }

            let incomingBlocks = normalizedBlocks(
                input.blocks,
                messages: input.messages
            )
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
            let rowCountChanged = oldRows.count != rows.count
            container.tableView.isHidden = rows.isEmpty
            if routeChanged || oldRows.isEmpty && !rows.isEmpty {
                container.tableView.noteNumberOfRowsChanged()
                // Establish the document width before any reload can ask
                // `heightOfRow`. Otherwise those reads use the old one-point
                // table frame while preparation below keys from the real clip
                // width.
                container.layoutTableDocument()
                if let visibleIndexes = reloadVisibleRowIndexes(in: container.tableView) {
                    layoutWorkPending = false
                    HermternalSwitchTrace.transcriptPhaseReload(
                        full: false,
                        rows: visibleIndexes.count
                    )
                    container.tableView.reloadData(
                        forRowIndexes: visibleIndexes,
                        columnIndexes: IndexSet(integer: 0)
                    )
                } else {
                    let visible = container.tableView.rows(
                        in: visibleRect(for: container.tableView)
                    )
                    layoutWorkPending = true
                    HermternalSwitchTrace.transcriptPhaseReloadDeferred(
                        rows: rows.count,
                        visibleLocation: visible.location,
                        visibleLength: visible.length
                    )
                }
            } else if rowCountChanged || !changed.isEmpty {
                if rowCountChanged {
                    container.tableView.noteNumberOfRowsChanged()
                }
                // The width must be committed before targeted reload invokes
                // the delegate's height callback.
                container.layoutTableDocument()
                if !changed.isEmpty {
                    if reloadVisibleRowIndexes(in: container.tableView) != nil {
                        layoutWorkPending = false
                        HermternalSwitchTrace.transcriptPhaseReload(
                            full: false,
                            rows: changed.count
                        )
                        container.tableView.reloadData(
                            forRowIndexes: changed,
                            columnIndexes: IndexSet(integer: 0)
                        )
                    } else {
                        let visible = container.tableView.rows(
                            in: visibleRect(for: container.tableView)
                        )
                        layoutWorkPending = true
                        HermternalSwitchTrace.transcriptPhaseReloadDeferred(
                            rows: rows.count,
                            visibleLocation: visible.location,
                            visibleLength: visible.length
                        )
                    }
                }
            }
            if let diffStart {
                HermternalSwitchTrace.transcriptPhaseCoordinatorDiff(
                    start: diffStart,
                    end: DispatchTime.now().uptimeNanoseconds
                )
            }
            prepareVisibleBlocks()
            schedulePositioning(routeChanged: routeChanged)
        }

        func dismantle(container: BlockTranscriptContainerView) {
            generation &+= 1
            preparation.cancel()
            layoutWorkPending = false
            container.onLayout = nil
            container.onAppearanceChange = nil
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
            guard rows.indices.contains(row) else { return nil }
            let traceEnabled = HermternalSwitchTrace.isEnabled
            let wasReused = traceEnabled
                && tableView.view(atColumn: 0, row: row, makeIfNecessary: false) != nil
            guard let view = tableView.makeView(
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
            let sliceStart = traceEnabled && preparedValue == nil
                ? HermternalSwitchTrace.transcriptPhaseClock()
                : nil
            let sourceText: String
            if let preparedValue {
                // Preparation already captured this range off-main. Reuse
                // that value instead of copying the source again on paint.
                sourceText = preparedValue.text
            } else {
                sourceText = BlockText.slice(
                    value.message.text,
                    range: value.block.sourceRange
                )
            }
            if let sliceStart {
                HermternalSwitchTrace.transcriptPhaseTextSlice(
                    start: sliceStart,
                    end: DispatchTime.now().uptimeNanoseconds
                )
            }
            view.configure(
                block: value.block,
                message: value.message,
                sourceText: sourceText,
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
            if traceEnabled {
                HermternalSwitchTrace.transcriptPhaseRowConfiguration(reused: wasReused)
            }
            return view
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let heightStart = HermternalSwitchTrace.transcriptPhaseClock()
            guard rows.indices.contains(row) else {
                if let heightStart {
                    HermternalSwitchTrace.transcriptPhaseHeight(
                        cacheHit: false,
                        start: heightStart,
                        end: DispatchTime.now().uptimeNanoseconds
                    )
                }
                return 24
            }
            let value = rows[row]
            let key = layoutKey(for: value.block, message: value.message, tableView: tableView)
            if let cached = layoutCache.value(for: key) {
                if let heightStart {
                    HermternalSwitchTrace.transcriptPhaseHeight(
                        cacheHit: true,
                        start: heightStart,
                        end: DispatchTime.now().uptimeNanoseconds
                    )
                }
                return cached.measuredHeight
            }
            // The fallback is arithmetic over the segmenter's range metadata.
            // It never slices or otherwise reads the message body.
            let estimated = BlockHeightEstimator.estimatedHeight(
                for: value.block.kind,
                width: contentWidth(for: value.message, in: tableView),
                contentLength: value.block.sourceRange.count
            )
            if let heightStart {
                HermternalSwitchTrace.transcriptPhaseHeight(
                    cacheHit: false,
                    start: heightStart,
                    end: DispatchTime.now().uptimeNanoseconds
                )
            }
            return estimated
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false
        }

        /// A row wrapper that does not clip its cell view.
        ///
        /// The last row of a user message draws a bubble tail that hangs below
        /// its own bottom edge. `NSTableRowView` clips, which cut the tail off
        /// flush and left the bubble reading as a chamfered corner — measured on
        /// a screenshot, after `clipsToBounds` on the cell view alone changed
        /// nothing.
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            tableView.makeView(
                withIdentifier: BlockTranscriptRowBackgroundView.identifier,
                owner: self
            ) as? NSTableRowView ?? BlockTranscriptRowBackgroundView()
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
                HermternalSwitchTrace.transcriptPhaseReload(
                    full: true,
                    rows: tableView.numberOfRows
                )
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

        private func normalizedBlocks(
            _ blocks: [TranscriptBlock],
            messages: [ChatMessage]
        ) -> [TranscriptBlock] {
            let blocksByMessageID = Dictionary(grouping: blocks, by: \.messageID)
            var result: [TranscriptBlock] = []
            result.reserveCapacity(blocks.count + messages.count)
            for message in messages {
                let id = messageID(for: message)
                if message.role == .assistant, message.isStreaming {
                    result.append(
                        TranscriptBlock(
                            messageID: id,
                            blockIndex: 0,
                            kind: .paragraph,
                            sourceRange: 0..<message.text.utf16.count,
                            contentHash: streamingContentHash(for: id)
                        )
                    )
                } else {
                    result.append(contentsOf: blocksByMessageID[id] ?? [])
                }
            }
            return result
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
                  !oldMessage.isStreaming,
                  !newMessage.isStreaming,
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
                    messageIndex: index
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
        

        private func visibleRowIndexes(in tableView: NSTableView) -> IndexSet? {
            guard tableView.bounds.width > 1,
                  let clip = tableView.enclosingScrollView?.contentView,
                  clip.bounds.width > 1,
                  clip.bounds.height > 1
            else { return nil }
            let visible = tableView.rows(in: visibleRect(for: tableView))
            guard visible.location != NSNotFound, visible.length > 0 else {
                return nil
            }
        
            let first = max(0, visible.location)
            let last = min(rows.count, visible.location + visible.length)
            guard first < last else { return nil }
            let result = IndexSet(integersIn: first..<last)
            lastVisibleRowIndexes = result
            return result
        }
        
        private func reloadVisibleRowIndexes(in tableView: NSTableView) -> IndexSet? {
            if let live = visibleRowIndexes(in: tableView) {
                return live
            }
            guard !rows.isEmpty, let remembered = lastVisibleRowIndexes else {
                return nil
            }
            let bounded = remembered.intersection(IndexSet(integersIn: 0..<rows.count))
            return bounded.isEmpty ? nil : bounded
        }

        /// Applies a held publication from the first layout with usable
        /// geometry. This is called by `BlockTranscriptContainerView.layout`,
        /// not by a timer or an opportunistic main-queue hop.
        private func scheduleLayoutWork() {
            guard !isUpdating,
                  layoutWorkPending,
                  !rows.isEmpty,
                  let tableView,
                  let visibleIndexes = reloadVisibleRowIndexes(in: tableView)
            else {
                return
            }
            layoutWorkPending = false
            HermternalSwitchTrace.transcriptPhaseReload(
                full: false,
                rows: visibleIndexes.count
            )
            tableView.reloadData(
                forRowIndexes: visibleIndexes,
                columnIndexes: IndexSet(integer: 0)
            )
            prepareVisibleBlocks()
            schedulePositioning(routeChanged: false)
        }

        private func prepareVisibleBlocks() {
            guard let tableView, !rows.isEmpty,
                  let visible = reloadVisibleRowIndexes(in: tableView)
            else { return }
            let firstVisible = visible.first ?? 0
            let lastVisible = visible.last.map { $0 + 1 } ?? rows.count
            let lower = max(0, firstVisible - overdrawRows)
            let upper = min(rows.count, lastVisible + overdrawRows)
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
            // `layoutTableDocument` commits this document width before
            // AppKit asks for any row height. Using the table's committed
            // bounds here makes reads and background writes observe the same
            // width snapshot instead of mixing a pre-layout frame with the
            // clip view's next width.
            // This ordering fix is still required: the earlier one-point
            // width could produce a genuinely different bucket. It was not
            // the cause of the old zero-hit trace, though; preparation writes
            // arrive after the publication's first height pass.
            let tableWidth = max(1, tableView.bounds.width)
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
                if let pending = pendingMessageID {
                    guard let index = rows.firstIndex(where: { $0.message.id == pending }) else { return }
                    tableView.scrollRowToVisible(index)
                    return
                }
                if let activeIndex = activeFindIndex,
                   findMatches.indices.contains(activeIndex) {
                    let match = findMatches[activeIndex]
                    guard let index = rows.firstIndex(where: {
                        $0.messageIndex == match.messageIndex
                    }) else { return }
                    scrollRowToCenter(index, in: tableView)
                    return
                }
                if routeChanged || isStreaming, !isReadOnly, !rows.isEmpty {
                    let clip = tableView.enclosingScrollView?.contentView
                    clip?.scroll(to: NSPoint(x: 0, y: max(0, tableView.bounds.height - (clip?.bounds.height ?? 0))))
                    if let clip { tableView.enclosingScrollView?.reflectScrolledClipView(clip) }
                }
            }
        }

        private func scrollRowToCenter(_ row: Int, in tableView: NSTableView) {
            guard let clip = tableView.enclosingScrollView?.contentView,
                  row >= 0,
                  row < tableView.numberOfRows
            else { return }
            let rowRect = tableView.rect(ofRow: row)
            guard !rowRect.isNull, !rowRect.isEmpty else { return }
            let visibleHeight = clip.bounds.height
            let maximumOrigin = max(0, tableView.bounds.height - visibleHeight)
            let centeredOrigin = rowRect.midY - visibleHeight / 2
            clip.scroll(to: NSPoint(
                x: clip.bounds.origin.x,
                y: min(max(0, centeredOrigin), maximumOrigin)
            ))
            tableView.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        private func updateAccessibility(in container: BlockTranscriptContainerView) {
            container.messageElements = Dictionary(grouping: rows, by: { $0.message.id }).values.map {
                BlockMessageAccessibilityElement(
                    label: $0.first?.message.text ?? "",
                    blocks: $0.map {
                        BlockAccessibilityElement(
                            sourceText: $0.message.text,
                            sourceRange: $0.block.sourceRange
                        )
                    }
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
        private func streamingContentHash(for messageID: String) -> UInt64 {
            let hashStart = HermternalSwitchTrace.transcriptPhaseClock()
            let token: UInt64
            if let existing = streamingIdentityTokens[messageID] {
                token = existing
            } else {
                token = nextStreamingIdentityToken
                nextStreamingIdentityToken &+= 1
                streamingIdentityTokens[messageID] = token
            }
            // The token distinguishes simultaneous streaming messages; the
            // revision distinguishes each publication. As with the previous
            // FNV digest, this is a bounded cache identity, not user data.
            let result = token &* 1_000_000_007 &+ streamingRevision
            if let hashStart {
                HermternalSwitchTrace.transcriptPhaseContentHash(
                    start: hashStart,
                    end: DispatchTime.now().uptimeNanoseconds
                )
            }
            return result
        }

    }
}

@MainActor
private final class BlockTranscriptTableView: NSTableView {
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        if let recycled = super.makeView(withIdentifier: identifier, owner: owner) {
            return recycled
        }
        switch identifier {
        case BlockTranscriptRowView.identifier:
            return BlockTranscriptRowView()
        case BlockTranscriptRowBackgroundView.identifier:
            return BlockTranscriptRowBackgroundView()
        default:
            return nil
        }
    }
}

/// The row wrapper the table builds, so a bubble tail can hang past its row.
///
/// `NSTableRowView` clips its cell view by default; the tail is the only thing
/// in the transcript that draws outside its row, and it is 4.8pt of a shape
/// that has nothing to collide with — the row below it starts with transparent
/// padding.
@MainActor
private final class BlockTranscriptRowBackgroundView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("BlockTranscriptRowBackground")

    override var clipsToBounds: Bool {
        get { false }
        set { _ = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class BlockTranscriptRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BlockTranscriptRow")
    /// The row's own drawn surface: the user bubble, or a fenced block's card.
    /// It tracks the text view's frame rather than the cell's, so a bubble hugs
    /// its column instead of banding the whole row.
    private let surface = BlockSurfaceView()
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
        // The last row of a user message draws a tail that hangs past the row's
        // own bottom edge, into the transparent top of the row below.
        clipsToBounds = false
        layer?.masksToBounds = false

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.wantsLayer = true
        // A fenced card is a card: SwiftUI draws it with `.continuous`, and the
        // layer draws that for free. A bubble ignores this and fills its own
        // path, because its caps are semicircles and its tail is not a corner.
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
        // The code-copy control is a plain secondary image-only button.
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
            assistantMark.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: BlockRenderStyle.assistantMarkLeading
            ),
            assistantMark.topAnchor.constraint(
                equalTo: topAnchor,
                constant: BlockRenderStyle.assistantVerticalInset
            ),
            assistantMark.widthAnchor.constraint(
                equalToConstant: BlockRenderStyle.assistantMarkSize
            ),
            assistantMark.heightAnchor.constraint(
                equalToConstant: BlockRenderStyle.assistantMarkSize
            )
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

        let isThinking = message.role == .assistant
            && message.isStreaming
            && message.text.isEmpty
        let isCode = block.kind == .code && !isThinking
        let content = isThinking
            ? BlockText.thinking(style: style)
            : (prepared?.content ?? BlockText.fallback(
                sourceText,
                kind: block.kind,
                role: message.role,
                style: style
            ))
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
        // Inside an opaque bubble the backdrop is the bubble, not the window,
        // so both halves of the selection resolve against it: the accent wash
        // barely registers on a saturated fill and `labelColor` would put black
        // text on blue. Assistant and system rows are unchanged.
        let isBubble = message.role == .user
        textView.selectedTextAttributes = [
            .backgroundColor: isBubble
                ? style.userBubbleSelection.nsColor
                : style.selectionHighlight.nsColor,
            .foregroundColor: isBubble
                ? style.userBubbleForeground.nsColor
                : style.label.nsColor
        ]
        textView.textStorage?.setAttributedString(content.value)
        applyFindMarks(findRanges, block: block, sourceText: sourceText, style: style)

        assistantMark.isHidden = message.role != .assistant || !isFirstInMessage
        if !assistantMark.isHidden {
            assistantMark.image = BlockAssistantMark.image(isDark: style.isDark)
        }
        languageLabel.isHidden = !isCode
        headerDivider.isHidden = !isCode
        copyButton.isHidden = !isCode
        if isCode {
            let label = block.language?.isEmpty == false
                ? block.language ?? "code"
                : "code"
            languageLabel.stringValue = label
            languageLabel.font = style.codeLabelFont
            languageLabel.textColor = style.secondaryLabel.nsColor
            applyLanguageFindMarks(
                findRanges,
                blockRange: block.sourceRange,
                sourceText: sourceText,
                label: label,
                style: style
            )
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
            leading.constant = messageRole == .assistant
                ? BlockRenderStyle.assistantTextLeading
                : 20
            trailing.constant = -max(20, bounds.width - leading.constant - outer)
        }
    }
    /// The row's background, border, and corner treatment.
    ///
    /// Role alone decides it: a user block fills a bubble because it is a user
    /// block, never because Find is active, because a row is selected, or
    /// because the pointer is over it. Find never paints a row-level surface,
    /// since a match belongs only to its text range.
    ///
    /// The bubble fill is an opaque colour on the layer rather than a material,
    /// which is also how it satisfies Reduce Transparency: there is no
    /// vibrancy behind bubble text to reduce. It is applied here at draw time,
    /// so a palette change repaints it without reshaping; the bubble's *text*
    /// colour is baked into prepared runs and is invalidated through
    /// `appearanceSignature`.
    private func applySurface(
        role: Role,
        isCode: Bool,
        isFirstInMessage: Bool,
        isLastInMessage: Bool,
        style: BlockRenderStyle
    ) {
        if isCode {
            // Same upward-y layer space the bubble path is mirrored into, so a
            // card's first row caps its top rather than its bottom.
            var corners: CACornerMask = []
            if isFirstInMessage { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
            if isLastInMessage { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
            surface.bubble = nil
            surface.layer?.backgroundColor = style.codeBackground.cgColor
            surface.layer?.cornerRadius = AppShapeScale.compact
            surface.layer?.maskedCorners = corners
            surface.layer?.borderWidth = BlockRenderStyle.codeBorderWidth
            surface.layer?.borderColor = style.codeBorder.cgColor
            return
        }
        surface.layer?.backgroundColor = NSColor.clear.cgColor
        surface.layer?.cornerRadius = 0
        surface.layer?.borderWidth = 0
        surface.layer?.borderColor = NSColor.clear.cgColor
        surface.bubble = role == .user
            ? BlockBubbleShape(
                fill: style.userBubble,
                radius: AppShapeScale.toast,
                roundsTop: isFirstInMessage,
                roundsBottom: isLastInMessage,
                hasTail: isLastInMessage
            )
            : nil
    }
    private func applyLanguageFindMarks(
        _ findRanges: [Range<Int>],
        blockRange: Range<Int>,
        sourceText: String,
        label: String,
        style: BlockRenderStyle
    ) {
        guard !findRanges.isEmpty else { return }
        let units = Array(sourceText.utf16)
        guard units.count >= 3,
              units[0] == 96, units[1] == 96, units[2] == 96
        else { return }
        let lineEnd = units.firstIndex(of: 10) ?? units.count
        var start = 3
        while start < lineEnd, units[start] == 32 || units[start] == 9 {
            start += 1
        }
        var end = lineEnd
        while end > start, units[end - 1] == 32 || units[end - 1] == 9 {
            end -= 1
        }
        guard start < end else { return }
        let languageRange = start..<end
        let languageSource = String(decoding: units[languageRange], as: UTF16.self)
        let localRanges = findRanges.compactMap { range -> Range<Int>? in
            let lower = max(range.lowerBound, blockRange.lowerBound + languageRange.lowerBound)
            let upper = min(range.upperBound, blockRange.lowerBound + languageRange.upperBound)
            guard lower < upper else { return nil }
            let localLower = lower - blockRange.lowerBound - start
            let localUpper = upper - blockRange.lowerBound - start
            return localLower..<localUpper
        }
        let projected = FindTextHighlighting.project(
            localRanges,
            from: languageSource,
            to: label
        )
        guard !projected.isEmpty else { return }
        let marked = NSMutableAttributedString(
            string: label,
            attributes: [
                .font: style.codeLabelFont,
                .foregroundColor: style.secondaryLabel.nsColor
            ]
        )
        for (offset, range) in projected.enumerated() {
            guard range.lowerBound >= 0,
                  range.upperBound <= marked.length
            else { continue }
            let nsRange = NSRange(
                location: range.lowerBound,
                length: range.upperBound - range.lowerBound
            )
            let matchColor = (offset == 0 ? style.findActiveMatch : style.findMatch).nsColor
            marked.addAttribute(
                .foregroundColor,
                value: matchColor,
                range: nsRange
            )
            marked.addAttribute(
                .backgroundColor,
                value: matchColor.withAlphaComponent(offset == 0 ? 0.25 : 0.16),
                range: nsRange
            )
            marked.addAttribute(
                .font,
                value: NSFontManager.shared.convert(
                    style.codeLabelFont,
                    toHaveTrait: .boldFontMask
                ),
                range: nsRange
            )
        }
        languageLabel.attributedStringValue = marked
    }

    /// Mark Find hits with the resolved accent, and bold only the matched text.
    /// Source ranges are projected onto the displayed block text because
    /// Markdown markers and list markers are not part of the drawn string.
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
            let matchColor = (offset == 0 ? style.findActiveMatch : style.findMatch).nsColor
            storage.addAttribute(
                .foregroundColor,
                value: matchColor,
                range: marked
            )
            storage.addAttribute(
                .backgroundColor,
                value: matchColor.withAlphaComponent(offset == 0 ? 0.25 : 0.16),
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

/// The app mark an assistant row shows in its reserved gutter.
///
/// It defers to `HermternalMark`, so the AppKit transcript and the SwiftUI
/// surfaces draw one asset from one decode. There is deliberately no generic
/// symbol fallback: a stand-in glyph would misrepresent the product, so a
/// missing resource draws nothing and is logged by the shared loader.
@MainActor
private enum BlockAssistantMark {
    static func image(isDark: Bool) -> NSImage? {
        HermternalMark.image(for: isDark ? .dark : .light)
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
    /// Called after layoutTableDocument so a publication deferred before
    /// SwiftUI geometry exists can be applied on the first usable layout.
    var onLayout: (() -> Void)?
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
        // NSTableView asks for row heights synchronously from
        // `noteHeightOfRows`. Set the document width first, otherwise that
        // callback can build a width-bucket key from the table's old
        // pre-layout one-point frame while preparation below uses the clip
        // view's real width. The measured result is then written under a
        // different bucket and every subsequent read misses.
        tableView.frame.size.width = width
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
        tableView.frame.size.height = max(1, tableView.fittingSize.height)
        onLayout?()
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
    private let sourceText: String
    private let sourceRange: Range<Int>

    init(sourceText: String, sourceRange: Range<Int>) {
        self.sourceText = sourceText
        self.sourceRange = sourceRange
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityLabel() -> String? {
        BlockText.slice(sourceText, range: sourceRange)
    }
}
