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

@Test("rich Markdown round trips Core constructs and Unicode")
func richMarkdownRoundTripsCoreConstructs() {
    let source = """
    # Títle

    A **bold** and *italic* [link](https://example.com "Example") with `code` and \\*literal\\*.

    - parent
      * child
    12) numbered

    > quoted line

    ```swift
    let value = "é"
    ```
    """
    let result = MarkdownDocument.parse(source)

    #expect(result.isValid)
    #expect(result.error == nil)
    #expect(MarkdownDocument.serialize(result.document) == source)
    #expect(result.document.serializedSource == source)
    #expect(result.document.blocks.count == 5)
    guard case .heading(_, _, let level, _) = result.document.blocks[0],
          case .paragraph(_, _, let inlines) = result.document.blocks[1],
          case .list(_, _, let items) = result.document.blocks[2],
          case .quote(_, _, _) = result.document.blocks[3],
          case .code(_, _, let language, let body) = result.document.blocks[4] else {
        Issue.record("Expected heading, paragraph, list, quote, and code blocks")
        return
    }
    #expect(level == 1)
    #expect(items.count == 3)
    #expect(items[1].depth == 1)
    #expect(language == "swift")
    #expect(body.contains("é"))
    #expect(inlines.contains {
        if case .link(let destination, let title, _) = $0.kind {
            return destination == "https://example.com" && title == "Example"
        }
        return false
    })
    #expect(inlines.contains {
        if case .text(let text) = $0.kind { return text.contains("*literal*") }
        return false
    })
}

@Test("rich Markdown exposes output-only tables tasks footnotes and strike")
func richMarkdownExposesOutputExtensions() {
    let source = """
    | Name | Value |
    | --- | --- |
    | one | **1** |

    - [x] done
      - [ ] nested

    [^note]: Supporting text with ~~removed~~ words.
    """
    let result = MarkdownDocument.parse(source)

    #expect(result.isValid)
    #expect(MarkdownDocument.serialize(result.document) == source)
    guard case .table(_, _, let headers, let rows) = result.document.blocks[0],
          case .taskList(_, _, let items) = result.document.blocks[1],
          case .footnote(_, _, let label, let footnoteInlines) = result.document.blocks[2] else {
        Issue.record("Expected table, task list, and footnote blocks")
        return
    }
    #expect(headers.count == 2)
    #expect(rows.count == 1)
    #expect(items.count == 2)
    #expect(items[0].depth == 0)
    #expect(items[1].depth == 1)
    #expect(label == "note")
    #expect(footnoteInlines.contains {
        if case .strikethrough = $0.kind { return true }
        return false
    })
    #expect(items[0].taskState == .checked)
    #expect(items[1].taskState == .unchecked)
}

@Test("rich Markdown preserves source ranges and inline selection")
func richMarkdownPreservesSourceRanges() {
    let source = "é **bold**\n\n[open](https://example.com)"
    let result = MarkdownDocument.parse(source)

    #expect(result.isValid)
    guard case .paragraph(_, let paragraphRange, let inlines) = result.document.blocks[0],
          let bold = inlines.first(where: {
              if case .strong = $0.kind { return true }
              return false
          }),
          case .paragraph(_, let linkRange, let linkInlines) = result.document.blocks[1],
          let link = linkInlines.first else {
        Issue.record("Expected source-addressable paragraph inlines")
        return
    }
    #expect(paragraphRange.range == 0..<10)
    #expect(bold.sourceRange.range == 2..<10)
    #expect(linkRange.range == 12..<39)
    #expect(link.sourceRange.range == 12..<39)
}

@Test("invalid rich Markdown keeps original Source and precise error")
func invalidRichMarkdownKeepsSource() {
    let source = "before\n\n```swift\nmissing closer"
    let result = MarkdownDocument.parse(source)

    #expect(!result.isValid)
    #expect(result.error?.message == "Unterminated fenced code block")
    #expect(result.error?.sourceRange.location == 8)
    #expect(result.document.source == source)
    guard let first = result.document.blocks.first,
          case .source(_, let range) = first else {
        Issue.record("Invalid input must remain a Source block")
        return
    }
    #expect(range.range == 0..<source.utf16.count)
    #expect(MarkdownDocument.serialize(result.document) == source)
}

@Test("rich Markdown bounds source and inline work")
func richMarkdownBoundsWork() {
    let tooLarge = MarkdownDocument.parse(
        "123456789",
        limits: .init(maxSourceBytes: 8, maxBlocks: 2, maxInlines: 2)
    )
    #expect(!tooLarge.isValid)
    #expect(tooLarge.document.source == "123456789")

    let tooMany = MarkdownDocument.parse(
        "one **two** and *three*",
        limits: .init(maxSourceBytes: 100, maxBlocks: 4, maxInlines: 1)
    )
    #expect(!tooMany.isValid)
    #expect(tooMany.document.source == "one **two** and *three*")
}

@Test("rich Markdown maps selection ranges back to exact source")
func richMarkdownMapsRangesToSource() {
    let source = "A **bold** value"
    let result = MarkdownDocument.parse(source)
    guard case .paragraph(_, _, let inlines) = result.document.blocks.first,
          let bold = inlines.first(where: {
              if case .strong = $0.kind { return true }
              return false
          }) else {
        Issue.record("Expected a strong inline")
        return
    }

    #expect(result.document.sourceText(in: bold.sourceRange) == "**bold**")
    #expect(result.document.sourceText(for: result.document.blocks[0]) == source)
}
