import HermternalCore
import Testing

@Test("reasoning header is absent until reasoning exists")
func reasoningHeaderPresence() {
    #expect(ReasoningDisclosurePolicy.header(isStreaming: true, hasReasoning: false, reduceMotion: false) == nil)
    let thinking = ReasoningDisclosurePolicy.header(isStreaming: true, hasReasoning: true, reduceMotion: false)
    #expect(thinking?.title == "Thinking")
    #expect(thinking?.isDisclosable == true)
    #expect(thinking?.isPulsing == true)
    #expect(thinking?.showsSpinner == false)

    let settled = ReasoningDisclosurePolicy.header(isStreaming: false, hasReasoning: true, reduceMotion: false)
    #expect(settled?.title == "Reasoning")
    #expect(settled?.isPulsing == false)
}

@Test("reduce motion replaces pulse with a spinner")
func reducedMotion() {
    let header = ReasoningDisclosurePolicy.header(isStreaming: true, hasReasoning: true, reduceMotion: true)
    #expect(header?.isPulsing == false)
    #expect(header?.showsSpinner == true)
    #expect(ReasoningPulse.isEnabled(reduceMotion: true, isStreaming: true) == false)
    #expect(ReasoningPulse.isEnabled(reduceMotion: false, isStreaming: false) == false)
}

@Test("reasoning rows appear only while expanded and hash ignores body growth")
func reasoningRowsAndStableHash() {
    #expect(ReasoningDisclosurePolicy.rows(state: .absent, reasoningBlockCount: 5) == 0)
    #expect(ReasoningDisclosurePolicy.rows(state: .collapsed, reasoningBlockCount: 5) == 0)
    #expect(ReasoningDisclosurePolicy.rows(state: .expanded, reasoningBlockCount: 5) == 5)
    #expect(ReasoningDisclosurePolicy.rows(state: .expanded, reasoningBlockCount: -1) == 0)

    let first = ReasoningHeaderProjection(title: "Thinking", isDisclosable: true, isPulsing: true, showsSpinner: false)
    let sameHeader = ReasoningHeaderProjection(title: "Thinking", isDisclosable: true, isPulsing: true, showsSpinner: false)
    #expect(first.contentHash == sameHeader.contentHash)
}

@Test("reasoning pulse is deterministic and bounded")
func pulseShape() {
    #expect(ReasoningPulse.opacity(atPhase: 0) == ReasoningPulse.maximumOpacity)
    #expect(ReasoningPulse.opacity(atPhase: 0.5) == ReasoningPulse.minimumOpacity)
    #expect(ReasoningPulse.opacity(atPhase: 1.5) == ReasoningPulse.minimumOpacity)
    #expect(ReasoningPulse.opacity(atPhase: 0.25) > ReasoningPulse.minimumOpacity)
    #expect(ReasoningPulse.opacity(atPhase: 0.25) < ReasoningPulse.maximumOpacity)
}
