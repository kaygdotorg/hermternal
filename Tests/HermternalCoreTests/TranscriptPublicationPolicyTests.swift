import HermternalCore
import Testing

@Test("initial publication bound selects a recent tail")
func initialPublicationTail() {
    let count = 100
    let start = max(0, count - TranscriptPublicationPolicy.initialMessageCount)
    #expect(start..<count == 88..<100)
    #expect(TranscriptPublicationPolicy.initialMessageCount == 12)
}

@Test("initial publication bound clamps for short transcripts")
func initialPublicationShortTranscript() {
    let count = 5
    let start = max(0, count - TranscriptPublicationPolicy.initialMessageCount)
    #expect(start..<count == 0..<5)
}
