import HermternalCore
import Testing

@Test("initial window selects the recent transcript tail")
func initialRecentWindow() {
    let window = TranscriptWindowPolicy.resolve(
        totalMessageCount: 100,
        requestedWindowSize: 40
    )

    #expect(window.range == 60..<100)
    #expect(window.hasMoreOlderMessages)
}

@Test("initial paint selects a bounded recent tail")
func initialPaintWindow() {
    let window = TranscriptWindowPolicy.initial(totalMessageCount: 100)

    #expect(window.range == 88..<100)
    #expect(window.hasMoreOlderMessages)
}

@Test("initial extension reaches the complete recent tail")
func initialWindowExtension() {
    let first = TranscriptWindowPolicy.initial(totalMessageCount: 100)
    let extended = TranscriptWindowPolicy.grow(
        totalMessageCount: 100,
        requestedWindowSize: TranscriptWindowPolicy.defaultWindowSize,
        currentState: first.state,
        growthBy: TranscriptWindowPolicy.extensionStep
    )

    #expect(TranscriptWindowPolicy.extensionStep == 28)
    #expect(extended.range == 60..<100)
    #expect(extended.range.upperBound == first.range.upperBound)
}

@Test("window growth prepends one bounded step and retains the tail")
func boundedWindowGrowth() {
    let first = TranscriptWindowPolicy.grow(
        totalMessageCount: 100,
        requestedWindowSize: 40,
        currentState: TranscriptWindowState(startIndex: 60, endIndex: 100)
    )
    let second = TranscriptWindowPolicy.grow(
        totalMessageCount: 100,
        requestedWindowSize: 40,
        currentState: first.state
    )

    #expect(first.range == 20..<100)
    #expect(first.hasMoreOlderMessages)
    #expect(second.range == 0..<100)
    #expect(!second.hasMoreOlderMessages)
}

@Test("growth clamps exactly at transcript start")
func growthClampsAtTranscriptStart() {
    let window = TranscriptWindowPolicy.grow(
        totalMessageCount: 55,
        requestedWindowSize: 40,
        currentState: TranscriptWindowState(startIndex: 15, endIndex: 55),
        growthBy: 40
    )

    #expect(window.range == 0..<55)
    #expect(!window.hasMoreOlderMessages)
}

@Test("including a target expands the rendered bounds without dropping rows")
func targetWindowCoverage() {
    let window = TranscriptWindowPolicy.including(
        targetIndex: 12,
        totalMessageCount: 100,
        requestedWindowSize: 40,
        currentState: TranscriptWindowState(startIndex: 60, endIndex: 100)
    )

    #expect(window.range == 12..<100)
    #expect(window.range.contains(12))
}

@Test("reset ignores the previous window and returns to the recent tail")
func windowResetSemantics() {
    let reset = TranscriptWindowPolicy.reset(
        totalMessageCount: 100,
        requestedWindowSize: 40
    )
    let resolved = TranscriptWindowPolicy.resolve(
        totalMessageCount: 100,
        requestedWindowSize: 40,
        currentState: TranscriptWindowState(startIndex: 0, endIndex: 100)
    )

    #expect(reset.range == 60..<100)
    #expect(resolved.range == 0..<100)
}
