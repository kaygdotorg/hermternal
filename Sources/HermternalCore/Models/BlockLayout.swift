import Foundation

/// The width granularity used by block layout keys.
///
/// The transcript reading measure is 556 points. An 8-point bucket gives about
/// 69 useful width steps across that measure without invalidating on every resize.
/// A bucket can reuse a measurement for a proposal up to four points away. The
/// visible block is measured again when it reaches the viewport, so that error
/// affects only the provisional off-screen geometry.
public struct BlockLayoutKey: Hashable, Sendable {
    /// Width bucket size in points.
    public static let widthBucketSize: CGFloat = 8
    /// Invalidating on content changes prevents stale text and wrapping.
    public let contentHash: UInt64
    /// Bucketing limits resize churn while bounding provisional wrap error.
    public let widthBucket: Int
    /// Font changes alter glyph widths, line breaks, and baseline metrics.
    public let fontSignature: String
    /// Backing scale changes raster metrics and can alter measured height.
    public let displayScaleBits: UInt64
    /// Appearance can alter colors, fallback fonts, and effective metrics.
    public let appearanceMode: String
    /// Locale changes line-break and shaping rules for the same text.
    public let localeIdentifier: String
    /// Renderer changes must not reuse measurements from an older algorithm.
    public let rendererVersion: Int

    public init(
        contentHash: UInt64,
        widthBucket: Int,
        fontSignature: String,
        displayScaleBits: UInt64,
        appearanceMode: String,
        localeIdentifier: String,
        rendererVersion: Int
    ) {
        self.contentHash = contentHash
        self.widthBucket = widthBucket
        self.fontSignature = fontSignature
        self.displayScaleBits = displayScaleBits
        self.appearanceMode = appearanceMode
        self.localeIdentifier = localeIdentifier
        self.rendererVersion = rendererVersion
    }

    /// Creates a key after converting a proposed width into an 8-point bucket.
    public init(
        contentHash: UInt64,
        width: CGFloat,
        fontSignature: String,
        displayScaleBits: UInt64,
        appearanceMode: String,
        localeIdentifier: String,
        rendererVersion: Int
    ) {
        self.init(
            contentHash: contentHash,
            widthBucket: Self.widthBucket(for: width),
            fontSignature: fontSignature,
            displayScaleBits: displayScaleBits,
            appearanceMode: appearanceMode,
            localeIdentifier: localeIdentifier,
            rendererVersion: rendererVersion
        )
    }

    /// Maps a proposed width to the nearest 8-point bucket.
    public static func widthBucket(for width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 0 }
        let roundedBucket = (width / widthBucketSize).rounded()
        guard roundedBucket < CGFloat(Int.max) else { return Int.max }
        return max(0, Int(roundedBucket))
    }

    /// The representative width used when a cached bucket needs a measurement.
    public var representativeWidth: CGFloat {
        CGFloat(widthBucket) * Self.widthBucketSize
    }
}

/// Immutable prepared content and the measured height for one transcript block.
///
/// Core stores text rather than an AppKit or TextKit object. Platform adapters can
/// prepare their own immutable representation and use this value at the seam.
public struct BlockLayoutValue: Equatable, Sendable {
    public let preparedContent: String
    public let measuredHeight: CGFloat

    public init(preparedContent: String, measuredHeight: CGFloat) {
        self.preparedContent = preparedContent
        self.measuredHeight = measuredHeight
    }

    /// Conservative resident cost for the dominant payload and fixed value data.
    ///
    /// Swift String storage is implementation-dependent. Two bytes per UTF-8 byte
    /// bounds common native storage while fixed overhead covers the value and key
    /// references. This cost is charged before insertion and never exceeds budget.
    public var byteCost: Int {
        Self.byteCost(preparedContent: preparedContent)
    }

    public static func byteCost(preparedContent: String) -> Int {
        let payload = preparedContent.utf8.count.multipliedReportingOverflow(by: 2)
        guard !payload.overflow else { return Int.max }
        let total = payload.partialValue.addingReportingOverflow(MemoryLayout<CGFloat>.size)
        guard !total.overflow else { return Int.max }
        return max(64, total.partialValue)
    }
}

/// A deterministic, byte-bounded LRU cache for prepared block layouts.
///
/// The cache delegates locking, recency, eviction, and byte accounting to the
/// shared `ByteBoundedCache` implementation. Its 8 MiB ceiling bounds the
/// process-local prepared-content working set. An entry larger than the ceiling
/// is returned by the caller but is not retained.
public final class BlockLayoutCache: @unchecked Sendable {
    public static let defaultByteBudget = 8 * 1024 * 1024

    private let storage: ByteBoundedCache<BlockLayoutKey, BlockLayoutValue>

    public init(byteBudget: Int = BlockLayoutCache.defaultByteBudget) {
        storage = ByteBoundedCache(byteBudget: byteBudget)
    }

    public var byteBudget: Int {
        storage.byteBudget
    }

    public var retainedByteCount: Int {
        storage.retainedByteCount
    }

    public func value(for key: BlockLayoutKey) -> BlockLayoutValue? {
        storage.value(for: key)
    }

    public func insert(_ value: BlockLayoutValue, for key: BlockLayoutKey) {
        storage.insert(value, for: key, byteCost: value.byteCost)
    }

    public func insert(
        preparedContent: String,
        measuredHeight: CGFloat,
        for key: BlockLayoutKey
    ) {
        insert(
            BlockLayoutValue(
                preparedContent: preparedContent,
                measuredHeight: measuredHeight
            ),
            for: key
        )
    }

    /// Returns a cached value or prepares and retains one on a miss.
    public func value(
        for key: BlockLayoutKey,
        preparing: () throws -> BlockLayoutValue
    ) rethrows -> BlockLayoutValue {
        if let cached = value(for: key) {
            return cached
        }
        let prepared = try preparing()
        insert(prepared, for: key)
        return prepared
    }
}

/// Cheap deterministic heights used until a block reaches the viewport.
///
/// The visible renderer replaces this estimate with its measured height and
/// stores that result in `BlockLayoutCache`. Off-screen blocks remain estimated.
public enum BlockHeightEstimator {
    private static let baseLineHeight: CGFloat = 20
    private static let headingLineHeight: CGFloat = 26
    private static let codeLineHeight: CGFloat = 18
    private static let averageCharacterWidth: CGFloat = 7

    /// Estimates a block with no content-length information.
    public static func estimatedHeight(
        for kind: TranscriptBlock.Kind,
        width: CGFloat
    ) -> CGFloat {
        estimatedHeight(for: kind, width: width, contentLength: 0)
    }

    /// Estimates height from kind, width, and UTF-16 content length.
    ///
    /// Increasing content length never decreases the estimate for a fixed kind
    /// and width. The calculation uses arithmetic only and performs no shaping.
    public static func estimatedHeight(
        for kind: TranscriptBlock.Kind,
        width: CGFloat,
        contentLength: Int
    ) -> CGFloat {
        let usableWidth = width.isFinite ? max(1, width) : 1
        let rawCharactersPerLine = (usableWidth / averageCharacterWidth).rounded(.down)
        let charactersPerLine = rawCharactersPerLine >= CGFloat(Int.max)
            ? Int.max
            : max(1, Int(rawCharactersPerLine))
        let normalizedLength = max(0, contentLength)
        let lineCount = max(
            1,
            normalizedLength / charactersPerLine
                + (normalizedLength % charactersPerLine == 0 ? 0 : 1)
        )

        switch kind {
        case .paragraph:
            return 8 + CGFloat(lineCount) * baseLineHeight
        case .heading:
            return 10 + CGFloat(lineCount) * headingLineHeight
        case .list:
            return 8 + CGFloat(lineCount) * baseLineHeight
        case .quote:
            return 8 + CGFloat(lineCount) * baseLineHeight
        case .code:
            return 12 + CGFloat(lineCount) * codeLineHeight
        case .fragmentContinuation:
            return CGFloat(lineCount) * baseLineHeight
        }
    }

    /// Estimates a concrete block using its source range as UTF-16 length.
    public static func estimatedHeight(
        for block: TranscriptBlock,
        width: CGFloat
    ) -> CGFloat {
        estimatedHeight(
            for: block.kind,
            width: width,
            contentLength: block.sourceRange.count
        )
    }
}
