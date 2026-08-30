import Foundation
@testable import HermternalCore
import Testing


@Test("viewport promotion retains an existing anchor")
func viewportPromotionRetainsAnchor() {
    let anchor = MessageIdentity.server(ServerMessageID(rawValue: 8))
    #expect(TranscriptViewportPolicy.resolveTarget(
        isStreaming: false,
        isNearBottom: false,
        routeChanged: false,
        currentTarget: .message(id: anchor)
    ) == .message(id: anchor))
}

@Test("measured rows preserve the document anchor")
func measuredRowAnchorCorrection() {
    #expect(TranscriptViewportPolicy.preservedScrollOrigin(
        currentOrigin: 200,
        oldAnchorOrigin: 480,
        newAnchorOrigin: 512
    ) == 232)
    #expect(TranscriptViewportPolicy.preservedScrollOrigin(
        currentOrigin: 200,
        oldAnchorOrigin: 480,
        newAnchorOrigin: .infinity
    ) == 200)
}
@Test("reasoning disclosure avoids motion when requested")
func reasoningDisclosureReducedMotion() {
    let reduced = ReasoningDisclosurePolicy.header(
        isStreaming: true,
        hasReasoning: true,
        reduceMotion: true
    )
    #expect(reduced?.isPulsing == false)
    #expect(reduced?.showsSpinner == true)
    let still = ReasoningDisclosurePolicy.header(
        isStreaming: true,
        hasReasoning: true,
        reduceMotion: false
    )
    #expect(still?.isPulsing == true)
    #expect(still?.showsSpinner == false)
}

@Test("turn presentation keeps role labels and channel order")
func turnPresentationContract() {
    let turn = TranscriptTurn(
        id: "turn",
        speaker: .hermes,
        reasoning: TranscriptReasoning(id: "reasoning", text: "plan"),
        tools: [
            TranscriptToolRun(
                id: "tool",
                name: "Search",
                output: "result",
                state: .completed
            )
        ],
        answer: "answer"
    )
    #expect(turn.speaker.label == "Hermes")
    #expect(turn.channels == [.reasoning, .tools, .answer])
}

@Test("extended Markdown remains immutable and source-addressable")
func extendedMarkdownPresentationContract() {
    let result = MarkdownDocument.parse(
        "- [x] done\n\n| Name |\n| --- |\n| Hermes |\n\n[^note]: detail\n\n~~old~~"
    )
    #expect(result.isValid)
    #expect(result.document.blocks.contains {
        if case .taskList = $0 { return true }
        return false
    })
    #expect(result.document.blocks.contains {
        if case .table = $0 { return true }
        return false
    })
    #expect(result.document.blocks.contains {
        if case .footnote = $0 { return true }
        return false
    })
    #expect(result.document.source == MarkdownDocument.serialize(result.document))
}

@Test("turn pages expose contiguous turn ordinals and total count")
func contiguousTurnPageContract() {
    let page = TranscriptTurnPage(
        turns: [
            TranscriptTurn(id: "t64", speaker: .me, answer: "one"),
            TranscriptTurn(id: "t65", speaker: .hermes, answer: "two")
        ],
        startOrdinal: 64,
        nextOrdinal: 66,
        totalTurnCount: 100,
        hasMore: true
    )
    #expect(page.startOrdinal + page.turns.count == page.nextOrdinal)
    #expect(page.nextOrdinal <= page.totalTurnCount)
    #expect(page.hasMore)
}
