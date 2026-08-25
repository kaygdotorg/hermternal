import Foundation
import HermternalCore
import Testing

private func reasoningRow(
    id: Int64 = 1,
    reasoning: JSONValue? = nil,
    reasoningContent: JSONValue? = nil,
    codexMessageItems: JSONValue? = nil,
    codexReasoningItems: JSONValue? = nil
) -> JSONValue {
    var fields: [String: JSONValue] = [
        "id": .integer(id),
        "role": .string("assistant"),
        "content": .string("answer")
    ]
    if let reasoning { fields["reasoning"] = reasoning }
    if let reasoningContent { fields["reasoning_content"] = reasoningContent }
    if let codexMessageItems { fields["codex_message_items"] = codexMessageItems }
    if let codexReasoningItems { fields["codex_reasoning_items"] = codexReasoningItems }
    return .object(fields)
}

@Test("REST reasoning survives when only reasoning is present")
func restReasoningPresent() throws {
    let message = try #require(ChatMessage.projectREST(historyRows: [
        reasoningRow(reasoning: .string("private chain of thought"))
    ]).first)
    #expect(message.reasoning == "private chain of thought")
}

@Test("REST reasoning_content survives when reasoning is absent")
func restReasoningContentOnly() throws {
    let message = try #require(ChatMessage.projectREST(historyRows: [
        reasoningRow(reasoningContent: .string("content alias"))
    ]).first)
    #expect(message.reasoning == "content alias")
}

@Test("REST reasoning remains nil when both reasoning fields are absent")
func restReasoningAbsent() throws {
    let message = try #require(ChatMessage.projectREST(historyRows: [reasoningRow()]).first)
    #expect(message.reasoning == nil)
}

@Test("equal reasoning aliases are emitted once")
func equalReasoningAliases() throws {
    let value: JSONValue = .string("same reasoning")
    let message = try #require(ChatMessage.projectREST(historyRows: [
        reasoningRow(reasoning: value, reasoningContent: value)
    ]).first)
    #expect(message.reasoning == "same reasoning")
}

@Test("differing reasoning aliases retain both values")
func differingReasoningAliases() throws {
    let message = try #require(ChatMessage.projectREST(historyRows: [
        reasoningRow(
            reasoning: .string("first source"),
            reasoningContent: .string("second source")
        )
    ]).first)
    #expect(message.reasoning == "first source\n\nsecond source")
}

@Test("unparseable Codex JSON is retained without failing projection")
func unparseableCodexString() throws {
    let raw = "{not-json"
    let message = try #require(ChatMessage.projectREST(historyRows: [
        reasoningRow(codexMessageItems: .string(raw))
    ]).first)
    let payload = try #require(message.codexMessageItems)
    #expect(payload.rawValue == raw)
    #expect(payload.parsedValue == nil)
    #expect(!payload.isParseable)
}

@Test("encrypted Codex reasoning is present but not displayable")
func encryptedCodexReasoning() throws {
    let raw = #"[{"type":"compaction","encrypted_content":"[ENCRYPTED_REDACTED]","_issuer_kind":"codex_backend"}]"#
    let message = try #require(ChatMessage.projectREST(historyRows: [
        reasoningRow(codexReasoningItems: .string(raw))
    ]).first)
    let payload = try #require(message.codexReasoningItems)
    #expect(payload.rawValue == raw)
    #expect(payload.parsedValue != nil)
    #expect(message.codexReasoningAvailability == .presentButNotDisplayable)
}

@Test("valid Codex message items retain their parsed dynamic shape")
func validCodexMessageItems() throws {
    let raw = #"[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"answer"}]}]"#
    let message = try #require(ChatMessage.projectREST(historyRows: [
        reasoningRow(codexMessageItems: .string(raw))
    ]).first)
    let payload = try #require(message.codexMessageItems)
    #expect(payload.isParseable)
    #expect(payload.parsedValue?.arrayValue?.isEmpty == false)
}

@Test("transient reasoning and readable Codex message items survive cache encoding")
func transientReasoningIsPersisted() throws {
    let message = ChatMessage(
        id: .server(ServerMessageID(rawValue: 7)),
        role: .assistant,
        text: "answer",
        reasoning: "private",
        codexMessageItems: CodexSerializedPayload(rawValue: "[]", parsedValue: .array([]))
    )
    let data = try JSONEncoder().encode(message)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["reasoning"] as? String == "private")
    #expect(object["codexReasoningItems"] == nil)
    #expect(object["codexMessageItems"] != nil)
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
    #expect(decoded.reasoning == "private")
    #expect(decoded.codexReasoningItems == nil)
    #expect(decoded.codexMessageItems?.rawValue == "[]")
}

@Test("encrypted reasoning availability survives without persisting opaque payload")
func encryptedReasoningAvailabilityRoundTrip() throws {
    let raw = #"[{"type":"compaction","encrypted_content":"[ENCRYPTED_REDACTED]"}]"#
    let message = try #require(ChatMessage.projectREST(historyRows: [
        reasoningRow(codexReasoningItems: .string(raw))
    ]).first)
    let data = try JSONEncoder().encode(message)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["codexReasoningItems"] == nil)
    #expect(object["codexReasoningAvailability"] as? String == "presentButNotDisplayable")
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
    #expect(decoded.codexReasoningAvailability == .presentButNotDisplayable)
}
