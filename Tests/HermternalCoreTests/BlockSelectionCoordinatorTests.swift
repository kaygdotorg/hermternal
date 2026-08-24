import Foundation
@testable import HermternalCore
import Testing

private func blockMessage(_ id: String, _ text: String) -> [TranscriptBlock] {
    TranscriptBlockSegmenter.blocks(for: id, text: text)
}

private func position(
    _ messageID: String,
    _ blockIndex: Int,
    _ offset: Int
) -> BlockTextPosition {
    BlockTextPosition(messageID: messageID, blockIndex: blockIndex, utf16Offset: offset)
}

@Test("selection direction is normalised and offsets clamp to block bounds")
func blockSelectionDirectionAndClamping() {
    let text = "abcdef"
    let blocks = blockMessage("message", text)
    let coordinator = BlockSelectionCoordinator()
    coordinator.begin(at: position("message", 0, 99))
    coordinator.extend(to: position("message", 0, 2))

    #expect(coordinator.selectedRange?.start == position("message", 0, 2))
    #expect(coordinator.selectedRange?.end == position("message", 0, 99))
    #expect(coordinator.plainText(
        for: coordinator.selectedRange!,
        blocks: blocks,
        messageText: { _ in text }
    ) == "cdef")
}

@Test("single block selection returns the requested source span")
func blockSelectionSingleBlock() {
    let text = "alpha beta"
    let blocks = blockMessage("message", text)
    let range = BlockSelectionRange(
        start: position("message", 0, 0),
        end: position("message", 0, 5)
    )
    let coordinator = BlockSelectionCoordinator()

    #expect(coordinator.plainText(for: range, blocks: blocks, messageText: { _ in text }) == "alpha")
    #expect(coordinator.markdownSource(for: range, blocks: blocks, messageText: { _ in text }) == "alpha")
}

@Test("fragment continuation joins without an inserted separator")
func blockSelectionAcrossFragments() {
    let text = "first fragment\nsecond fragment"
    let blocks = [
        TranscriptBlock(
            messageID: "message",
            blockIndex: 0,
            kind: .paragraph,
            sourceRange: 0..<15,
            contentHash: 1
        ),
        TranscriptBlock(
            messageID: "message",
            blockIndex: 1,
            kind: .fragmentContinuation,
            sourceRange: 15..<text.utf16.count,
            contentHash: 2,
            continuationOf: 0
        )
    ]
    let range = BlockSelectionRange(
        start: position("message", 0, 6),
        end: position("message", 1, text.utf16.count - 15)
    )
    let coordinator = BlockSelectionCoordinator()

    #expect(coordinator.plainText(for: range, blocks: blocks, messageText: { _ in text })
        == "fragment\nsecond fragment")
    #expect(coordinator.markdownSource(for: range, blocks: blocks, messageText: { _ in text })
        == "fragment\nsecond fragment")
}

@Test("selection spanning messages joins each original message span")
func blockSelectionAcrossMessages() {
    let first = "first message"
    let second = "second message"
    let blocks = blockMessage("first", first) + blockMessage("second", second)
    let range = BlockSelectionRange(
        start: position("first", 0, 6),
        end: position("second", 0, 6)
    )
    let coordinator = BlockSelectionCoordinator()

    #expect(coordinator.plainText(
        for: range,
        blocks: blocks,
        messageText: { id in id == "first" ? first : second }
    ) == "message\n\nsecond")
    #expect(coordinator.markdownSource(
        for: range,
        blocks: blocks,
        messageText: { id in id == "first" ? first : second }
    ) == "message\n\nsecond")
}

@Test("mixed prose code and list use reader text and preserve Markdown source")
func blockSelectionMixedPlainAndMarkdown() {
    let text = "Intro\n\n```swift\nlet value = 1\n```\n\n- item"
    let blocks = blockMessage("message", text)
    let range = BlockSelectionRange(
        start: position("message", 0, 0),
        end: position("message", blocks[2].blockIndex, blocks[2].sourceRange.count)
    )
    let coordinator = BlockSelectionCoordinator()

    #expect(coordinator.plainText(for: range, blocks: blocks, messageText: { _ in text })
        == "Intro\n\nlet value = 1\n\nitem")
    #expect(coordinator.markdownSource(for: range, blocks: blocks, messageText: { _ in text })
        == text)
}

@Test("consecutive prose blocks use one blank-line separator")
func blockSelectionConsecutiveProse() {
    let text = "first paragraph\n\nsecond paragraph"
    let blocks = blockMessage("message", text)
    let range = BlockSelectionRange(
        start: position("message", 0, 0),
        end: position("message", 1, blocks[1].sourceRange.count)
    )
    let coordinator = BlockSelectionCoordinator()

    #expect(coordinator.plainText(
        for: range,
        blocks: blocks,
        messageText: { _ in text }
    ) == "first paragraph\n\nsecond paragraph")
}

@Test("fenced code at either selection edge has no fence terminator")
func blockSelectionFenceAtSelectionEdges() {
    let firstCode = "```swift\nlet first = true\n```\n\nprose"
    let firstBlocks = blockMessage("first", firstCode)
    let firstRange = BlockSelectionRange(
        start: position("first", 0, 0),
        end: position("first", 1, firstBlocks[1].sourceRange.count)
    )

    let lastCode = "prose\n\n```\nlet last = true\n```"
    let lastBlocks = blockMessage("last", lastCode)
    let lastRange = BlockSelectionRange(
        start: position("last", 0, 0),
        end: position("last", 1, lastBlocks[1].sourceRange.count)
    )

    let onlyCode = "```\nlet only = true\n```"
    let onlyCodeBlocks = blockMessage("only", onlyCode)
    let onlyCodeRange = BlockSelectionRange(
        start: position("only", 0, 0),
        end: position("only", 0, onlyCodeBlocks[0].sourceRange.count)
    )
    let coordinator = BlockSelectionCoordinator()

    #expect(coordinator.plainText(
        for: onlyCodeRange,
        blocks: onlyCodeBlocks,
        messageText: { _ in onlyCode }
    ) == "let only = true")
    #expect(coordinator.plainText(
        for: firstRange,
        blocks: firstBlocks,
        messageText: { _ in firstCode }
    ) == "let first = true\n\nprose")
    #expect(coordinator.plainText(
        for: lastRange,
        blocks: lastBlocks,
        messageText: { _ in lastCode }
    ) == "prose\n\nlet last = true")
}

@Test("collapsed selection yields empty copy output")
func blockSelectionCollapsed() {
    let text = "collapsed"
    let blocks = blockMessage("message", text)
    let range = BlockSelectionRange(
        start: position("message", 0, 4),
        end: position("message", 0, 4)
    )
    let coordinator = BlockSelectionCoordinator()

    #expect(coordinator.plainText(for: range, blocks: blocks, messageText: { _ in text }) == "")
    #expect(coordinator.markdownSource(for: range, blocks: blocks, messageText: { _ in text }) == "")
}
