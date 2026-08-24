import Foundation
@testable import HermternalCore
import Testing

@Test("prose preserves single newlines")
func markdownProsePreservesNewlines() {
    let segments = MarkdownSegment.parse("first line\nsecond line")

    #expect(segments.count == 1)
    guard case .prose(_, let attributed) = segments[0] else {
        Issue.record("Expected one prose segment")
        return
    }
    #expect(String(attributed.characters) == "first line\nsecond line")
}

@Test("blank lines split paragraphs")
func markdownBlankLinesSplitParagraphs() {
    let segments = MarkdownSegment.parse("first\n\nsecond")

    #expect(segments.count == 2)
    #expect(segments.allSatisfy {
        if case .prose = $0 { return true }
        return false
    })
}

@Test("headings and list items expose block metadata")
func markdownBlockMetadata() {
    let segments = MarkdownSegment.parse("# Heading\n\n- parent\n  * child\n\n12) numbered")

    guard segments.count == 4 else {
        Issue.record("Expected heading and three list segments")
        return
    }
    guard case .heading(_, let level, let heading) = segments[0] else {
        Issue.record("Expected heading")
        return
    }
    #expect(level == 1)
    #expect(String(heading.characters) == "Heading")
    guard case .bullet(_, let marker, let depth, let parent) = segments[1],
          case .bullet(_, let nestedMarker, let nestedDepth, let child) = segments[2],
          case .numbered(_, let numberMarker, let number, let numberDepth, let numbered) = segments[3] else {
        Issue.record("Expected bullet and numbered list segments")
        return
    }
    #expect(marker == "-")
    #expect(depth == 0)
    #expect(String(parent.characters) == "parent")
    #expect(nestedMarker == "*")
    #expect(nestedDepth == 1)
    #expect(String(child.characters) == "child")
    #expect(numberMarker == "12)")
    #expect(number == 12)
    #expect(numberDepth == 0)
    #expect(String(numbered.characters) == "numbered")
}

@Test("inline emphasis remains attributed")
func markdownInlineEmphasisRemainsAttributed() {
    let segments = MarkdownSegment.parse("**bold** and `code` and [link](https://example.com)")

    guard case .prose(_, let attributed) = segments[0] else {
        Issue.record("Expected prose segment")
        return
    }
    #expect(attributed.runs.contains {
        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
    })
    #expect(String(attributed.characters).contains("bold"))
}

@Test("fenced code keeps its language and body")
func markdownFencedCodeKeepsLanguageAndBody() {
    let segments = MarkdownSegment.parse("```swift\nlet value = 1\n```")

    guard case .code(_, let language, let body) = segments[0] else {
        Issue.record("Expected fenced code segment")
        return
    }
    #expect(language == "swift")
    #expect(body == "let value = 1")
}

@Test("identical parses have stable segment ids")
func markdownIdentitiesAreStable() {
    let text = "# Title\n\n- one\n- two\n\nbody"
    let first = MarkdownSegment.parse(text).map(\.id)
    let second = MarkdownSegment.parse(text).map(\.id)

    #expect(first == second)
}

@Test("parse cache is bounded by bytes with deterministic LRU behavior")
func markdownParseCacheIsByteBounded() {
    #expect(MarkdownSegment.parseCacheByteBudget > 0)
    let hotText = "hot-entry-\(String(repeating: "x", count: 4_096))"

    _ = MarkdownSegment.parse(hotText)
    for index in 0..<96 {
        if index.isMultiple(of: 8) {
            _ = MarkdownSegment.parse(hotText)
        }
        _ = MarkdownSegment.parse(
            "cache-entry-\(index)-\(String(repeating: "y", count: 128_000))"
        )
        #expect(
            MarkdownSegment.parseCacheRetainedBytes
                <= MarkdownSegment.parseCacheByteBudget
        )
    }

    // A recently used entry remains stable after older entries are evicted.
    let first = MarkdownSegment.parse(hotText).map(\.id)
    let second = MarkdownSegment.parse(hotText).map(\.id)
    #expect(first == second)
}

@Test("Find source spans remain correct after cache eviction")
func markdownSourceSpansRemainCorrectAfterEviction() {
    let text = "before\n\n```swift\nlet value = 1\n```\n\nafter"
    let expected = MarkdownSegment.sourceSpans(for: text)

    for index in 0..<96 {
        _ = MarkdownSegment.parse("eviction-\(index)-\(String(repeating: "z", count: 128_000))")
    }

    let actual = MarkdownSegment.sourceSpans(for: text)
    #expect(actual.count == expected.count)
    for (actualSpan, expectedSpan) in zip(actual, expected) {
        #expect(actualSpan.source == expectedSpan.source)
        #expect(actualSpan.language == expectedSpan.language)
    }
    #expect(
        MarkdownSegment.parseCacheRetainedBytes
            <= MarkdownSegment.parseCacheByteBudget
    )
}

@Test("row-height key includes every layout input")
func markdownRowHeightKeyInvalidatesEveryInput() {
    let base = RowHeightCacheKey(
        messageID: .server(ServerMessageID(rawValue: 7)),
        revision: "revision-1",
        availableWidthBits: Double(400).bitPattern,
        textStyle: "body-13",
        displayScaleBits: Double(2).bitPattern,
        rendererVersion: 1
    )
    let identityChanged = RowHeightCacheKey(
        messageID: .server(ServerMessageID(rawValue: 8)),
        revision: base.revision,
        availableWidthBits: base.availableWidthBits,
        textStyle: base.textStyle,
        displayScaleBits: base.displayScaleBits,
        rendererVersion: base.rendererVersion
    )
    let revisionChanged = RowHeightCacheKey(
        messageID: base.messageID,
        revision: "revision-2",
        availableWidthBits: base.availableWidthBits,
        textStyle: base.textStyle,
        displayScaleBits: base.displayScaleBits,
        rendererVersion: base.rendererVersion
    )
    let widthChanged = RowHeightCacheKey(
        messageID: base.messageID,
        revision: base.revision,
        availableWidthBits: Double(401).bitPattern,
        textStyle: base.textStyle,
        displayScaleBits: base.displayScaleBits,
        rendererVersion: base.rendererVersion
    )
    let styleChanged = RowHeightCacheKey(
        messageID: base.messageID,
        revision: base.revision,
        availableWidthBits: base.availableWidthBits,
        textStyle: "body-14",
        displayScaleBits: base.displayScaleBits,
        rendererVersion: base.rendererVersion
    )
    let scaleChanged = RowHeightCacheKey(
        messageID: base.messageID,
        revision: base.revision,
        availableWidthBits: base.availableWidthBits,
        textStyle: base.textStyle,
        displayScaleBits: Double(1).bitPattern,
        rendererVersion: base.rendererVersion
    )
    let rendererChanged = RowHeightCacheKey(
        messageID: base.messageID,
        revision: base.revision,
        availableWidthBits: base.availableWidthBits,
        textStyle: base.textStyle,
        displayScaleBits: base.displayScaleBits,
        rendererVersion: 2
    )

    #expect(base == base)
    #expect(base != identityChanged)
    #expect(base != revisionChanged)
    #expect(base != widthChanged)
    #expect(base != styleChanged)
    #expect(base != scaleChanged)
    #expect(base != rendererChanged)
}

@Test("shared byte cache evicts deterministically under its budget")
func markdownSharedByteCacheEvictsDeterministically() {
    let cache = ByteBoundedCache<String, String>(byteBudget: 10)
    cache.insert("old", for: "old", byteCost: 4)
    cache.insert("hot", for: "hot", byteCost: 4)
    let oldValue = cache.value(for: "old")
    #expect(oldValue == "old")
    cache.insert("new", for: "new", byteCost: 4)
    let hotValue = cache.value(for: "hot")
    let newValue = cache.value(for: "new")
    #expect(hotValue == nil)
    #expect(newValue == "new")
    #expect(cache.retainedByteCount == 8)
}
