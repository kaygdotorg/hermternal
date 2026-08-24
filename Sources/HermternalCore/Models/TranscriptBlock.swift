import Foundation

/// The top-level Markdown shape that a transcript renderer draws.
public struct TranscriptBlock: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case paragraph
        case heading
        case list
        case quote
        case code
        case fragmentContinuation
    }

    public let messageID: String
    public let blockIndex: Int
    public let kind: Kind
    /// A UTF-16 range into the message text.
    public let sourceRange: Range<Int>
    /// FNV-1a over the block kind, language, and exact source bytes.
    /// This bounded-cache identity has a theoretical collision, like any
    /// fixed-width digest. A collision can only return a transient wrong
    /// layout height because visible blocks are measured and corrected.
    /// Revisit this choice before caching prepared content where collisions
    /// could display the wrong text.
    public let contentHash: UInt64
    public let language: String?
    /// The first block index for this logical block when this is a fragment.
    /// This lets selection and copy join continuation rows without changing
    /// the stable `(messageID, blockIndex)` identity of each drawn row.
    public let continuationOf: Int?

    public var id: String {
        "\(messageID):\(blockIndex)"
    }

    public init(
        messageID: String,
        blockIndex: Int,
        kind: Kind,
        sourceRange: Range<Int>,
        contentHash: UInt64,
        language: String? = nil,
        continuationOf: Int? = nil
    ) {
        self.messageID = messageID
        self.blockIndex = blockIndex
        self.kind = kind
        self.sourceRange = sourceRange
        self.contentHash = contentHash
        self.language = language
        self.continuationOf = continuationOf
    }

    public var isContinuation: Bool {
        continuationOf != nil || kind == .fragmentContinuation
    }
}

/// A compatibility spelling for code that prefers a top-level kind name.
public typealias TranscriptBlockKind = TranscriptBlock.Kind

/// The smallest changed suffix after streaming text is appended.
public struct TranscriptBlockResegmentation: Sendable, Equatable {
    public let blocks: [TranscriptBlock]
    public let changedBlocks: [TranscriptBlock]
    public let unchangedPrefixCount: Int

    public init(
        blocks: [TranscriptBlock],
        changedBlocks: [TranscriptBlock],
        unchangedPrefixCount: Int
    ) {
        self.blocks = blocks
        self.changedBlocks = changedBlocks
        self.unchangedPrefixCount = unchangedPrefixCount
    }
}

/// Parses one message into source-addressable top-level Markdown blocks.
public enum TranscriptBlockSegmenter {
    public static let fragmentTargetUTF16Length = 2_000

    public static func blocks(for message: ChatMessage) -> [TranscriptBlock] {
        blocks(for: messageID(for: message), text: message.text)
    }

    /// Segments text with a caller-supplied stable message identity.
    public static func blocks(for messageID: String, text: String) -> [TranscriptBlock] {
        let parsed = MarkdownSegment.segments(
            for: text,
            owner: .blockPreparation
        )
        let spans = MarkdownSegment.sourceSpans(
            for: text,
            owner: .blockPreparation
        )
        guard parsed.count == spans.count else {
            // The parser contract promises aligned arrays. Returning no rows
            // is safer than assigning a wrong range to a visible block if a
            // future parser version violates that contract.
            return []
        }

        var result: [TranscriptBlock] = []
        result.reserveCapacity(parsed.count)
        for (segment, span) in zip(parsed, spans) {
            let base = makeBaseBlock(
                messageID: messageID,
                text: text,
                segment: segment,
                sourceRange: sourceRange(for: segment, parserRange: span.source, text: text),
                language: span.language.flatMap {
                    let value = slice(text, range: $0).trimmingCharacters(in: .whitespaces)
                    return value.isEmpty ? nil : value
                }
            )
            append(base, from: text, to: &result)
        }
        return result
    }

    /// Re-segments an append and returns only the changed trailing suffix.
    /// Completed prefix values are reused from `previous` without rebuilding.
    public static func resegment(
        previous: [TranscriptBlock],
        previousMessage: ChatMessage,
        appendedText: String
    ) -> TranscriptBlockResegmentation {
        var text = previousMessage.text
        text.append(appendedText)
        let message = ChatMessage(
            id: previousMessage.id,
            role: previousMessage.role,
            text: text,
            timestamp: previousMessage.timestamp,
            isStreaming: previousMessage.isStreaming
        )
        return resegment(previous: previous, previousMessage: previousMessage, message: message)
    }

    public static func resegment(
        previous: [TranscriptBlock],
        previousMessage: ChatMessage,
        message: ChatMessage
    ) -> TranscriptBlockResegmentation {
        let identifier = messageID(for: message)
        guard messageID(for: previousMessage) == identifier,
              message.text.utf16.starts(with: previousMessage.text.utf16)
        else {
            let fresh = blocks(for: message)
            return TranscriptBlockResegmentation(
                blocks: fresh,
                changedBlocks: fresh,
                unchangedPrefixCount: 0
            )
        }

        let newLength = message.text.utf16.count
        let firstTrailingIndex: Int
        let trailingStart: Int
        if let last = previous.last {
            let logicalIndex = last.continuationOf ?? last.blockIndex
            firstTrailingIndex = previous.firstIndex {
                $0.blockIndex == logicalIndex
            } ?? max(0, previous.count - 1)
            trailingStart = previous[firstTrailingIndex].sourceRange.lowerBound
        } else {
            firstTrailingIndex = 0
            trailingStart = 0
        }

        // The suffix starts at the last logical block. This preserves every
        // completed block and still handles a partial fence becoming a fence.
        let suffix = slice(message.text, range: trailingStart..<newLength)
        let trailing = blocks(for: identifier, text: suffix).enumerated().map {
            offset, block in
            let lowerBound: Int = block.sourceRange.lowerBound + trailingStart
            let upperBound: Int = block.sourceRange.upperBound + trailingStart
            let adjustedRange: Range<Int> = lowerBound..<upperBound
            let continuationOf: Int? = block.continuationOf.map {
                $0 + firstTrailingIndex
            }
            return TranscriptBlock(
                messageID: block.messageID,
                blockIndex: firstTrailingIndex + offset,
                kind: block.kind,
                sourceRange: adjustedRange,
                contentHash: block.contentHash,
                language: block.language,
                continuationOf: continuationOf
            )
        }
        var fresh = Array(previous.prefix(firstTrailingIndex))
        fresh.append(contentsOf: trailing)

        // Appending after a completed block can leave that block unchanged.
        // Compare the rebuilt suffix and report the smallest changed suffix.
        var prefix = 0
        while prefix < previous.count, prefix < fresh.count,
              previous[prefix] == fresh[prefix] {
            prefix += 1
        }
        if prefix > 0 {
            fresh.replaceSubrange(0..<prefix, with: previous.prefix(prefix))
        }
        return TranscriptBlockResegmentation(
            blocks: fresh,
            changedBlocks: Array(fresh.dropFirst(prefix)),
            unchangedPrefixCount: prefix
        )
    }

    /// Convenience for callers that need only the changed rows.
    public static func changedBlocks(
        previous: [TranscriptBlock],
        previousMessage: ChatMessage,
        appendedText: String
    ) -> [TranscriptBlock] {
        resegment(
            previous: previous,
            previousMessage: previousMessage,
            appendedText: appendedText
        ).changedBlocks
    }

    private static func makeBaseBlock(
        messageID: String,
        text: String,
        segment: MarkdownSegment,
        sourceRange: Range<Int>,
        language: String?
    ) -> TranscriptBlock {
        let kind: TranscriptBlock.Kind
        switch segment {
        case .prose:
            kind = isQuote(text, range: sourceRange) ? .quote : .paragraph
        case .heading:
            kind = .heading
        case .bullet, .numbered:
            kind = .list
        case .code:
            kind = .code
        }
        let hash = contentHash(kind: kind, language: language, text: slice(text, range: sourceRange))
        return TranscriptBlock(
            messageID: messageID,
            blockIndex: 0,
            kind: kind,
            sourceRange: sourceRange,
            contentHash: hash,
            language: kind == .code ? language : nil
        )
    }

    private static func append(
        _ base: TranscriptBlock,
        from text: String,
        to result: inout [TranscriptBlock]
    ) {
        let ranges = base.kind == .paragraph
            ? fragmentRanges(base.sourceRange, in: text)
            : [base.sourceRange]
        let logicalIndex = result.count
        for (fragmentIndex, range) in ranges.enumerated() {
            let isFragment = fragmentIndex > 0
            let kind: TranscriptBlock.Kind = isFragment ? .fragmentContinuation : base.kind
            let blockIndex = result.count
            result.append(TranscriptBlock(
                messageID: base.messageID,
                blockIndex: blockIndex,
                kind: kind,
                sourceRange: range,
                contentHash: contentHash(
                    kind: kind,
                    language: base.language,
                    text: slice(text, range: range)
                ),
                language: base.language,
                continuationOf: isFragment ? logicalIndex : nil
            ))
        }
    }

    private static func fragmentRanges(_ range: Range<Int>, in text: String) -> [Range<Int>] {
        guard range.count > fragmentTargetUTF16Length else { return [range] }
        let breaks = lineBreakEnds(in: text, range: range)
        guard !breaks.isEmpty else { return [range] }

        var result: [Range<Int>] = []
        var start = range.lowerBound
        while start < range.upperBound {
            let target = start + fragmentTargetUTF16Length
            guard target < range.upperBound else {
                result.append(start..<range.upperBound)
                break
            }
            var boundary: Int?
            var bestDistance: Int?
            for candidate in breaks {
                guard candidate > start && candidate < range.upperBound else { continue }
                let distance: Int = abs(candidate - target)
                if let currentBest: Int = bestDistance {
                    guard distance < currentBest else { continue }
                }
                boundary = candidate
                bestDistance = distance
            }
            guard let boundary else {
                result.append(start..<range.upperBound)
                break
            }
            result.append(start..<boundary)
            start = boundary
        }
        return result
    }

    private static func lineBreakEnds(in text: String, range: Range<Int>) -> [Int] {
        let units = Array(text.utf16)
        guard range.upperBound <= units.count else { return [] }
        var result: [Int] = []
        for index in range where units[index] == 10 {
            let end = index + 1
            if end > range.lowerBound && end < range.upperBound { result.append(end) }
        }
        return result
    }

    private static func sourceRange(
        for segment: MarkdownSegment,
        parserRange: Range<Int>,
        text: String
    ) -> Range<Int> {
        guard case .code = segment else { return parserRange }
        let units = Array(text.utf16)
        let bodyStart: Int = min(parserRange.lowerBound, units.count)
        let previousUnits = units[..<bodyStart]
        let bodyLineStart: Int
        if let lineBreak = previousUnits.lastIndex(of: 10) {
            bodyLineStart = lineBreak + 1
        } else {
            bodyLineStart = 0
        }
        let openingStart: Int
        if let openingLineBreak = previousUnits.lastIndex(of: 10) {
            let beforeOpening = units[..<openingLineBreak]
            if let previousLineBreak = beforeOpening.lastIndex(of: 10) {
                openingStart = previousLineBreak + 1
            } else {
                openingStart = 0
            }
        } else {
            openingStart = 0
        }
        var end: Int = parserRange.upperBound
        var cursor: Int = bodyLineStart
        let fenceMarker: [UInt16] = Array("```".utf16)
        while cursor < units.count {
            let remaining = units[cursor...]
            let lineBreak = remaining.firstIndex(of: 10)
            let lineEnd: Int = lineBreak ?? units.count
            let line = units[cursor..<lineEnd]
            if line.starts(with: fenceMarker) {
                end = lineEnd
                break
            }
            cursor = lineEnd < units.count ? lineEnd + 1 : units.count
        }
        let boundedEnd: Int = max(openingStart, end)
        return openingStart..<boundedEnd
    }

    private static func isQuote(_ text: String, range: Range<Int>) -> Bool {
        let value = slice(text, range: range)
        let lines = value.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            let indentation = line.prefix { $0 == " " || $0 == "\t" }
            return indentation.count <= 3 && line.dropFirst(indentation.count).first == ">"
        }
    }

    private static func contentHash(kind: TranscriptBlock.Kind, language: String?, text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (kind.rawValue + "|" + (language ?? "") + "|" + text).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func slice(_ text: String, range: Range<Int>) -> String {
        let units = text.utf16
        let start = String.Index(utf16Offset: max(0, range.lowerBound), in: text)
        let end = String.Index(utf16Offset: min(units.count, range.upperBound), in: text)
        return String(decoding: text.utf16[start..<end], as: UTF16.self)
    }

    private static func messageID(for message: ChatMessage) -> String {
        switch message.id {
        case .server(let id): return String(id.rawValue)
        case .provisional(let id): return id.uuidString
        }
    }
}
