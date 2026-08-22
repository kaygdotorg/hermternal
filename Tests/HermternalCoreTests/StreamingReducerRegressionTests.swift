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

private func event(_ type: String, text: String? = nil) -> GatewayEvent {
    GatewayEvent(
        type: type,
        sessionID: "session",
        payload: text.map { .object(["text": .string($0)]) }
    )
}
