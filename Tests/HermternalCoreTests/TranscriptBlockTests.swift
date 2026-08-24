import Foundation
@testable import HermternalCore
import Testing

private func message(_ text: String, id: Int64 = 1, streaming: Bool = false) -> ChatMessage {
    ChatMessage(
        id: .server(ServerMessageID(rawValue: id)),
        role: .assistant,
        text: text,
        isStreaming: streaming
    )
}

private func sourceText(_ text: String, range: Range<Int>) -> String {
    let start = String.Index(utf16Offset: range.lowerBound, in: text)
    let end = String.Index(utf16Offset: range.upperBound, in: text)
    return String(decoding: text.utf16[start..<end], as: UTF16.self)
}

@Test("segments prose headings lists quotes and code")
func transcriptBlockKindsAndRanges() {
    let text = "# Heading\n\n- item\n\n> quoted\n\n```swift\nlet x = 1\n```\n\nbody"
    let blocks = TranscriptBlockSegmenter.blocks(for: message(text))

    #expect(blocks.map(\.kind) == [
        .heading, .list, .quote, .code, .paragraph
    ])
    #expect(blocks[0].sourceRange == 0..<9)
    #expect(blocks[3].language == "swift")
    #expect(sourceText(text, range: blocks[3].sourceRange)
        == "```swift\nlet x = 1\n```")
}

@Test("fenced code without a language has no language value")
func transcriptBlockCodeWithoutLanguage() {
    let blocks = TranscriptBlockSegmenter.blocks(for: message("```\ncode\n```"))
    #expect(blocks.count == 1)
    #expect(blocks[0].kind == .code)
    #expect(blocks[0].language == nil)
}

@Test("long paragraphs fragment at nearby line boundaries")
func transcriptBlockFragments() {
    let line = String(repeating: "x", count: 500)
    let text = Array(repeating: line, count: 50).joined(separator: "\n")
    let blocks = TranscriptBlockSegmenter.blocks(for: message(text))

    #expect(blocks.count > 1)
    #expect(blocks.first?.kind == .paragraph)
    #expect(blocks.dropFirst().allSatisfy { $0.kind == .fragmentContinuation })
    #expect(blocks.dropFirst().allSatisfy { $0.continuationOf == blocks[0].blockIndex })
    #expect(blocks.dropFirst().allSatisfy { $0.sourceRange.count <= 3_000 })
}

@Test("streaming append changes only the trailing block")
func transcriptBlockStreamingAppend() {
    let old = message("first paragraph\n\nsecond", streaming: true)
    let previous = TranscriptBlockSegmenter.blocks(for: old)
    let update = TranscriptBlockSegmenter.resegment(
        previous: previous,
        previousMessage: old,
        appendedText: " more"
    )

    #expect(update.unchangedPrefixCount == 1)
    #expect(update.changedBlocks.count == 1)
    #expect(update.blocks[0] == previous[0])
    #expect(update.blocks[1].contentHash != previous[1].contentHash)
}

@Test("an incomplete fence is promoted without changing the completed prefix")
func transcriptBlockStreamingFencePromotion() {
    let old = message("stable\n\nparagraph\n``", streaming: true)
    let previous = TranscriptBlockSegmenter.blocks(for: old)
    let update = TranscriptBlockSegmenter.resegment(
        previous: previous,
        previousMessage: old,
        appendedText: "`swift\nlet value = 1\n```"
    )

    #expect(update.unchangedPrefixCount == 1)
    #expect(update.blocks[0] == previous[0])
    #expect(update.changedBlocks.contains { $0.kind == .code })
}

@Test("block identity is stable across equivalent re-segmentation")
func transcriptBlockIdentityStability() {
    let text = "# Title\n\n- one\n\nbody"
    let first = TranscriptBlockSegmenter.blocks(for: message(text, id: 9))
    let second = TranscriptBlockSegmenter.blocks(for: message(text, id: 9))

    #expect(first.map(\.id) == second.map(\.id))
    #expect(first == second)
}

@Test("different content produces different block hashes")
func transcriptBlockContentHash() {
    let first = TranscriptBlockSegmenter.blocks(for: message("same"))[0]
    let second = TranscriptBlockSegmenter.blocks(for: message("changed"))[0]
    #expect(first.contentHash != second.contentHash)
}
