import Foundation

/// A position inside one transcript block.
///
/// `utf16Offset` is local to the block's `sourceRange`. The coordinator clamps
/// the offset to the block length when it resolves a selection against blocks.
public struct BlockTextPosition: Hashable, Sendable {
    public let messageID: String
    public let blockIndex: Int
    public let utf16Offset: Int

    public init(messageID: String, blockIndex: Int, utf16Offset: Int) {
        self.messageID = messageID
        self.blockIndex = blockIndex
        self.utf16Offset = max(0, utf16Offset)
    }
}

/// An ordered pair of positions in transcript text.
public struct BlockSelectionRange: Hashable, Sendable {
    public let start: BlockTextPosition
    public let end: BlockTextPosition

    public init(start: BlockTextPosition, end: BlockTextPosition) {
        if Self.precedes(end, start) {
            self.start = end
            self.end = start
        } else {
            self.start = start
            self.end = end
        }
    }

    public var isCollapsed: Bool { start == end }
    public var lowerBound: BlockTextPosition { start }
    public var upperBound: BlockTextPosition { end }

    private static func precedes(
        _ lhs: BlockTextPosition,
        _ rhs: BlockTextPosition
    ) -> Bool {
        if lhs.messageID != rhs.messageID { return lhs.messageID < rhs.messageID }
        if lhs.blockIndex != rhs.blockIndex { return lhs.blockIndex < rhs.blockIndex }
        return lhs.utf16Offset < rhs.utf16Offset
    }
}

/// Coordinates selection across rows without depending on a platform text view.
public final class BlockSelectionCoordinator {
    private var anchor: BlockTextPosition?

    public private(set) var selectedRange: BlockSelectionRange?

    public init() {}

    public func begin(at anchor: BlockTextPosition) {
        self.anchor = anchor
        selectedRange = BlockSelectionRange(start: anchor, end: anchor)
    }

    public func extend(to focus: BlockTextPosition) {
        guard let anchor else {
            begin(at: focus)
            return
        }
        selectedRange = BlockSelectionRange(start: anchor, end: focus)
    }

    public func clear() {
        anchor = nil
        selectedRange = nil
    }

    /// Copies the selected span as reader-facing text.
    public func plainText(
        for range: BlockSelectionRange,
        blocks: [TranscriptBlock],
        messageText: (String) -> String?
    ) -> String {
        let pieces = resolvedPieces(for: range, blocks: blocks, messageText: messageText)
        guard !pieces.isEmpty else { return "" }

        var groups: [[Piece]] = []
        for piece in pieces {
            if let last = groups.last?.last,
               piece.block.messageID == last.block.messageID,
               piece.block.continuationOf != nil,
               piece.block.continuationOf == last.logicalBlockIndex {
                groups[groups.count - 1].append(piece)
            } else {
                groups.append([piece])
            }
        }

        var output = ""
        var previous: TranscriptBlock?
        for group in groups {
            let text = group.map(\.text).joined().trimmingCharacters(in: .newlines)
            guard !text.isEmpty else { continue }
            if let previous {
                output += plainSeparator(after: previous, before: group[0].block)
            }
            output += text
            previous = group[group.count - 1].block
        }
        return output

    }
    /// Copies the selected span as its original Markdown source.
    ///
    /// Each message is sliced directly from its source text. This preserves
    /// fences, list markers, and source whitespace instead of rendered output.
    public func markdownSource(
        for range: BlockSelectionRange,
        blocks: [TranscriptBlock],
        messageText: (String) -> String?
    ) -> String {
        let selections = resolvedMessageSelections(
            for: range,
            blocks: blocks,
            messageText: messageText
        )
        guard !selections.isEmpty else { return "" }

        return selections.compactMap { selection in
            guard let text = messageText(selection.messageID) else { return nil }
            return slice(text, range: selection.sourceRange)
        }.joined(separator: "\n\n")
    }

    private struct Piece {
        let block: TranscriptBlock
        let text: String
        let logicalBlockIndex: Int
    }

    private struct MessageSelection {
        let messageID: String
        let sourceRange: Range<Int>
    }

    private func resolvedPieces(
        for range: BlockSelectionRange,
        blocks: [TranscriptBlock],
        messageText: (String) -> String?
    ) -> [Piece] {
        guard let endpoints = endpoints(for: range, blocks: blocks),
              endpoints.start.index <= endpoints.end.index,
              !(endpoints.start.index == endpoints.end.index
                && endpoints.start.offset == endpoints.end.offset)
        else { return [] }

        var pieces: [Piece] = []
        pieces.reserveCapacity(endpoints.end.index - endpoints.start.index + 1)
        for index in endpoints.start.index...endpoints.end.index {
            let block = blocks[index]
            guard let text = messageText(block.messageID) else { continue }
            let lower = index == endpoints.start.index ? endpoints.start.offset : 0
            let upper = index == endpoints.end.index
                ? endpoints.end.offset
                : block.sourceRange.count
            guard lower < upper else { continue }
            let absoluteRange = block.sourceRange.lowerBound + lower
                ..< block.sourceRange.lowerBound + upper
            let source = slice(text, range: absoluteRange)
            let rendered = plainFragment(source, kind: block.kind)
            guard !rendered.isEmpty else { continue }
            pieces.append(Piece(
                block: block,
                text: rendered,
                logicalBlockIndex: block.continuationOf ?? block.blockIndex
            ))
        }
        return pieces
    }

    private func resolvedMessageSelections(
        for range: BlockSelectionRange,
        blocks: [TranscriptBlock],
        messageText: (String) -> String?
    ) -> [MessageSelection] {
        guard let endpoints = endpoints(for: range, blocks: blocks),
              endpoints.start.index <= endpoints.end.index,
              !(endpoints.start.index == endpoints.end.index
                && endpoints.start.offset == endpoints.end.offset)
        else { return [] }

        var result: [MessageSelection] = []
        var index = endpoints.start.index
        while index <= endpoints.end.index {
            let messageID = blocks[index].messageID
            let groupStart = index
            while index < endpoints.end.index, blocks[index + 1].messageID == messageID {
                index += 1
            }
            let groupEnd = index
            let first = blocks[groupStart]
            let last = blocks[groupEnd]
            let firstOffset = groupStart == endpoints.start.index ? endpoints.start.offset : 0
            let lastOffset = groupEnd == endpoints.end.index
                ? endpoints.end.offset
                : last.sourceRange.count
            let start = first.sourceRange.lowerBound + firstOffset
            let end = last.sourceRange.lowerBound + lastOffset
            if start < end, messageText(messageID) != nil {
                result.append(MessageSelection(
                    messageID: messageID,
                    sourceRange: start..<end
                ))
            }
            index += 1
        }
        return result
    }

    private struct Endpoint {
        let index: Int
        let offset: Int
    }

    private struct Endpoints {
        var start: Endpoint
        var end: Endpoint
    }

    private func endpoints(
        for range: BlockSelectionRange,
        blocks: [TranscriptBlock]
    ) -> Endpoints? {
        guard let startIndex = blocks.firstIndex(where: {
            $0.messageID == range.start.messageID && $0.blockIndex == range.start.blockIndex
        }), let endIndex = blocks.firstIndex(where: {
            $0.messageID == range.end.messageID && $0.blockIndex == range.end.blockIndex
        }) else { return nil }

        let start = Endpoint(
            index: startIndex,
            offset: clamp(range.start.utf16Offset, to: blocks[startIndex].sourceRange.count)
        )
        let end = Endpoint(
            index: endIndex,
            offset: clamp(range.end.utf16Offset, to: blocks[endIndex].sourceRange.count)
        )
        if start.index < end.index || (start.index == end.index && start.offset <= end.offset) {
            return Endpoints(start: start, end: end)
        }
        return Endpoints(start: end, end: start)
    }

    private func plainSeparator(
        after previous: TranscriptBlock,
        before current: TranscriptBlock
    ) -> String {
        if previous.messageID != current.messageID { return "\n\n" }
        if previous.kind == .list, current.kind == .list { return "\n" }
        return "\n\n"
    }

    private func plainFragment(
        _ source: String,
        kind: TranscriptBlock.Kind
    ) -> String {
        switch kind {
        case .code:
            return stripCodeFences(source)
        case .list:
            return sourceLines(source) { _ in true }
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { stripListMarker(String($0)) }
                .joined(separator: "\n")
        case .heading:
            return sourceLines(source) { _ in true }
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { stripHeadingMarker(String($0)) }
                .joined(separator: "\n")
        case .quote:
            return sourceLines(source) { _ in true }
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { stripQuoteMarker(String($0)) }
                .joined(separator: "\n")
        case .paragraph, .fragmentContinuation:
            return source
        }
    }

    private func sourceLines(
        _ source: String,
        keep: (String) -> Bool
    ) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter(keep)
            .joined(separator: "\n")
    }

    private func stripCodeFences(_ source: String) -> String {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !lines.isEmpty else { return "" }

        var first = 0
        if lines[first].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            first += 1
        }

        var last = lines.count
        while last > first, lines[last - 1].isEmpty {
            last -= 1
        }
        if last > first,
           lines[last - 1].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            last -= 1
        }
        guard first < last else { return "" }
        return lines[first..<last]
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    private func stripListMarker(_ line: String) -> String {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let remainder = line.dropFirst(leading.count)
        guard let first = remainder.first else { return line }
        if ["-", "*", "+"].contains(first), remainder.dropFirst().first == " " {
            return String(remainder.dropFirst(2))
        }
        var digitCount = 0
        for character in remainder {
            guard character.isNumber else { break }
            digitCount += 1
        }
        guard digitCount > 0 else { return line }
        let markerEnd = remainder.index(remainder.startIndex, offsetBy: digitCount)
        guard markerEnd < remainder.endIndex,
              [".", ")"].contains(remainder[markerEnd]) else { return line }
        let contentStart = remainder.index(after: markerEnd)
        guard contentStart < remainder.endIndex, remainder[contentStart] == " " else {
            return line
        }
        return String(remainder[remainder.index(after: contentStart)...])
    }

    private func stripHeadingMarker(_ line: String) -> String {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let remainder = line.dropFirst(leading.count)
        let hashes = remainder.prefix(while: { $0 == "#" })
        guard !hashes.isEmpty,
              hashes.count <= 6,
              remainder.dropFirst(hashes.count).first == " " else { return line }
        return String(remainder.dropFirst(hashes.count + 1))
    }

    private func stripQuoteMarker(_ line: String) -> String {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let remainder = line.dropFirst(leading.count)
        guard remainder.first == ">" else { return line }
        let content = remainder.dropFirst()
        return String(content.first == " " ? content.dropFirst() : content)
    }

    private func clamp(_ value: Int, to length: Int) -> Int {
        min(max(0, value), max(0, length))
    }

    private func slice(_ text: String, range: Range<Int>) -> String {
        let length = text.utf16.count
        let lower = clamp(range.lowerBound, to: length)
        let upper = clamp(range.upperBound, to: length)
        guard lower < upper else { return "" }
        let start = String.Index(utf16Offset: lower, in: text)
        let end = String.Index(utf16Offset: upper, in: text)
        return String(decoding: text.utf16[start..<end], as: UTF16.self)
    }
}
