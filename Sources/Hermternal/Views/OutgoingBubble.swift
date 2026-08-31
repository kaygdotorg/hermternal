import CoreGraphics
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// The outgoing chat bubble's outline.
///
/// Pure geometry. It names no colour, no view, and no UI framework, so the same
/// numbers describe the bubble on any platform that draws a `CGPath`.
///
/// Every length comes from an existing token:
///
/// | Part | Value | Reason |
/// |---|---|---|
/// | Body radius, three corners | `AppShapeScale.toast` (14) | The composer card directly below the transcript draws at this token. Two app-owned cards on one vertical axis must not disagree on radius. |
/// | Bottom-trailing radius | `AppShapeScale.outgoingBubbleTailCorner` (4) | The tail consumes that corner and its hook lands on the corner's tangency point, so the junction has no crease. |
/// | Tail width | `tailWidth` (7) | Half the body radius. A tail that out-reaches the curve it grows from reads as a triangle bolted on. |
/// | Tail height | `tailHeight` (14) | The body radius, so the tail's base spans exactly the corner it replaces. |
enum OutgoingBubbleGeometry {
    /// The tail's reach past the body's trailing edge.
    static let tailWidth: CGFloat = AppShapeScale.toast / 2

    /// The tail's rise above the body's bottom edge.
    static let tailHeight: CGFloat = AppShapeScale.toast

    /// The cubic approximation of a quarter arc, `4 / 3 * (sqrt(2) - 1)`.
    ///
    /// This is the constant `CGPath(roundedRect:)` uses. It makes the tail
    /// leave the trailing edge vertically and reach the tip horizontally, so
    /// both ends are tangent to the body and neither shows a crease.
    private static let arcConstant: CGFloat = 0.552284749830794

    /// The bubble body, which stops short of the trailing edge to leave the
    /// tail its own width.
    static func bodyRect(in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(0, rect.width - tailWidth),
            height: rect.height
        )
    }

    /// The point the tail ends at, which lands on the transcript gutter.
    static func tailTip(in rect: CGRect, mirrored: Bool = false) -> CGPoint {
        CGPoint(x: mirrored ? rect.minX : rect.maxX, y: rect.minY)
    }

    /// The bubble outline for `rect`, tail included.
    ///
    /// The coordinate space is the unflipped `NSView` space of the decoration:
    /// y grows upward, so the tail sits at `rect.minY`. Pass `mirrored` for a
    /// right-to-left interface, where the trailing edge is the left edge.
    static func path(in rect: CGRect, mirrored: Bool = false) -> CGPath {
        let body = bodyRect(in: rect)
        let bodyOutline = bodyPath(in: body)
        let outline = CGMutablePath()
        outline.addPath(bodyOutline)
        addTail(to: outline, body: body, clockwise: isClockwise(bodyOutline))
        guard mirrored else { return outline }
        // Auto Layout mirrors the bubble's frame for a right-to-left interface,
        // but a `CGPath` is not mirrored with it. One reflection about the
        // rect's vertical centre puts the tail back on the trailing edge.
        var reflection = CGAffineTransform(translationX: rect.midX * 2, y: 0)
            .scaledBy(x: -1, y: 1)
        return outline.copy(using: &reflection) ?? outline
    }

    /// The direction the body's outline runs in.
    ///
    /// The tail is a second subpath that overlaps the body's small corner. Under
    /// the nonzero fill rule two subpaths add up only when they run the same
    /// way. Opposite directions cancel and cut a hole exactly where the tail
    /// joins the body, so the tail follows whichever way the body runs instead
    /// of assuming one.
    ///
    /// The sign of the shoelace sum is all that is needed, so each curve
    /// contributes its endpoint alone. A polygon through the outline's endpoints
    /// runs the same way as the outline itself.
    private static func isClockwise(_ path: CGPath) -> Bool {
        var doubleArea: CGFloat = 0
        var start = CGPoint.zero
        var current = CGPoint.zero
        path.applyWithBlock { element in
            let points = element.pointee.points
            let next: CGPoint?
            switch element.pointee.type {
            case .moveToPoint:
                start = points[0]
                current = points[0]
                next = nil
            case .addLineToPoint:
                next = points[0]
            case .addQuadCurveToPoint:
                next = points[1]
            case .addCurveToPoint:
                next = points[2]
            case .closeSubpath:
                next = start
            @unknown default:
                next = nil
            }
            guard let next else { return }
            doubleArea += current.x * next.y - next.x * current.y
            current = next
        }
        return doubleArea < 0
    }

    /// The body's rounded rectangle, with three body corners and the small
    /// corner the tail grows out of.
    private static func bodyPath(in body: CGRect) -> CGPath {
        // `UnevenRoundedRectangle` names its corners in SwiftUI's coordinate
        // space, where y grows downward. This path is used in an unflipped
        // `NSView`, where y grows upward, so SwiftUI's top corners are this
        // view's bottom corners. The tail's small corner therefore goes in
        // `topTrailingRadius`.
        //
        // The style is `.continuous` because the composer card below the
        // transcript is a continuous `RoundedRectangle`. Circular arcs beside
        // it would visibly disagree. This is Apple's own squircle primitive,
        // so no curve math is hand-rolled here.
        UnevenRoundedRectangle(
            topLeadingRadius: AppShapeScale.toast,
            bottomLeadingRadius: AppShapeScale.toast,
            bottomTrailingRadius: AppShapeScale.toast,
            topTrailingRadius: AppShapeScale.outgoingBubbleTailCorner,
            style: .continuous
        ).path(in: body).cgPath
    }

    /// The tail, appended as a second subpath.
    ///
    /// macOS ships no message-tail control and no system style that draws a
    /// chat bubble, so this geometry is hand-rolled. The user approved the
    /// custom tail for this surface, and no system control is replaced: the
    /// bubble is a background behind an `NSTextView`, not a restyled control.
    /// `NSBezierPath` and `CGPath` are the documented primitives for an
    /// arbitrary closed curve, and both ends of the tail stay tangent to the
    /// body so the union reads as one boundary.
    ///
    /// Both endpoints and the outer control point share the body's bottom edge,
    /// so the tail adds no height. Row height is independent of it.
    private static func addTail(
        to outline: CGMutablePath,
        body: CGRect,
        clockwise: Bool
    ) {
        let trailing = body.maxX
        let bottom = body.minY
        let hook = AppShapeScale.outgoingBubbleTailCorner
        let curve = arcConstant

        // On the body's straight trailing edge, above the small corner. The
        // outer curve leaves here vertically, so the edge has no crease.
        let edge = CGPoint(x: trailing, y: bottom + tailHeight)
        // The tip, on the transcript gutter.
        let tip = CGPoint(x: trailing + tailWidth, y: bottom)
        // On the body's straight bottom edge, at the small corner's tangency
        // point, so the hook rejoins the bottom edge tangentially.
        let base = CGPoint(x: trailing - hook, y: bottom)
        // The outer curve's control points: the first shares `edge`'s x, so the
        // curve leaves vertically; the second shares `tip`'s y, so it arrives
        // horizontally.
        let outerNearEdge = CGPoint(x: trailing, y: bottom + tailHeight * (1 - curve))
        let outerNearTip = CGPoint(x: trailing + tailWidth * (1 - curve), y: bottom)
        // The hook's control points: the first is lifted by the corner radius,
        // the only other length in this corner, which is what makes the edge
        // concave. The second sits on the square corner the radius replaced.
        let hookNearTip = CGPoint(x: trailing + tailWidth * (1 - curve), y: bottom + hook)
        let hookNearBase = CGPoint(x: trailing, y: bottom)

        if clockwise {
            outline.move(to: edge)
            outline.addCurve(to: tip, control1: outerNearEdge, control2: outerNearTip)
            outline.addCurve(to: base, control1: hookNearTip, control2: hookNearBase)
        } else {
            outline.move(to: base)
            outline.addCurve(to: tip, control1: hookNearBase, control2: hookNearTip)
            outline.addCurve(to: edge, control1: outerNearTip, control2: outerNearEdge)
        }
        outline.closeSubpath()
    }
}

#if canImport(AppKit)
/// The outgoing bubble's fill, drawn behind the row's selectable text.
///
/// The view exists to keep scrolling free of drawing work:
///
/// - `draw(_:)` is never called. The layer is a `CAShapeLayer`, so the fill is
///   a layer property that the compositor rasterises.
/// - The path is built once per bounds size, not once per frame.
/// - The fill is one resolved `CGColor`, written only when it changes.
///
/// `CAShapeLayer.fillColor` defaults to opaque black, so an unwritten fill is
/// not blank: it is the one colour the foreground policy also reads as black
/// text, which is how the transcript came to show a black slab with black text
/// in it. The fill is therefore established in `init` and re-established from
/// `apply(_:)` and `updateLayer`, and never left to a display pass alone.
///
/// The view handles no input and carries no accessibility content. The text
/// view above it owns both.
///
/// Reduce Transparency needs no branch here. The bubble is one opaque fill with
/// no material and no vibrancy. Do not add one.
@MainActor
final class OutgoingBubbleView: NSView {
    private var pathSize: CGSize = .zero
    private var pathMirrored = false

    /// The fill the layer carries now.
    ///
    /// `CAShapeLayer.fillColor` cannot be read back as the `NSColor` it came
    /// from, and an unchanged value must not be rewritten: a write to a layer
    /// property is compositor traffic, and rows are recycled on every scroll
    /// step.
    private var appliedFill: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
        // Before any display pass, so the opaque black default is never seen.
        apply(OutgoingBubblePalette.colors(for: effectiveAppearance))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer { CAShapeLayer() }

    override var wantsUpdateLayer: Bool { true }

    /// Decoration only. The pointer must reach the text view above it, and a
    /// click on the bubble must start a selection in that text view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var acceptsFirstResponder: Bool { false }

    private var shape: CAShapeLayer? { layer as? CAShapeLayer }

    override func layout() {
        super.layout()
        updatePathIfNeeded()
    }

    /// Puts `colors`' fill on the layer.
    ///
    /// The row calls this with the same value it takes its text colour from, so
    /// the fill and the text can only ever state one accent. No display pass is
    /// needed: the fill is a layer property, not drawn content.
    func apply(_ colors: OutgoingBubbleColors) {
        guard let shape else { return }
        if let appliedFill, appliedFill.isEqual(colors.fill) { return }
        appliedFill = colors.fill
        shape.fillColor = colors.layerFill
    }

    override func updateLayer() {
        updatePathIfNeeded()
        // This view's appearance is the one the bubble is seen in.
        apply(OutgoingBubblePalette.colors(for: effectiveAppearance))
    }

    /// Rebuilds the path only when the size or the layout direction changed.
    private func updatePathIfNeeded() {
        let mirrored = userInterfaceLayoutDirection == .rightToLeft
        guard bounds.size != pathSize || mirrored != pathMirrored else { return }
        pathSize = bounds.size
        pathMirrored = mirrored
        shape?.path = OutgoingBubbleGeometry.path(in: bounds, mirrored: mirrored)
    }
}
#endif
