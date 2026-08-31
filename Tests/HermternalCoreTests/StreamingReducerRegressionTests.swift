import Foundation
import HermternalCore
import Testing

@Test("empty complete after deltas preserves accumulated text and finishes")
func emptyCompleteAfterDeltasPreservesAccumulatedText() {
    var reducer = StreamingEventReducer()
    reducer.appendUser("question")
    _ = reducer.reduce(event("message.start"))
    _ = reducer.reduce(event("message.delta", text: "hel"))
    _ = reducer.reduce(event("message.delta", text: "lo"))

    let result = reducer.reduce(event("message.complete", text: ""))

    #expect(result.messages.map(\.text) == ["question", "hello"])
    #expect(!result.messages[1].isStreaming)
    #expect(!result.isAwaitingReply)
    #expect(result.terminal == .complete)
}

@Test("empty complete without a streaming row does not append an empty row")
func emptyCompleteWithoutStreamingRowDoesNotAppendEmptyRow() {
    var reducer = StreamingEventReducer()
    reducer.appendUser("question")

    let result = reducer.reduce(event("message.complete", text: ""))

    #expect(result.messages.map(\.text) == ["question"])
    #expect(!result.isAwaitingReply)
    #expect(result.terminal == .complete)
}

@Test("complete text replaces accumulated deltas")
func completeTextReplacesAccumulatedDeltas() {
    var reducer = StreamingEventReducer()
    reducer.appendUser("question")
    _ = reducer.reduce(event("message.start"))
    _ = reducer.reduce(event("message.delta", text: "partial"))

    let result = reducer.reduce(event("message.complete", text: "authoritative"))

    #expect(result.messages.map(\.text) == ["question", "authoritative"])
    #expect(!result.messages[1].isStreaming)
    #expect(!result.isAwaitingReply)
}

@Test("duplicate complete is idempotent")
func duplicateCompleteIsIdempotent() {
    var reducer = StreamingEventReducer()
    reducer.appendUser("question")
    _ = reducer.reduce(event("message.start"))
    _ = reducer.reduce(event("message.delta", text: "answer"))
    _ = reducer.reduce(event("message.complete", text: "answer"))

    let duplicate = reducer.reduce(event("message.complete", text: "answer"))

    #expect(duplicate.messages.map(\.text) == ["question", "answer"])
    #expect(duplicate.messages.count == 2)
    #expect(!duplicate.messages[1].isStreaming)
    #expect(!duplicate.isAwaitingReply)
    #expect(duplicate.terminal == .complete)
}

@Test("reasoning-only turn stays separate from answer text")
func reasoningOnlyTurnStaysSeparateFromAnswerText() {
    var reducer = StreamingEventReducer()
    _ = reducer.reduce(event("message.start"))
    _ = reducer.reduce(event("reasoning.delta", text: "inspect files"))
    _ = reducer.reduce(event("reasoning.available", text: "waiting for provider"))

    let result = reducer.reduce(event("message.complete"))

    #expect(result.messages.count == 1)
    #expect(result.messages[0].text.isEmpty)
    #expect(result.messages[0].reasoning == "inspect fileswaiting for provider")
    #expect(!result.messages[0].isStreaming)
}

@Test("answer-only turn leaves reasoning empty")
func answerOnlyTurnLeavesReasoningEmpty() {
    var reducer = StreamingEventReducer()
    _ = reducer.reduce(event("message.start"))
    _ = reducer.reduce(event("message.delta", text: "answer"))

    let result = reducer.reduce(event("message.complete", text: "answer"))

    #expect(result.messages[0].text == "answer")
    #expect(result.messages[0].reasoning == nil)
}

@Test("interleaved answer and reasoning deltas stay in separate fields")
func interleavedAnswerAndReasoningDeltasStaySeparate() {
    var reducer = StreamingEventReducer()
    _ = reducer.reduce(event("message.start"))
    _ = reducer.reduce(event("reasoning.delta", text: "first"))
    _ = reducer.reduce(event("message.delta", text: "hello"))
    _ = reducer.reduce(event("thinking.delta", text: "second"))
    _ = reducer.reduce(event("message.delta", text: " world"))

    let result = reducer.reduce(event("message.complete", text: "hello world"))

    #expect(result.messages[0].text == "hello world")
    #expect(result.messages[0].reasoning == "firstsecond")
}

@Test("complete reasoning agrees with streamed reasoning")
func completeReasoningAgreesWithStream() {
    var reducer = StreamingEventReducer()
    _ = reducer.reduce(event("message.start"))
    _ = reducer.reduce(event("reasoning.delta", text: "plan"))

    let result = reducer.reduce(event(
        "message.complete",
        text: "done",
        reasoning: "plan"
    ))

    #expect(result.messages[0].reasoning == "plan")
}

@Test("complete reasoning is authoritative when it disagrees")
func completeReasoningIsAuthoritativeWhenItDisagrees() {
    var reducer = StreamingEventReducer()
    _ = reducer.reduce(event("message.start"))
    _ = reducer.reduce(event("reasoning.delta", text: "partial"))

    let result = reducer.reduce(event(
        "message.complete",
        text: "done",
        reasoning: "final"
    ))

    #expect(result.messages[0].reasoning == "final")
}

@Test("unknown event retains its type and payload")
func unknownEventRetainsTypeAndPayload() {
    var reducer = StreamingEventReducer()
    let future = event("future.event", text: "opaque")

    #expect(future.kind == .unknown("future.event"))
    _ = reducer.reduce(future)

    #expect(reducer.unknownEventTypes == ["future.event"])
    #expect(future.payload?["text"]?.stringValue == "opaque")
}

private func event(
    _ type: String,
    text: String? = nil,
    reasoning: String? = nil
) -> GatewayEvent {
    var fields: [String: JSONValue] = [:]
    if let text { fields["text"] = .string(text) }
    if let reasoning { fields["reasoning"] = .string(reasoning) }
    return GatewayEvent(
        type: type,
        sessionID: "session",
        payload: fields.isEmpty ? nil : .object(fields)
    )
}

@Test("rollbackUser removes the unpublished user turn")
func rollbackUserRemovesUnpublishedUserTurn() {
    var reducer = StreamingEventReducer()
    reducer.appendUser("question")
    let result = reducer.rollbackUser()
    #expect(result.messages.isEmpty)
    #expect(!result.isAwaitingReply)
}
