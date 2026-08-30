import AppKit
import HermternalCore
import Testing
@testable import Hermternal

@Test("renderer maps viewport inputs through the Core policy")
func rendererMapsViewportInputsThroughCorePolicy() {
    #expect(
        TranscriptRendererTestSeam.viewportTarget(
            pendingMessageID: "explicit-message",
            findMessageID: "find-message",
            isStreaming: true,
            isNearBottom: true,
            routeChanged: true,
            currentTarget: .message(id: "older-message")
        ) == .message(id: "explicit-message")
    )
    #expect(
        TranscriptRendererTestSeam.viewportTarget(
            pendingMessageID: nil,
            findMessageID: "find-message",
            isStreaming: true,
            isNearBottom: true,
            routeChanged: true,
            currentTarget: .message(id: "older-message")
        ) == .message(id: "find-message")
    )
    #expect(
        TranscriptRendererTestSeam.viewportTarget(
            pendingMessageID: nil,
            findMessageID: nil,
            isStreaming: true,
            isNearBottom: true,
            routeChanged: false,
            currentTarget: .message(id: "older-message")
        ) == .bottom
    )
    #expect(
        TranscriptRendererTestSeam.viewportTarget(
            pendingMessageID: nil,
            findMessageID: nil,
            isStreaming: true,
            isNearBottom: false,
            routeChanged: false,
            currentTarget: .message(id: "older-message")
        ) == .message(id: "older-message")
    )
}

@Test("renderer disclosure buttons send the configured turn identity")
@MainActor
func rendererDisclosureButtonsSendConfiguredTurnIdentity() throws {
    _ = NSApplication.shared
    let row = TranscriptTurnRowView(frame: .zero)
    let turn = TranscriptTurn(
        id: "turn-42",
        speaker: .hermes,
        reasoning: TranscriptReasoning(id: "reasoning-42", text: "reasoning"),
        tools: [TranscriptToolRun(id: "tool-42", name: "tool")],
        answer: "answer"
    )
    var reasoningID: String?
    var toolsID: String?
    row.configure(
        turn: turn,
        document: nil,
        reasoningExpanded: false,
        toolsExpanded: false,
        showsMetadata: false,
        findQuery: "",
        onReasoning: { reasoningID = $0 },
        onTools: { toolsID = $0 },
        onCopyCode: { _ in }
    )

    let reasoningButton = row.reasoningButtonForTesting
    let toolsButton = row.toolsButtonForTesting
    #expect(!reasoningButton.isHidden)
    #expect(!toolsButton.isHidden)

    let reasoningAction = try #require(reasoningButton.action)
    let toolsAction = try #require(toolsButton.action)
    #expect(NSApplication.shared.sendAction(
        reasoningAction,
        to: reasoningButton.target,
        from: reasoningButton
    ))
    #expect(NSApplication.shared.sendAction(
        toolsAction,
        to: toolsButton.target,
        from: toolsButton
    ))
    #expect(reasoningID == turn.id)
    #expect(toolsID == turn.id)
}

@Test("renderer preserves inline Markdown semantics as AppKit attributes")
func rendererPreservesInlineMarkdownSemantics() throws {
    let document = MarkdownDocument.parse(
        "**strong** *emphasis* ~~strike~~ `code` [link](https://example.com/path)"
    ).document
    let rendered = TranscriptRendererTestSeam.attributedAnswer(document)
    let source = rendered.string as NSString

    func attributes(for text: String) throws -> [NSAttributedString.Key: Any] {
        let range = source.range(of: text)
        let location = try #require(range.location == NSNotFound ? nil : range.location)
        return rendered.attributes(at: location, effectiveRange: nil)
    }

    let strongFont = try #require(try attributes(for: "strong")[.font] as? NSFont)
    #expect(NSFontManager.shared.traits(of: strongFont).contains(.boldFontMask))
    let emphasisFont = try #require(try attributes(for: "emphasis")[.font] as? NSFont)
    #expect(NSFontManager.shared.traits(of: emphasisFont).contains(.italicFontMask))
    let strike = try #require(try attributes(for: "strike")[.strikethroughStyle] as? NSNumber)
    #expect(strike.intValue == NSUnderlineStyle.single.rawValue)
    let codeFont = try #require(try attributes(for: "code")[.font] as? NSFont)
    #expect(codeFont.fontName.localizedCaseInsensitiveContains("mono"))
    let link = try #require(try attributes(for: "link")[.link] as? URL)
    #expect(link == URL(string: "https://example.com/path"))
}

@Test("renderer ignores a completed locate for a stale viewport target")
func rendererIgnoresStaleLocatedMessage() {
    #expect(!TranscriptRendererTestSeam.acceptsLocatedMessage(
        "previous-find-message",
        currentTarget: .message(id: "next-find-message")
    ))
    #expect(TranscriptRendererTestSeam.acceptsLocatedMessage(
        "active-find-message",
        currentTarget: .message(id: "active-find-message")
    ))
}

@Test("renderer consumes a pending target before Find takes control")
func rendererConsumesPendingTargetBeforeFindTakesControl() {
    let pending = TranscriptRendererTestSeam.activePendingMessageID(
        pendingMessageID: "pending-message",
        consumedPendingMessageID: nil
    )
    #expect(pending == "pending-message")
    #expect(
        TranscriptRendererTestSeam.activePendingMessageID(
            pendingMessageID: "pending-message",
            consumedPendingMessageID: "pending-message"
        ) == nil
    )
    #expect(
        TranscriptRendererTestSeam.viewportTarget(
            pendingMessageID: nil,
            findMessageID: "find-message",
            isStreaming: false,
            isNearBottom: false,
            routeChanged: false,
            currentTarget: .message(id: "pending-message")
        ) == .message(id: "find-message")
    )
}

@Test("renderer preserves quote and footnote block attributes")
func rendererPreservesQuoteAndFootnoteBlockAttributes() throws {
    let rendered = TranscriptRendererTestSeam.attributedAnswer(
        MarkdownDocument.parse("> quoted\n\n[^note]: footnote").document
    )
    let source = rendered.string as NSString

    func attributes(for text: String) throws -> [NSAttributedString.Key: Any] {
        let range = source.range(of: text)
        let location = try #require(range.location == NSNotFound ? nil : range.location)
        return rendered.attributes(at: location, effectiveRange: nil)
    }

    let quote = try attributes(for: "quoted")
    let quoteColor = try #require(quote[.foregroundColor] as? NSColor)
    #expect(quoteColor.isEqual(NSColor.secondaryLabelColor))
    let quoteParagraph = try #require(quote[.paragraphStyle] as? NSParagraphStyle)
    #expect(quoteParagraph.headIndent == 10)
    #expect(quoteParagraph.firstLineHeadIndent == 10)
    let footnoteFont = try #require(try attributes(for: "footnote")[.font] as? NSFont)
    #expect(footnoteFont.pointSize == NSFont.preferredFont(forTextStyle: .footnote).pointSize)
}
