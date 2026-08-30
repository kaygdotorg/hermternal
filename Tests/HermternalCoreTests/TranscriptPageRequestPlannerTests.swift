import Testing
@testable import HermternalCore

@Test("viewport demand coalesces to aligned page starts")
func alignedPageStartsCoalesceOverlappingRows() {
    #expect(TranscriptPageRequestPlanner.alignedStarts(
        for: 0..<276,
        totalRows: 276
    ) == [0, 64, 128, 192, 256])
    #expect(TranscriptPageRequestPlanner.alignedStarts(
        for: 65..<66,
        totalRows: 276
    ) == [64])
    #expect(TranscriptPageRequestPlanner.alignedStarts(
        for: 276..<400,
        totalRows: 276
    ).isEmpty)
}
