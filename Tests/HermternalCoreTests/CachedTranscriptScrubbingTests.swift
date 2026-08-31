import Foundation
@testable import HermternalCore
import Testing

@Test("Scrubbing drops empty streaming placeholders")
func cachedTranscriptScrubbingDropsEmptyStreamingRows() {
    let messages = [
        ChatMessage(id: .server(ServerMessageID(rawValue: 1)), role: .user, text: "Hello"),
        ChatMessage(
            id: .provisional(UUID()),
            role: .assistant,
            text: "",
            isStreaming: true
        )
    ]

    let scrubbed = CachedTranscriptScrubbing.scrub(messages)

    #expect(scrubbed.map(\.text) == ["Hello"])
    #expect(CachedTranscriptScrubbing.needsScrub(messages))
    #expect(!CachedTranscriptScrubbing.needsScrub(scrubbed))
}

@Test("Scrubbing keeps finished text and clears the streaming flag")
func cachedTranscriptScrubbingClearsStreamingFlag() {
    let messages = [
        ChatMessage(
            id: .server(ServerMessageID(rawValue: 2)),
            role: .assistant,
            text: "Partial answer",
            isStreaming: true
        )
    ]

    let scrubbed = CachedTranscriptScrubbing.scrub(messages)

    #expect(scrubbed.count == 1)
    #expect(scrubbed[0].text == "Partial answer")
    #expect(!scrubbed[0].isStreaming)
}
