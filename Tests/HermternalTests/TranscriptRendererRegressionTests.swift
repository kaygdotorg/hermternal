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

@Test("renderer configures disclosure actions with the turn identity")
func rendererConfiguresDisclosureActionsWithTurnIdentity() {
    let turn = TranscriptTurn(id: "turn-42", speaker: .hermes, answer: "answer")
    #expect(TranscriptRendererTestSeam.configuredTurnID(for: turn) == "turn-42")
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
