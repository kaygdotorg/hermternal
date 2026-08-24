import Foundation
@testable import HermternalCore
import Testing

private func layoutKey(
    contentHash: UInt64 = 1,
    widthBucket: Int = 70,
    fontSignature: String = "body-17",
    displayScaleBits: UInt64 = 0x3ff0000000000000,
    appearanceMode: String = "light",
    localeIdentifier: String = "en_US",
    rendererVersion: Int = 1
) -> BlockLayoutKey {
    BlockLayoutKey(
        contentHash: contentHash,
        widthBucket: widthBucket,
        fontSignature: fontSignature,
        displayScaleBits: displayScaleBits,
        appearanceMode: appearanceMode,
        localeIdentifier: localeIdentifier,
        rendererVersion: rendererVersion
    )
}

@Test("block layout key includes every rendering input")
func blockLayoutKeyInvalidatesEveryField() {
    let base = layoutKey()
    #expect(base != layoutKey(contentHash: 2))
    #expect(base != layoutKey(widthBucket: 71))
    #expect(base != layoutKey(fontSignature: "body-18"))
    #expect(base != layoutKey(displayScaleBits: 0x4000000000000000))
    #expect(base != layoutKey(appearanceMode: "dark"))
    #expect(base != layoutKey(localeIdentifier: "fr_FR"))
    #expect(base != layoutKey(rendererVersion: 2))
}

@Test("width bucketing reuses neighbouring widths and separates distant widths")
func blockLayoutWidthBucketing() {
    #expect(BlockLayoutKey.widthBucket(for: 556) == BlockLayoutKey.widthBucket(for: 559))
    #expect(BlockLayoutKey.widthBucket(for: 556) != BlockLayoutKey.widthBucket(for: 600))

    let neighbouringA = BlockLayoutKey(
        contentHash: 1,
        width: 556,
        fontSignature: "body-17",
        displayScaleBits: 1,
        appearanceMode: "light",
        localeIdentifier: "en_US",
        rendererVersion: 1
    )
    let neighbouringB = BlockLayoutKey(
        contentHash: 1,
        width: 559,
        fontSignature: "body-17",
        displayScaleBits: 1,
        appearanceMode: "light",
        localeIdentifier: "en_US",
        rendererVersion: 1
    )
    #expect(neighbouringA == neighbouringB)
    #expect(BlockLayoutKey.widthBucket(for: -10) == 0)
    #expect(BlockLayoutKey.widthBucket(for: .infinity) == 0)
}

@Test("layout cache hit skips preparation")
func blockLayoutCacheHitSkipsPreparation() throws {
    let cache = BlockLayoutCache(byteBudget: 1_024)
    let key = layoutKey()
    var preparationCount = 0

    let first = try cache.value(for: key) {
        preparationCount += 1
        return BlockLayoutValue(preparedContent: "prepared", measuredHeight: 42)
    }
    let second = try cache.value(for: key) {
        preparationCount += 1
        return BlockLayoutValue(preparedContent: "wrong", measuredHeight: 99)
    }

    #expect(preparationCount == 1)
    #expect(first == second)
    #expect(second.preparedContent == "prepared")
}

@Test("layout cache retains no more than its byte ceiling")
func blockLayoutCacheHonorsByteCeiling() {
    let cache = BlockLayoutCache(byteBudget: 1_024)
    for index in 0..<100 {
        let key = layoutKey(contentHash: UInt64(index + 1))
        cache.insert(
            BlockLayoutValue(
                preparedContent: String(repeating: "x", count: 100),
                measuredHeight: CGFloat(index)
            ),
            for: key
        )
    }

    #expect(cache.retainedByteCount <= cache.byteBudget)
}

@Test("height estimates are deterministic and monotonic in content length")
func blockHeightEstimatorIsDeterministicAndMonotonic() {
    let kinds: [TranscriptBlock.Kind] = [
        .paragraph,
        .heading,
        .list,
        .quote,
        .code,
        .fragmentContinuation
    ]

    for kind in kinds {
        let short = BlockHeightEstimator.estimatedHeight(
            for: kind,
            width: 556,
            contentLength: 10
        )
        let long = BlockHeightEstimator.estimatedHeight(
            for: kind,
            width: 556,
            contentLength: 1_000
        )
        let repeated = BlockHeightEstimator.estimatedHeight(
            for: kind,
            width: 556,
            contentLength: 1_000
        )
        #expect(long >= short)
        #expect(long == repeated)
    }
}
