import AppKit
import HermternalCore
import Testing
@testable import Hermternal

/// The WCAG 2.1 contrast ratio between two relative luminances.
private func contrastRatio(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
    (max(first, second) + 0.05) / (min(first, second) + 0.05)
}

/// The WCAG 2.1 relative luminance of a colour an appearance has resolved.
///
/// `usingColorSpace` is the total conversion. Reading a component off an
/// unresolved catalog colour raises instead of returning a number, so the test
/// must not do what the production bug did.
private func relativeLuminance(of color: NSColor) throws -> CGFloat {
    let srgb = try #require(color.usingColorSpace(.sRGB))
    return OutgoingForegroundPolicy.relativeLuminance(
        red: srgb.redComponent,
        green: srgb.greenComponent,
        blue: srgb.blueComponent
    )
}

@Test("outgoing fill is the live system accent")
@MainActor
func outgoingFillIsLiveSystemAccent() {
    // The app's stored accent override is deliberately not read. The bubble
    // states what macOS is set to.
    #expect(OutgoingBubblePalette.fill.isEqual(NSColor.controlAccentColor))
}

@Test("outgoing foreground clears 4.5 to 1 on every possible accent")
func outgoingForegroundClearsContrastOnEveryAccent() {
    #expect(OutgoingForegroundPolicy.relativeLuminance(red: 0, green: 0, blue: 0) == 0)
    #expect(
        abs(OutgoingForegroundPolicy.relativeLuminance(red: 1, green: 1, blue: 1) - 1)
            < 0.0001
    )

    // Black and white read equally well at the crossover, and both clear the
    // 4.5:1 body-text criterion there. Every other fill is easier.
    let crossover = OutgoingForegroundPolicy.crossoverLuminance
    #expect(abs(contrastRatio(1, crossover) - contrastRatio(0, crossover)) < 0.001)
    #expect(contrastRatio(1, crossover) >= 4.5)

    for step in 0...20 {
        let component = CGFloat(step) / 20
        let luminance = OutgoingForegroundPolicy.relativeLuminance(
            red: component,
            green: component,
            blue: component
        )
        let prefersBlack = OutgoingForegroundPolicy.prefersBlackText(
            red: component,
            green: component,
            blue: component
        )
        #expect(contrastRatio(prefersBlack ? 0 : 1, luminance) >= 4.5)
    }
}

@Test("outgoing foreground selects black or white by luminance")
@MainActor
func outgoingForegroundSelectsBlackOrWhiteByLuminance() {
    #expect(OutgoingBubblePalette.foreground(on: NSColor.white).isEqual(NSColor.black))
    #expect(OutgoingBubblePalette.foreground(on: NSColor.black).isEqual(NSColor.white))

    // System blue is the macOS default accent and the future iOS default. Its
    // luminance sits above the crossover, so black is the higher-contrast text
    // and the policy must not fall back to a conventional white.
    let systemBlue = NSColor(srgbRed: 0, green: 122.0 / 255.0, blue: 1, alpha: 1)
    let luminance = OutgoingForegroundPolicy.relativeLuminance(
        red: 0,
        green: 122.0 / 255.0,
        blue: 1
    )
    #expect(luminance > OutgoingForegroundPolicy.crossoverLuminance)
    #expect(OutgoingBubblePalette.foreground(on: systemBlue).isEqual(NSColor.black))
}

@Test("outgoing bubble path reaches the tail tip and adds no height")
func outgoingBubblePathReachesTailTip() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 60)
    let body = OutgoingBubbleGeometry.bodyRect(in: rect)
    let path = OutgoingBubbleGeometry.path(in: rect)
    let box = path.boundingBoxOfPath

    #expect(body.width == rect.width - OutgoingBubbleGeometry.tailWidth)
    #expect(body.height == rect.height)
    #expect(OutgoingBubbleGeometry.tailWidth == 7)
    #expect(OutgoingBubbleGeometry.tailHeight == 14)
    #expect(AppShapeScale.outgoingBubbleTailCorner == 4)

    // The tail tip lands on the trailing edge, and the tail adds no height: the
    // path's bottom is the body's bottom.
    #expect(OutgoingBubbleGeometry.tailTip(in: rect) == CGPoint(x: rect.maxX, y: rect.minY))
    #expect(abs(box.minX - rect.minX) < 0.01)
    #expect(abs(box.maxX - rect.maxX) < 0.01)
    #expect(abs(box.minY - rect.minY) < 0.01)
    #expect(abs(box.maxY - rect.maxY) < 0.01)

    // The body fills.
    #expect(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
    // The tail fills past the body's trailing edge.
    #expect(path.contains(CGPoint(x: body.maxX + 1, y: rect.minY + 4)))
    // The junction fills. Two subpaths that ran opposite ways would cancel here
    // and cut a hole where the tail meets the body.
    #expect(path.contains(CGPoint(x: body.maxX - 2, y: rect.minY + 6)))
    // The tail narrows towards the tip, and nothing draws outside the rect.
    #expect(!path.contains(CGPoint(x: rect.maxX - 1, y: rect.minY + 10)))
    #expect(!path.contains(CGPoint(x: rect.maxX + 1, y: rect.minY + 1)))
}

@Test("a mirrored outgoing bubble carries its tail to the other side")
func mirroredOutgoingBubbleCarriesTailToOtherSide() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 60)
    let body = OutgoingBubbleGeometry.bodyRect(in: rect)
    let mirrored = OutgoingBubbleGeometry.path(in: rect, mirrored: true)
    let box = mirrored.boundingBoxOfPath

    #expect(
        OutgoingBubbleGeometry.tailTip(in: rect, mirrored: true)
            == CGPoint(x: rect.minX, y: rect.minY)
    )
    #expect(abs(box.minX - rect.minX) < 0.01)
    #expect(abs(box.maxX - rect.maxX) < 0.01)
    // The mirrored tail fills past the mirrored body's leading edge, and it
    // narrows towards its tip exactly as the unmirrored tail does.
    #expect(mirrored.contains(CGPoint(x: rect.width - body.maxX - 1, y: rect.minY + 4)))
    #expect(!mirrored.contains(CGPoint(x: rect.minX + 1, y: rect.minY + 10)))
    #expect(!mirrored.contains(CGPoint(x: rect.minX - 1, y: rect.minY + 1)))
}

@Test("a one-word outgoing message hugs its text")
@MainActor
func oneWordOutgoingMessageHugsItsText() {
    let turn = TranscriptTurn(id: "short", speaker: .me, answer: "ok")
    let document = MarkdownDocument.parse(turn.answer).document
    let width = TranscriptRendererTestSeam.effectiveWidth(for: turn, availableWidth: 1200)
    let layout = TranscriptRendererTestSeam.measuredLayout(
        for: turn,
        document: document,
        width: width
    )

    #expect(
        width == MessageTypography.outgoingTextMeasure(
            in: MessageTypography.readingMeasure
        )
    )
    #expect(layout.textWidth > 0)
    #expect(layout.textWidth < 60)
    // The agent floor reserves a role band, a disclosure band, and a metadata
    // band. An outgoing row shows none of them, so it must clear that floor.
    #expect(layout.height < MessageTypography.minimumTurnHeight)
}

@Test("a long outgoing message wraps inside the text cap")
@MainActor
func longOutgoingMessageWrapsInsideTextCap() {
    let answer = String(repeating: "wrapping outgoing message ", count: 40)
    let turn = TranscriptTurn(id: "long", speaker: .me, answer: answer)
    let document = MarkdownDocument.parse(answer).document
    let widest = MessageTypography.outgoingTextMeasure(
        in: MessageTypography.readingMeasure
    )

    // The bubble's box is the content column, not a share of it, and the text
    // is what is left inside the box: 490 less both 14pt paddings and the 7pt
    // tail. The 0.7 share this replaced capped the same text at 308pt, so the
    // user's own words wrapped 147pt earlier than the answer under them.
    #expect(widest == 455)
    #expect(
        widest
            + 2 * MessageTypography.outgoingBubblePaddingH
            + OutgoingBubbleGeometry.tailWidth
            == MessageTypography.readingMeasure
    )
    // A window wider than the readable measure widens the gutters, never the
    // bubble.
    #expect(
        TranscriptRendererTestSeam.effectiveWidth(for: turn, availableWidth: 4000)
            == widest
    )
    // A window narrower than the measure gives the bubble the column it has,
    // less its own box.
    let narrowColumn = MessageTypography.contentColumn(in: 300)
    #expect(narrowColumn == 300 - 2 * MessageTypography.transcriptInset)
    #expect(
        TranscriptRendererTestSeam.effectiveWidth(for: turn, availableWidth: 300)
            == narrowColumn
                - 2 * MessageTypography.outgoingBubblePaddingH
                - OutgoingBubbleGeometry.tailWidth
    )

    // A word-wrapped paragraph leaves a ragged right edge, so its widest line
    // need not reach the cap. The contract is that it never passes the cap.
    let wrapped = TranscriptRendererTestSeam.measuredLayout(
        for: turn,
        document: document,
        width: widest
    )
    #expect(wrapped.textWidth <= widest)
    #expect(wrapped.textWidth > widest / 2)
    #expect(wrapped.height > MessageTypography.outgoingMinimumTurnHeight)

    // One unbroken token has no break opportunity, so the typesetter fills each
    // line to within one character of the cap. This is what proves the cap is
    // the binding limit and not an accident of where the spaces fell.
    let token = String(repeating: "a", count: 400)
    let tokenTurn = TranscriptTurn(id: "token", speaker: .me, answer: token)
    let tokenLayout = TranscriptRendererTestSeam.measuredLayout(
        for: tokenTurn,
        document: MarkdownDocument.parse(token).document,
        width: widest
    )
    #expect(tokenLayout.textWidth <= widest)
    #expect(tokenLayout.textWidth > widest - 20)
}

@Test("both speakers share one text measure")
@MainActor
func bothSpeakersShareOneTextMeasure() {
    let text = String(repeating: "a turn that wraps. ", count: 10)
    let outgoing = TranscriptTurn(id: "me", speaker: .me, answer: text)
    let agent = TranscriptTurn(id: "agent", speaker: .hermes, answer: text)
    defer { MessageTypography.widthMode = .standard }

    // 2000pt is wider than the measure, 780pt is about the window's minimum
    // content width, 530pt is the narrowest window that still holds the whole
    // measure, and 300pt is narrower than it.
    for mode in TranscriptWidthMode.allCases {
        MessageTypography.widthMode = mode
        for available in [CGFloat(2000), 780, 530, 300] {
            let outgoingMeasure = TranscriptRendererTestSeam.effectiveWidth(
                for: outgoing,
                availableWidth: available
            )
            let agentMeasure = TranscriptRendererTestSeam.effectiveWidth(
                for: agent,
                availableWidth: available
            )
            // The bubble spends 35pt of the column on its box: two 14pt
            // paddings and the 7pt tail. The agent spends 36pt on the mark and
            // its gap. One point apart is one measure — neither speaker is
            // given a wider line than the other.
            #expect(abs(outgoingMeasure - agentMeasure) <= 1)
            #expect(outgoingMeasure > 0)
        }
    }
}

@Test("the full measure gives both speakers the window")
@MainActor
func theFullMeasureGivesBothSpeakersTheWindow() {
    let outgoing = TranscriptTurn(id: "me", speaker: .me, answer: "a turn")
    let agent = TranscriptTurn(id: "agent", speaker: .hermes, answer: "a turn")
    defer { MessageTypography.widthMode = .standard }

    MessageTypography.widthMode = .standard
    #expect(
        MessageTypography.contentColumn(in: 1200)
            == MessageTypography.readingMeasure
    )

    MessageTypography.widthMode = .full
    let column = MessageTypography.contentColumn(in: 1200)
    // The gutters are the one thing the full measure keeps, so no glyph ever
    // touches the window's edge.
    #expect(column == 1200 - 2 * MessageTypography.transcriptInset)
    #expect(
        TranscriptRendererTestSeam.effectiveWidth(for: agent, availableWidth: 1200)
            == column - MessageTypography.hermesIndent
    )
    #expect(
        TranscriptRendererTestSeam.effectiveWidth(for: outgoing, availableWidth: 1200)
            == MessageTypography.outgoingTextMeasure(in: column)
    )
    // A window narrower than the reading measure reads the same in both
    // measures: the column was already the window less its gutters.
    #expect(MessageTypography.contentColumn(in: 300) == 260)
    MessageTypography.widthMode = .standard
    #expect(MessageTypography.contentColumn(in: 300) == 260)
}

@Test("the outgoing row height is the constraint chain exactly")
func outgoingRowHeightIsTheConstraintChain() {
    let bands = 2 * MessageTypography.outgoingBubblePaddingV
        + MessageTypography.turnGap
        + MessageTypography.outgoingMeasurementSlack

    #expect(MessageTypography.outgoingBubblePaddingH == 14)
    #expect(MessageTypography.outgoingBubblePaddingV == 10)
    #expect(MessageTypography.outgoingMinimumTurnHeight == 62)
    #expect(bands == 45)
    #expect(
        TranscriptRendererTestSeam.outgoingRowHeight(textHeight: 200) - 200 == bands
    )
    #expect(
        TranscriptRendererTestSeam.outgoingRowHeight(textHeight: 0)
            == MessageTypography.outgoingMinimumTurnHeight
    )
    // A fractional text height rounds up once, never twice.
    #expect(TranscriptRendererTestSeam.outgoingRowHeight(textHeight: 100.2) == 146)

    // No role, disclosure, metadata, or copy band is measured.
    let agentBands = MessageTypography.roleLabelHeight
        + MessageTypography.metadataFooterHeight
        + MessageTypography.internalBlockGap
        + MessageTypography.turnGap
    #expect(bands < agentBands)
}

@Test("agent measurement keeps its bands and reports no fitting width")
@MainActor
func agentMeasurementKeepsItsBands() {
    let answer = String(repeating: "an assistant paragraph that wraps. ", count: 20)
    let document = MarkdownDocument.parse(answer).document
    let agent = TranscriptTurn(id: "agent", speaker: .hermes, answer: answer)

    #expect(
        TranscriptRendererTestSeam.effectiveWidth(for: agent, availableWidth: 780)
            == MessageTypography.readingMeasure - MessageTypography.hermesIndent
    )
    #expect(
        TranscriptRendererTestSeam.effectiveWidth(for: agent, availableWidth: 2000)
            == MessageTypography.readingMeasure - MessageTypography.hermesIndent
    )
    let system = TranscriptTurn(id: "system", speaker: .system, answer: answer)
    #expect(
        TranscriptRendererTestSeam.effectiveWidth(for: system, availableWidth: 500)
            == 460
    )

    // Both branches measure the rendered string in the body font. The agent
    // row still has bands an outgoing row does not: a disclosure, a metadata
    // footer, and the gaps between them. The band arithmetic is proved below
    // and at the same text height in `outgoingRowHeightIsTheConstraintChain`.
    let agentLayout = TranscriptRendererTestSeam.measuredLayout(
        for: agent,
        document: document,
        width: 340
    )

    // The agent branch has no use for a fitting width, so it reports the width
    // it measured against.
    #expect(agentLayout.textWidth == 340)
    #expect(agentLayout.height >= MessageTypography.minimumTurnHeight)

    // The agent band sum is unchanged. One collapsed reasoning channel adds
    // exactly one disclosure band and one internal gap, and nothing else: the
    // measured body text is identical because the disclosure is not expanded.
    let withReasoning = TranscriptTurn(
        id: "agent-reasoning",
        speaker: .hermes,
        reasoning: TranscriptReasoning(id: "reasoning", text: "collapsed detail"),
        answer: answer
    )
    let channelLayout = TranscriptRendererTestSeam.measuredLayout(
        for: withReasoning,
        document: document,
        width: 340
    )
    #expect(
        channelLayout.height - agentLayout.height
            == MessageTypography.disclosureHeight
                + MessageTypography.internalBlockGap
    )
}

/// The trailing edge of the content column inside a row of `rowWidth`.
///
/// The column is centred, so its trailing edge is the row's centre plus half
/// the column. This is where an agent answer ends, and where an outgoing
/// bubble's tail tip lands.
@MainActor
private func columnTrailing(in rowWidth: CGFloat) -> CGFloat {
    (rowWidth + MessageTypography.contentColumn(in: rowWidth)) / 2
}

@Test("an outgoing row trails the gutter and keeps the 12pt row bands")
@MainActor
func outgoingRowTrailsGutterAndKeepsRowBands() {
    _ = NSApplication.shared
    let rowWidth: CGFloat = 780
    let rowHeight: CGFloat = 140
    let root = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 400))
    let row = TranscriptTurnRowView(
        frame: NSRect(x: 0, y: 0, width: rowWidth, height: rowHeight)
    )
    root.addSubview(row)

    let agent = TranscriptTurn(
        id: "agent",
        speaker: .hermes,
        answer: "An assistant reply keeps the document measure it always had."
    )
    row.configure(
        turn: agent,
        document: nil,
        reasoningExpanded: false,
        toolsExpanded: false,
        showsMetadata: false,
        findQuery: "",
        onReasoning: { _ in },
        onTools: { _ in },
        onCopyCode: { _ in }
    )
    row.layoutSubtreeIfNeeded()

    #expect(row.bubbleForTesting.isHidden)
    #expect(
        abs(
            row.answerViewForTesting.bounds.width
                - TranscriptRendererTestSeam.effectiveWidth(
                    for: agent,
                    availableWidth: rowWidth
                )
        ) < 1
    )

    let outgoing = TranscriptTurn(id: "outgoing", speaker: .me, answer: "ok")
    let textWidth: CGFloat = 120
    row.configure(
        turn: outgoing,
        document: nil,
        reasoningExpanded: false,
        toolsExpanded: false,
        showsMetadata: false,
        findQuery: "",
        outgoingTextWidth: textWidth,
        onReasoning: { _ in },
        onTools: { _ in },
        onCopyCode: { _ in }
    )
    row.layoutSubtreeIfNeeded()

    #expect(!row.bubbleForTesting.isHidden)
    // The measured width holds, so the bubble hugs the text instead of filling
    // the row.
    #expect(abs(row.answerViewForTesting.bounds.width - textWidth) < 1)

    let bubble = row.bubbleForTesting.frame
    let band = MessageTypography.turnGap / 2
    // The tail tip, not the text, lands on the column's trailing edge, so the
    // bubble ends where an agent answer ends and never at the window's edge.
    #expect(abs(bubble.maxX - columnTrailing(in: rowWidth)) < 1)
    #expect(
        abs(
            bubble.width - (textWidth
                + 2 * MessageTypography.outgoingBubblePaddingH
                + OutgoingBubbleGeometry.tailWidth)
        ) < 1
    )
    // The 12pt row bands above and below are the agent row's bands.
    #expect(abs(bubble.minY - band) < 1)
    #expect(abs(bubble.maxY - (rowHeight - band)) < 1)
}

@Test("a tiny outgoing bubble hugs its text and still meets the gutter")
@MainActor
func tinyOutgoingBubbleHugsItsTextAndMeetsTheGutter() {
    _ = NSApplication.shared
    let rowWidth: CGFloat = 780

    // The hidden disclosure buttons keep required leading and trailing pins to
    // the stack, and their content hugging is `defaultHigh`. The measured width
    // equality must outrank them, or the stack collapses to a hidden button's
    // intrinsic width and every bubble comes out the same wrong size.
    for textWidth in [
        CGFloat(14), 30, 60, 120, MessageTypography.widestStandardOutgoingText
    ] {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 400))
        let row = TranscriptTurnRowView(
            frame: NSRect(x: 0, y: 0, width: rowWidth, height: 140)
        )
        root.addSubview(row)
        row.configure(
            turn: TranscriptTurn(id: "outgoing", speaker: .me, answer: "ok"),
            document: nil,
            reasoningExpanded: false,
            toolsExpanded: false,
            showsMetadata: false,
            findQuery: "",
            outgoingTextWidth: textWidth,
            onReasoning: { _ in },
            onTools: { _ in },
            onCopyCode: { _ in }
        )
        row.layoutSubtreeIfNeeded()

        #expect(abs(row.answerViewForTesting.bounds.width - textWidth) < 1)
        // Whatever the bubble's width, the tail tip lands on the column.
        #expect(
            abs(row.bubbleForTesting.frame.maxX - columnTrailing(in: rowWidth)) < 1
        )
    }
}

@Test("first layout of a short outgoing message hugs its text")
@MainActor
func firstLayoutOfAShortOutgoingMessageHugsItsText() {
    _ = NSApplication.shared
    defer { MessageTypography.widthMode = .standard }

    let short = TranscriptTurn(id: "short", speaker: .me, answer: "ok")
    let long = TranscriptTurn(
        id: "long",
        speaker: .me,
        answer: String(repeating: "wrapping outgoing message ", count: 40)
    )

    for mode in TranscriptWidthMode.allCases {
        MessageTypography.widthMode = mode
        for rowWidth in [CGFloat(780), 1_200] {
            for turn in [short, long] {
                let documents: [MarkdownDocument?] = [
                    MarkdownDocument.parse(turn.answer).document,
                    nil
                ]
                for document in documents {
                    let root = NSView(
                        frame: NSRect(x: 0, y: 0, width: rowWidth, height: 400)
                    )
                    let row = TranscriptTurnRowView(
                        frame: NSRect(x: 0, y: 0, width: rowWidth, height: 140)
                    )
                    root.addSubview(row)

                    let cap = TranscriptRendererTestSeam.effectiveWidth(
                        for: turn,
                        availableWidth: rowWidth
                    )
                    let hug = TranscriptRendererTestSeam.measuredLayout(
                        for: turn,
                        document: MarkdownDocument.parse(turn.answer).document,
                        width: cap
                    ).textWidth

                    // No measured width. This is first configure, before the
                    // async measurement pass lands.
                    row.configure(
                        turn: turn,
                        document: document,
                        reasoningExpanded: false,
                        toolsExpanded: false,
                        showsMetadata: false,
                        findQuery: "",
                        onReasoning: { _ in },
                        onTools: { _ in },
                        onCopyCode: { _ in }
                    )
                    row.layoutSubtreeIfNeeded()

                    let first = row.answerViewForTesting.bounds.width
                    #expect(abs(first - hug) < 1)
                    #expect(first <= cap + 0.5)
                    if turn.id == "short" {
                        #expect(first < 60)
                        #expect(first < cap - 100)
                    } else {
                        #expect(first > cap / 2)
                    }

                    // The later measurement pass must not change the width.
                    row.configure(
                        turn: turn,
                        document: document,
                        reasoningExpanded: false,
                        toolsExpanded: false,
                        showsMetadata: false,
                        findQuery: "",
                        outgoingTextWidth: hug,
                        onReasoning: { _ in },
                        onTools: { _ in },
                        onCopyCode: { _ in }
                    )
                    row.layoutSubtreeIfNeeded()
                    #expect(abs(row.answerViewForTesting.bounds.width - first) < 1)
                }
            }
        }
    }
}

@Test("a narrow window keeps the required transcript insets")
@MainActor
func narrowWindowKeepsRequiredTranscriptInsets() {
    _ = NSApplication.shared
    defer { MessageTypography.widthMode = .standard }

    // The measured equality is optional, so a window too narrow for it must
    // shrink the stack rather than break the required leading inset. 780pt is
    // about the window's minimum content width, 490pt is exactly the reading
    // measure, and the last two are narrower than it. Both measures are swept:
    // a required constraint that only holds in one of them is a layout the
    // solver would have to break.
    for mode in TranscriptWidthMode.allCases {
        MessageTypography.widthMode = mode
        for rowWidth in [CGFloat(780), 490, 300, 200] {
            let root = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 400))
            let row = TranscriptTurnRowView(
                frame: NSRect(x: 0, y: 0, width: rowWidth, height: 140)
            )
            root.addSubview(row)
            row.configure(
                turn: TranscriptTurn(id: "outgoing", speaker: .me, answer: "ok"),
                document: nil,
                reasoningExpanded: false,
                toolsExpanded: false,
                showsMetadata: false,
                findQuery: "",
                outgoingTextWidth: MessageTypography.widestStandardOutgoingText,
                onReasoning: { _ in },
                onTools: { _ in },
                onCopyCode: { _ in }
            )
            row.layoutSubtreeIfNeeded()

            let answer = row.answerViewForTesting.bounds.width
            // The column cap outranks the measured width, so the bubble is
            // never wider than the column it sits in, at any of these widths.
            #expect(
                answer <= MessageTypography.outgoingTextMeasure(
                    in: MessageTypography.contentColumn(in: rowWidth)
                ) + 0.5
            )
            #expect(
                row.bubbleForTesting.frame.minX
                    >= MessageTypography.transcriptInset
                        - MessageTypography.outgoingBubblePaddingH
                        - 0.5
            )
            // Nothing required was broken, so the row still spans the window
            // and the stack still stands inside both gutters.
            #expect(row.bounds.width == rowWidth)
            #expect(
                row.bubbleForTesting.frame.maxX
                    <= rowWidth - MessageTypography.transcriptInset
                        + MessageTypography.outgoingBubblePaddingH
                        + OutgoingBubbleGeometry.tailWidth
                        + 0.5
            )
        }
    }
}

@Test("the full measure widens the bubble's cap with the window")
@MainActor
func fullMeasureWidensTheBubbleCapWithTheWindow() {
    _ = NSApplication.shared
    let rowWidth: CGFloat = 1_200
    defer { MessageTypography.widthMode = .standard }

    // A measured width no window could justify, so the cap is the only thing
    // that can decide this bubble's width. In the standard measure the cap is
    // the reading column; in the full measure it is the window's own column,
    // and one constant switch is the whole difference.
    for mode in TranscriptWidthMode.allCases {
        MessageTypography.widthMode = mode
        let root = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 400))
        let row = TranscriptTurnRowView(
            frame: NSRect(x: 0, y: 0, width: rowWidth, height: 140)
        )
        root.addSubview(row)
        row.configure(
            turn: TranscriptTurn(id: "outgoing", speaker: .me, answer: "ok"),
            document: nil,
            reasoningExpanded: false,
            toolsExpanded: false,
            showsMetadata: false,
            findQuery: "",
            outgoingTextWidth: 10_000,
            onReasoning: { _ in },
            onTools: { _ in },
            onCopyCode: { _ in }
        )
        row.layoutSubtreeIfNeeded()

        let column = MessageTypography.contentColumn(in: rowWidth)
        #expect(
            abs(
                row.answerViewForTesting.bounds.width
                    - MessageTypography.outgoingTextMeasure(in: column)
            ) < 1
        )
        #expect(
            abs(row.bubbleForTesting.frame.maxX - columnTrailing(in: rowWidth)) < 1
        )
    }

    MessageTypography.widthMode = .full
    #expect(
        MessageTypography.contentColumn(in: rowWidth)
            > MessageTypography.readingMeasure
    )
}

@Test("row reuse clears every outgoing property")
@MainActor
func rowReuseClearsEveryOutgoingProperty() {
    _ = NSApplication.shared
    let rowWidth: CGFloat = 780
    // The row must sit in a superview. The column guide relates to the row's own
    // `widthAnchor`, and a view with no superview has no layout engine to
    // publish that width from its frame, so the solver would fall back to the
    // required `stack.width >= 1`.
    let root = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 400))
    let row = TranscriptTurnRowView(
        frame: NSRect(x: 0, y: 0, width: rowWidth, height: 140)
    )
    root.addSubview(row)
    let outgoing = TranscriptTurn(id: "outgoing", speaker: .me, answer: "ok")
    let agent = TranscriptTurn(id: "agent", speaker: .hermes, answer: "answer")

    row.configure(
        turn: outgoing,
        document: nil,
        reasoningExpanded: false,
        toolsExpanded: false,
        showsMetadata: false,
        findQuery: "",
        outgoingTextWidth: 120,
        onReasoning: { _ in },
        onTools: { _ in },
        onCopyCode: { _ in }
    )
    #expect(row.isOutgoingForTesting)
    #expect(!row.bubbleForTesting.isHidden)
    #expect(row.accessibilityLabel() == TranscriptSpeaker.me.label)

    row.configureLoading(showText: true)
    #expect(!row.isOutgoingForTesting)
    #expect(row.bubbleForTesting.isHidden)
    #expect(row.accessibilityLabel() == "Loading transcript row")

    row.configure(
        turn: agent,
        document: nil,
        reasoningExpanded: false,
        toolsExpanded: false,
        showsMetadata: false,
        findQuery: "",
        onReasoning: { _ in },
        onTools: { _ in },
        onCopyCode: { _ in }
    )
    row.layoutSubtreeIfNeeded()
    #expect(!row.isOutgoingForTesting)
    #expect(row.bubbleForTesting.isHidden)
    // A recycled row must not keep announcing "Loading transcript row".
    #expect(row.accessibilityLabel() == TranscriptSpeaker.hermes.label)
    // The full-row measure width is active again, so the agent row is back to
    // the document measure.
    #expect(
        abs(
            row.answerViewForTesting.bounds.width
                - TranscriptRendererTestSeam.effectiveWidth(
                    for: agent,
                    availableWidth: rowWidth
                )
        ) < 1
    )
}

@Test("the outgoing bubble takes no input and no accessibility stop")
@MainActor
func outgoingBubbleTakesNoInputAndNoAccessibilityStop() {
    _ = NSApplication.shared
    let bubble = OutgoingBubbleView(
        frame: NSRect(x: 0, y: 0, width: 160, height: 40)
    )

    #expect(bubble.hitTest(NSPoint(x: 80, y: 20)) == nil)
    #expect(!bubble.acceptsFirstResponder)
    #expect(!bubble.isAccessibilityElement())
    // The fill is a layer property, so `draw(_:)` is never asked for.
    #expect(bubble.wantsUpdateLayer)
    #expect(bubble.wantsLayer)
    #expect(bubble.makeBackingLayer() is CAShapeLayer)
}

/// A rendered answer that carries a link and a fenced code block.
private let bubbleRunFixture =
    "before [docs](https://example.com/path) after\n\n```swift\nlet value = 1\n```"

@MainActor
private func configuredRow(
    speaker: TranscriptSpeaker
) -> TranscriptTurnRowView {
    _ = NSApplication.shared
    let row = TranscriptTurnRowView(frame: NSRect(x: 0, y: 0, width: 780, height: 220))
    let turn = TranscriptTurn(id: "run-fixture", speaker: speaker, answer: bubbleRunFixture)
    row.configure(
        turn: turn,
        document: MarkdownDocument.parse(bubbleRunFixture).document,
        reasoningExpanded: false,
        toolsExpanded: false,
        showsMetadata: false,
        findQuery: "",
        outgoingTextWidth: 200,
        onReasoning: { _ in },
        onTools: { _ in },
        onCopyCode: { _ in }
    )
    return row
}

@MainActor
private func runAttributes(
    _ row: TranscriptTurnRowView,
    for needle: String
) throws -> [NSAttributedString.Key: Any] {
    let storage = try #require(row.answerViewForTesting.textStorage)
    let text = storage.string as NSString
    let range = text.range(of: needle)
    let location = try #require(range.location == NSNotFound ? nil : range.location)
    return storage.attributes(at: location, effectiveRange: nil)
}

@Test("every outgoing run carries one foreground and no code tint")
@MainActor
func everyOutgoingRunCarriesOneForegroundAndNoCodeTint() throws {
    let row = configuredRow(speaker: .me)
    let body = try #require(try runAttributes(row, for: "before")[.foregroundColor] as? NSColor)

    // The link inherits the row's colour. The default link colour is the accent,
    // which is the fill here.
    let link = try runAttributes(row, for: "docs")
    #expect(link[.link] != nil)
    #expect(try #require(link[.foregroundColor] as? NSColor).isEqual(body))

    // The code run keeps its monospaced typography and drops the 42%
    // window-background tint, which would dim the accent under the text.
    let code = try runAttributes(row, for: "let value = 1")
    #expect(try #require(code[.font] as? NSFont).fontName.localizedCaseInsensitiveContains("mono"))
    #expect(code[.backgroundColor] == nil)
    #expect(try #require(code[.foregroundColor] as? NSColor).isEqual(body))

    // No foreground in `linkTextAttributes`, so the stored uniform colour and a
    // black Find match stay authoritative.
    let linkAttributes = try #require(row.answerViewForTesting.linkTextAttributes)
    #expect(linkAttributes[.foregroundColor] == nil)
    #expect(linkAttributes[.underlineStyle] != nil)
}

@Test("agent rows keep the fenced code tint and the link colour")
@MainActor
func agentRowsKeepFencedCodeTintAndLinkColour() throws {
    let row = configuredRow(speaker: .hermes)

    let code = try runAttributes(row, for: "let value = 1")
    #expect(try #require(code[.font] as? NSFont).fontName.localizedCaseInsensitiveContains("mono"))
    #expect(code[.backgroundColor] != nil)

    let body = try #require(try runAttributes(row, for: "before")[.foregroundColor] as? NSColor)
    #expect(body.isEqual(NSColor.labelColor))

    let linkAttributes = try #require(row.answerViewForTesting.linkTextAttributes)
    #expect(linkAttributes[.foregroundColor] != nil)
}

@Test("one resolution gives the fill, the layer colour, and the foreground")
@MainActor
func oneResolutionGivesFillLayerColourAndForeground() throws {
    // The transcript showed a black bubble with black text in it. The layer and
    // the text each resolved the accent for themselves: the text's resolution
    // read blue and answered black, the layer's did not resolve at all and kept
    // `CAShapeLayer`'s black default. One value now carries both answers.
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = try #require(NSAppearance(named: name))
        let colors = OutgoingBubblePalette.colors(for: appearance)

        // The foreground is the answer for this fill, not for a second reading.
        #expect(
            colors.foreground.isEqual(OutgoingBubblePalette.foreground(on: colors.fill))
        )

        // The layer colour is a real RGB colour with four components, so handing
        // it to a layer property is a total conversion. A catalog colour's
        // `cgColor` is not defined at all.
        #expect(colors.layerFill.numberOfComponents == 4)
        #expect(colors.layerFill.alpha == 1)
        #expect(colors.layerFill.colorSpace?.model == .rgb)

        // The layer colour is the fill, component for component.
        let fill = try #require(colors.fill.usingColorSpace(.sRGB))
        let components = try #require(colors.layerFill.components)
        #expect(abs(components[0] - fill.redComponent) < 0.001)
        #expect(abs(components[1] - fill.greenComponent) < 0.001)
        #expect(abs(components[2] - fill.blueComponent) < 0.001)

        // The invariant the bug broke. Black on black is a ratio of 1.0, and no
        // resolved pair may come anywhere near it.
        let fillLuminance = try relativeLuminance(of: colors.fill)
        let textLuminance = try relativeLuminance(of: colors.foreground)
        #expect(contrastRatio(fillLuminance, textLuminance) >= 4.5)
    }
}

@Test("the bubble layer never carries the CAShapeLayer black default")
@MainActor
func bubbleLayerNeverCarriesShapeLayerBlackDefault() throws {
    _ = NSApplication.shared

    // The hazard, stated so the test explains itself: a shape layer that is
    // never told what to fill with fills opaque black.
    let untouched = try #require(CAShapeLayer().fillColor)
    #expect(untouched.alpha == 1)
    let defaults = try #require(untouched.components)
    let defaultIsBlack = defaults.allSatisfy { $0 == 0 || $0 == 1 }
    #expect(defaultIsBlack)

    // No display pass, no window, no layout. The fill is established in `init`,
    // so nothing has to run for the bubble to be honest.
    let bubble = OutgoingBubbleView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
    let shape = try #require(bubble.layer as? CAShapeLayer)
    let filled = try #require(shape.fillColor)
    let expected = OutgoingBubblePalette.colors(for: bubble.effectiveAppearance)
    let components = try #require(filled.components)
    let wanted = try #require(expected.layerFill.components)

    #expect(filled.numberOfComponents == expected.layerFill.numberOfComponents)
    #expect(components.count == wanted.count)
    let matchesResolved = zip(components, wanted).allSatisfy { abs($0.0 - $0.1) < 0.001 }
    #expect(matchesResolved)

    // A different colour reaches the layer. The probe is built in sRGB, so its
    // components are the four the layer reports back.
    let probe = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    bubble.apply(
        OutgoingBubbleColors(
            fill: probe,
            layerFill: probe.cgColor,
            foreground: NSColor.black
        )
    )
    let rewrittenFill = try #require(shape.fillColor)
    let rewritten = try #require(rewrittenFill.components)
    #expect(rewritten.count == 4)
    let isWhite = rewritten.prefix(3).allSatisfy { abs($0 - 1) < 0.001 }
    #expect(isWhite)
}

@Test("the outgoing row's text carries the bubble's own resolved foreground")
@MainActor
func outgoingRowTextCarriesBubbleResolvedForeground() throws {
    _ = NSApplication.shared
    let rowWidth: CGFloat = 780
    let root = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 400))
    let row = TranscriptTurnRowView(
        frame: NSRect(x: 0, y: 0, width: rowWidth, height: 140)
    )
    root.addSubview(row)
    row.configure(
        turn: TranscriptTurn(id: "outgoing", speaker: .me, answer: "a prompt"),
        document: nil,
        reasoningExpanded: false,
        toolsExpanded: false,
        showsMetadata: false,
        findQuery: "",
        outgoingTextWidth: 120,
        onReasoning: { _ in },
        onTools: { _ in },
        onCopyCode: { _ in }
    )
    row.layoutSubtreeIfNeeded()

    let colors = OutgoingBubblePalette.colors(for: row.effectiveAppearance)
    let storage = try #require(row.answerViewForTesting.textStorage)
    let text = try #require(
        storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    )
    #expect(text.isEqual(colors.foreground))

    // The same resolution reached the layer.
    let shape = try #require(row.bubbleForTesting.layer as? CAShapeLayer)
    let layerFill = try #require(shape.fillColor)
    let filled = try #require(layerFill.components)
    let wanted = try #require(colors.layerFill.components)
    #expect(filled.count == wanted.count)
    let matchesResolved = zip(filled, wanted).allSatisfy { abs($0.0 - $0.1) < 0.001 }
    #expect(matchesResolved)

    // And the pair still clears the body-text criterion on the real accent.
    let fillLuminance = try relativeLuminance(of: colors.fill)
    let textLuminance = try relativeLuminance(of: colors.foreground)
    #expect(contrastRatio(fillLuminance, textLuminance) >= 4.5)

    // A system colour change re-resolves both together, with no per-row
    // observer: the container walks the rows it has materialised.
    row.reloadOutgoingPalette()
    let reloaded = try #require(
        storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    )
    #expect(reloaded.isEqual(colors.foreground))
}

@Test("the outgoing text sits inside the bubble's padded band")
@MainActor
func outgoingTextSitsInsideBubblePaddedBand() throws {
    _ = NSApplication.shared
    let rowWidth: CGFloat = 780

    for textWidth in [
        CGFloat(30), 120, MessageTypography.widestStandardOutgoingText
    ] {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 400))
        let row = TranscriptTurnRowView(
            frame: NSRect(x: 0, y: 0, width: rowWidth, height: 140)
        )
        root.addSubview(row)
        row.configure(
            turn: TranscriptTurn(id: "outgoing", speaker: .me, answer: "a prompt"),
            document: nil,
            reasoningExpanded: false,
            toolsExpanded: false,
            showsMetadata: false,
            findQuery: "",
            outgoingTextWidth: textWidth,
            onReasoning: { _ in },
            onTools: { _ in },
            onCopyCode: { _ in }
        )
        row.layoutSubtreeIfNeeded()

        let answer = row.answerViewForTesting
        let text = answer.convert(answer.bounds, to: row)
        let bubble = row.bubbleForTesting.frame
        let padH = MessageTypography.outgoingBubblePaddingH
        let padV = MessageTypography.outgoingBubblePaddingV

        // No glyph reaches a bubble edge, and none enters the tail's width.
        #expect(text.minX >= bubble.minX + padH - 0.5)
        #expect(text.maxX <= bubble.maxX - padH - OutgoingBubbleGeometry.tailWidth + 0.5)
        #expect(text.minY >= bubble.minY + padV - 0.5)
        #expect(text.maxY <= bubble.maxY - padV + 0.5)
    }
}

@Test("the padded text band is filled in both layout directions")
func paddedTextBandIsFilledInBothLayoutDirections() {
    // The bubble at its widest: the text cap plus both paddings plus the tail,
    // which is the whole content column.
    let rect = CGRect(
        x: 0,
        y: 0,
        width: MessageTypography.readingMeasure,
        height: 60
    )
    let padH = MessageTypography.outgoingBubblePaddingH
    let padV = MessageTypography.outgoingBubblePaddingV
    let tail = OutgoingBubbleGeometry.tailWidth

    for mirrored in [false, true] {
        let path = OutgoingBubbleGeometry.path(in: rect, mirrored: mirrored)
        // Auto Layout puts the tail's width on the trailing edge, which is the
        // left edge in a right-to-left interface.
        let band = CGRect(
            x: mirrored ? tail + padH : padH,
            y: padV,
            width: rect.width - 2 * padH - tail,
            height: rect.height - 2 * padV
        )
        #expect(band.width == MessageTypography.widestStandardOutgoingText)

        // Every corner of the text band is inside the fill, so the body radius
        // never crosses a glyph in either direction.
        for corner in [
            CGPoint(x: band.minX, y: band.minY),
            CGPoint(x: band.maxX, y: band.minY),
            CGPoint(x: band.minX, y: band.maxY),
            CGPoint(x: band.maxX, y: band.maxY)
        ] {
            #expect(path.contains(corner))
        }
    }
}
