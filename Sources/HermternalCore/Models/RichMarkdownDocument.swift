import Foundation

/// A source range measured in UTF-16 code units.
public struct MarkdownSourceRange: Hashable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }

    public init(_ range: Range<Int>) {
        self.init(location: range.lowerBound, length: max(0, range.upperBound - range.lowerBound))
    }

    public var lowerBound: Int { location }
    public var upperBound: Int { location + length }
    public var range: Range<Int> { location..<upperBound }
}

/// A source-addressable inline value. It contains no platform attributes.
public struct MarkdownInline: Hashable, Sendable, Identifiable {
    public indirect enum Kind: Hashable, Sendable {
        case text(String)
        case emphasis([MarkdownInline])
        case strong([MarkdownInline])
        case strikethrough([MarkdownInline])
        case inlineCode(String)
        case link(destination: String, title: String?, children: [MarkdownInline])
    }

    public let id: String
    public let kind: Kind
    public let sourceRange: MarkdownSourceRange

    public init(id: String, kind: Kind, sourceRange: MarkdownSourceRange) {
        self.id = id
        self.kind = kind
        self.sourceRange = sourceRange
    }
}

/// The optional checked state of an output task-list item.
public enum MarkdownTaskState: String, Hashable, Sendable {
    case checked
    case unchecked
}

/// An ordered list item with its original marker and nesting depth.
public struct MarkdownListItem: Hashable, Sendable, Identifiable {
    public let id: String
    public let marker: String
    public let number: Int?
    public let depth: Int
    public let taskState: MarkdownTaskState?
    public let inlines: [MarkdownInline]
    public let sourceRange: MarkdownSourceRange

    public init(
        id: String,
        marker: String,
        number: Int? = nil,
        depth: Int,
        taskState: MarkdownTaskState? = nil,
        inlines: [MarkdownInline],
        sourceRange: MarkdownSourceRange
    ) {
        self.id = id
        self.marker = marker
        self.number = number
        self.depth = max(0, depth)
        self.taskState = taskState
        self.inlines = inlines
        self.sourceRange = sourceRange
    }
}

/// A table row with source-addressable cells.
public struct MarkdownTableRow: Hashable, Sendable, Identifiable {
    public let id: String
    public let cells: [[MarkdownInline]]
    public let sourceRange: MarkdownSourceRange

    public init(id: String, cells: [[MarkdownInline]], sourceRange: MarkdownSourceRange) {
        self.id = id
        self.cells = cells
        self.sourceRange = sourceRange
    }
}

/// Immutable Markdown blocks exposed to platform adapters.
public indirect enum MarkdownBlock: Hashable, Sendable, Identifiable {
    case paragraph(id: String, sourceRange: MarkdownSourceRange, inlines: [MarkdownInline])
    case heading(id: String, sourceRange: MarkdownSourceRange, level: Int, inlines: [MarkdownInline])
    case list(id: String, sourceRange: MarkdownSourceRange, items: [MarkdownListItem])
    case taskList(id: String, sourceRange: MarkdownSourceRange, items: [MarkdownListItem])
    case quote(id: String, sourceRange: MarkdownSourceRange, inlines: [MarkdownInline])
    case code(id: String, sourceRange: MarkdownSourceRange, language: String, body: String)
    case table(id: String, sourceRange: MarkdownSourceRange, headers: [[MarkdownInline]], rows: [MarkdownTableRow])
    case footnote(id: String, sourceRange: MarkdownSourceRange, label: String, inlines: [MarkdownInline])
    /// The original source remains available when parsing fails.
    case source(id: String, sourceRange: MarkdownSourceRange)

    public var id: String {
        switch self {
        case .paragraph(let id, _, _), .heading(let id, _, _, _),
             .list(let id, _, _), .taskList(let id, _, _), .quote(let id, _, _),
             .code(let id, _, _, _), .table(let id, _, _, _),
             .footnote(let id, _, _, _), .source(let id, _):
            return id
        }
    }

    public var sourceRange: MarkdownSourceRange {
        switch self {
        case .paragraph(_, let range, _), .heading(_, let range, _, _),
             .list(_, let range, _), .taskList(_, let range, _),
             .quote(_, let range, _), .code(_, let range, _, _),
             .table(_, let range, _, _), .footnote(_, let range, _, _),
             .source(_, let range):
            return range
        }
    }
}

/// A precise, non-throwing parse diagnostic.
public struct MarkdownParseError: Error, Hashable, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public let sourceRange: MarkdownSourceRange

    public init(message: String, sourceRange: MarkdownSourceRange) {
        self.message = message
        self.sourceRange = sourceRange
    }

    public var description: String {
        "\(message) at UTF-16 offset \(sourceRange.location)"
    }
}

/// The result of one bounded parse operation.
public struct MarkdownParseResult: Hashable, Sendable {
    public let document: MarkdownDocument
    public let error: MarkdownParseError?

    public init(document: MarkdownDocument, error: MarkdownParseError? = nil) {
        self.document = document
        self.error = error
    }

    public var isValid: Bool { error == nil }
}

/// A lossless, source-addressable rich Markdown document.
public struct MarkdownDocument: Hashable, Sendable {
    public struct Limits: Hashable, Sendable {
        public let maxSourceBytes: Int
        public let maxBlocks: Int
        public let maxInlines: Int

        public init(maxSourceBytes: Int = 4 * 1024 * 1024, maxBlocks: Int = 8_192, maxInlines: Int = 65_536) {
            self.maxSourceBytes = max(1, maxSourceBytes)
            self.maxBlocks = max(1, maxBlocks)
            self.maxInlines = max(1, maxInlines)
        }
    }

    public let source: String
    public let blocks: [MarkdownBlock]

    fileprivate init(source: String, blocks: [MarkdownBlock]) {
        self.source = source
        self.blocks = blocks
    }

    /// Parses Core Markdown and output-only extensions in one pass.
    public static func parse(_ source: String, limits: Limits = Limits()) -> MarkdownParseResult {
        guard source.utf8.count <= limits.maxSourceBytes else {
            let document = MarkdownDocument(source: source, blocks: [.source(
                id: "source-0",
                sourceRange: MarkdownSourceRange(location: 0, length: source.utf16.count)
            )])
            return MarkdownParseResult(
                document: document,
                error: MarkdownParseError(
                    message: "Source exceeds the Markdown size limit",
                    sourceRange: MarkdownSourceRange(location: 0, length: source.utf16.count)
                )
            )
        }

        let parser = MarkdownDocumentParser(source: source, limits: limits)
        return parser.parse()
    }

    /// Serializes the original source without normalizing or losing syntax.
    public static func serialize(_ document: MarkdownDocument) -> String {
        document.source
    }

    public var serializedSource: String { source }
    /// Returns the exact source covered by a block or inline range.
    public func sourceText(in range: MarkdownSourceRange) -> String {
        let units = source.utf16
        let lower = min(max(0, range.location), units.count)
        let upper = min(max(lower, range.location + range.length), units.count)
        let start = String.Index(utf16Offset: lower, in: source)
        let end = String.Index(utf16Offset: upper, in: source)
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    public func sourceText(for block: MarkdownBlock) -> String {
        sourceText(in: block.sourceRange)
    }
}

private struct MarkdownDocumentParser {
    private struct Line {
        let text: Substring
        let start: Int
        let end: Int
    }

    private let lines: [Line]
    private let source: String
    private let limits: MarkdownDocument.Limits
    private var inlineCount = 0
    private var inlineLimitExceeded = false
    private var blockCount = 0

    init(source: String, limits: MarkdownDocument.Limits) {
        self.source = source
        self.limits = limits
        var offset = 0
        self.lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let start = offset
            let end = start + line.utf16.count
            offset = end + 1
            return Line(text: line, start: start, end: end)
        }
    }

    func parse() -> MarkdownParseResult {
        var parser = self
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < parser.lines.count {
            let line = parser.lines[index]
            if parser.isBlank(line.text) {
                index += 1
                continue
            }
            if parser.blockCount >= parser.limits.maxBlocks {
                return parser.invalid("Source exceeds the Markdown block limit", at: line.start, length: line.text.utf16.count)
            }

            if let fence = parser.fence(line.text) {
                let opening = line
                var cursor = index + 1
                var bodyLines: [Substring] = []
                var closing: Line?
                while cursor < parser.lines.count {
                    let candidate = parser.lines[cursor]
                    if parser.isClosingFence(candidate.text, marker: fence.marker) {
                        closing = candidate
                        break
                    }
                    bodyLines.append(candidate.text)
                    cursor += 1
                }
                guard let closing else {
                    return parser.invalid(
                        "Unterminated fenced code block",
                        at: opening.start,
                        length: opening.text.utf16.count
                    )
                }
                let body = bodyLines.joined(separator: "\n")
                let id = parser.blockID(kind: "code", index: blocks.count, range: opening.start..<closing.end)
                blocks.append(.code(
                    id: id,
                    sourceRange: MarkdownSourceRange(opening.start..<closing.end),
                    language: fence.language,
                    body: body
                ))
                parser.blockCount += 1
                index = cursor + 1
                continue
            }

            if let footnote = parser.footnote(line) {
                let id = parser.blockID(kind: "footnote", index: blocks.count, range: line.start..<line.end)
                let inlines = parser.parseInlines(footnote.content, baseOffset: footnote.contentStart)
                blocks.append(.footnote(
                    id: id,
                    sourceRange: MarkdownSourceRange(line.start..<line.end),
                    label: footnote.label,
                    inlines: inlines
                ))
                parser.blockCount += 1
                index += 1
                continue
            }

            if let heading = parser.heading(line) {
                let id = parser.blockID(kind: "heading", index: blocks.count, range: line.start..<line.end)
                blocks.append(.heading(
                    id: id,
                    sourceRange: MarkdownSourceRange(line.start..<line.end),
                    level: heading.level,
                    inlines: parser.parseInlines(heading.content, baseOffset: heading.contentStart)
                ))
                parser.blockCount += 1
                index += 1
                continue
            }

            if parser.isTableStart(index) {
                let header = parser.lines[index]
                let divider = parser.lines[index + 1]
                var cursor = index + 2
                var rows: [MarkdownTableRow] = []
                while cursor < parser.lines.count, parser.tableCells(parser.lines[cursor].text) != nil {
                    let row = parser.lines[cursor]
                    if let cells = parser.tableCells(row.text) {
                        rows.append(MarkdownTableRow(
                            id: parser.blockID(kind: "table-row", index: cursor, range: row.start..<row.end),
                            cells: parser.parseCells(cells, line: row.text, lineStart: row.start),
                            sourceRange: MarkdownSourceRange(row.start..<row.end)
                        ))
                    }
                    cursor += 1
                }
                guard let headerCells = parser.tableCells(header.text) else {
                    return parser.invalid("Invalid table header", at: header.start, length: header.text.utf16.count)
                }
                let headerInlines = parser.parseCells(headerCells, line: header.text, lineStart: header.start)
                let end = cursor > index + 2 ? parser.lines[cursor - 1].end : divider.end
                blocks.append(.table(
                    id: parser.blockID(kind: "table", index: blocks.count, range: header.start..<end),
                    sourceRange: MarkdownSourceRange(header.start..<end),
                    headers: headerInlines,
                    rows: rows
                ))
                parser.blockCount += 1
                index = cursor
                continue
            }

            if let list = parser.listItem(line) {
                var items: [MarkdownListItem] = []
                let firstStart = line.start
                var end = line.end
                var cursor = index
                var hasTask = false
                while cursor < parser.lines.count, let item = parser.listItem(parser.lines[cursor]) {
                    let current = parser.lines[cursor]
                    let content = item.content
                    var task = false
                    var taskContent = content
                    var taskPrefix = item.contentPrefixUTF16
                    if content.hasPrefix("[ ] ") || content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
                        task = true
                        taskContent = content.dropFirst(4)
                        taskPrefix += 4
                    }
                    hasTask = hasTask || task
                    let taskState: MarkdownTaskState? = task
                        ? ((content.hasPrefix("[x] ") || content.hasPrefix("[X] "))
                            ? .checked
                            : .unchecked)
                        : nil
                    let inlines = parser.parseInlines(taskContent, baseOffset: current.start + taskPrefix)
                    items.append(MarkdownListItem(
                        id: parser.blockID(kind: "list-item", index: cursor, range: current.start..<current.end),
                        marker: item.marker,
                        number: item.number,
                        depth: item.depth,
                        taskState: taskState,
                        inlines: inlines,
                        sourceRange: MarkdownSourceRange(current.start..<current.end)
                    ))
                    end = current.end
                    cursor += 1
                }
                let id = parser.blockID(kind: hasTask ? "task-list" : "list", index: blocks.count, range: firstStart..<end)
                let block: MarkdownBlock = hasTask
                    ? .taskList(id: id, sourceRange: MarkdownSourceRange(firstStart..<end), items: items)
                    : .list(id: id, sourceRange: MarkdownSourceRange(firstStart..<end), items: items)
                blocks.append(block)
                parser.blockCount += 1
                index = cursor
                continue
            }

            if parser.isQuote(line.text) {
                let start = line.start
                var end = line.end
                var quoteInlines: [MarkdownInline] = []
                var cursor = index
                while cursor < parser.lines.count, parser.isQuote(parser.lines[cursor].text) {
                    let current = parser.lines[cursor]
                    let stripped = parser.stripQuote(current.text)
                    quoteInlines.append(contentsOf: parser.parseInlines(
                        stripped.text,
                        baseOffset: current.start + stripped.offset
                    ))
                    end = current.end
                    cursor += 1
                }
                let id = parser.blockID(kind: "quote", index: blocks.count, range: start..<end)
                blocks.append(.quote(
                    id: id,
                    sourceRange: MarkdownSourceRange(start..<end),
                    inlines: quoteInlines
                ))
                parser.blockCount += 1
                index = cursor
                continue
            }

            let start = line.start
            var end = line.end
            var content = line.text
            var cursor = index + 1
            while cursor < parser.lines.count {
                let next = parser.lines[cursor]
                guard !parser.isBlank(next.text), parser.fence(next.text) == nil,
                      parser.heading(next) == nil, parser.listItem(next) == nil,
                      !parser.isQuote(next.text), !parser.footnote(next).isSome,
                      !parser.isTableStart(cursor) else { break }
                content.append("\n")
                content.append(contentsOf: next.text)
                end = next.end
                cursor += 1
            }
            let id = parser.blockID(kind: "paragraph", index: blocks.count, range: start..<end)
            blocks.append(.paragraph(
                id: id,
                sourceRange: MarkdownSourceRange(start..<end),
                inlines: parser.parseInlines(content[...], baseOffset: start)
            ))
            parser.blockCount += 1
            index = cursor
        }
        if parser.inlineLimitExceeded {
            return parser.invalid(
                "Source exceeds the Markdown inline limit",
                at: 0,
                length: parser.source.utf16.count
            )
        }
        return MarkdownParseResult(document: MarkdownDocument(source: parser.source, blocks: blocks))
    }

    private func invalid(_ message: String, at location: Int, length: Int) -> MarkdownParseResult {
        let range = MarkdownSourceRange(location: location, length: length)
        return MarkdownParseResult(
            document: MarkdownDocument(source: source, blocks: [.source(id: "source-0", sourceRange: MarkdownSourceRange(location: 0, length: source.utf16.count))]),
            error: MarkdownParseError(message: message, sourceRange: range)
        )
    }

    private func blockID(kind: String, index: Int, range: Range<Int>) -> String {
        "\(kind)-\(index)-\(range.lowerBound)-\(range.upperBound)"
    }

    private func isBlank(_ text: Substring) -> Bool {
        text.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    private func heading(_ line: Line) -> (level: Int, content: Substring, contentStart: Int)? {
        let indentation = line.text.prefix { $0 == " " || $0 == "\t" }
        guard indentation.count <= 3 else { return nil }
        let rest = line.text.dropFirst(indentation.count)
        let hashes = rest.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let after = rest.dropFirst(hashes.count)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        let content = after.drop { $0 == " " || $0 == "\t" }
        return (hashes.count, content, line.start + line.text.utf16.count - content.utf16.count)
    }

    private func listItem(_ line: Line) -> (marker: String, number: Int?, depth: Int, content: Substring, contentPrefixUTF16: Int)? {
        let indentation = line.text.prefix { $0 == " " || $0 == "\t" }
        let rest = line.text.dropFirst(indentation.count)
        guard let first = rest.first else { return nil }
        let depth = indentation.reduce(into: 0) { result, character in result += character == "\t" ? 2 : 1 } / 2
        if "-*+".contains(first) {
            let after = rest.dropFirst()
            guard after.first == " " || after.first == "\t" else { return nil }
            let content = after.drop { $0 == " " || $0 == "\t" }
            let prefix = line.text.utf16.count - content.utf16.count
            return (String(first), nil, depth, content, prefix)
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let after = afterDigits.dropFirst()
        guard after.first == " " || after.first == "\t", let number = Int(digits) else {
            return nil
        }
        let content = after.drop { $0 == " " || $0 == "\t" }
        let prefix = line.text.utf16.count - content.utf16.count
        return (String(digits) + String(delimiter), number, depth, content, prefix)
    }
    private func footnote(_ line: Line) -> (label: String, content: Substring, contentStart: Int)? {
        guard line.text.hasPrefix("[^") else { return nil }
        guard let close = line.text.firstIndex(of: "]"), close < line.text.endIndex else { return nil }
        let after = line.text.index(after: close)
        guard after < line.text.endIndex, line.text[after] == ":" else { return nil }
        let contentStartIndex = line.text.index(after: after)
        let content = line.text[contentStartIndex...].drop { $0 == " " || $0 == "\t" }
        let prefixUTF16 = line.text[..<contentStartIndex].utf16.count
        return (
            String(line.text[line.text.index(line.text.startIndex, offsetBy: 2)..<close]),
            content,
            line.start + prefixUTF16 + (line.text[contentStartIndex...].utf16.count - content.utf16.count)
        )
    }

    private func fence(_ text: Substring) -> (marker: Character, language: String)? {
        let indentation = text.prefix { $0 == " " || $0 == "\t" }
        guard indentation.count <= 3 else { return nil }
        let rest = text.dropFirst(indentation.count)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let marks = rest.prefix { $0 == marker }
        guard marks.count >= 3 else { return nil }
        let info = rest.dropFirst(marks.count).trimmingCharacters(in: .whitespaces)
        return (marker, String(info))
    }

    private func isClosingFence(_ text: Substring, marker: Character) -> Bool {
        guard let value = fence(text), value.marker == marker else { return false }
        return value.language.isEmpty
    }

    private func isQuote(_ text: Substring) -> Bool {
        let indentation = text.prefix { $0 == " " || $0 == "\t" }
        guard indentation.count <= 3 else { return false }
        return text.dropFirst(indentation.count).first == ">"
    }

    private func stripQuote(_ text: Substring) -> (text: Substring, offset: Int) {
        let indentation = text.prefix { $0 == " " || $0 == "\t" }
        let start = indentation.count + 1
        let rest = text.dropFirst(start).drop { $0 == " " || $0 == "\t" }
        return (rest, text.utf16.count - rest.utf16.count)
    }

    private func isTableStart(_ index: Int) -> Bool {
        guard index + 1 < lines.count,
              let header = tableCells(lines[index].text),
              header.count > 0,
              let divider = tableCells(lines[index + 1].text),
              divider.count == header.count else { return false }
        return divider.allSatisfy { cell in
            let value = String(cell).trimmingCharacters(in: .whitespaces)
            return value.count >= 3 && value.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }

    private func tableCells(_ line: Substring) -> [Substring]? {
        guard line.contains("|") else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let value = trimmed.first == "|" ? trimmed.dropFirst() : trimmed[...]
        let withoutEnd = value.last == "|" ? value.dropLast() : value
        let cells = withoutEnd.split(separator: "|", omittingEmptySubsequences: false)
        return cells.isEmpty ? nil : cells
    }

    private mutating func parseCells(_ cells: [Substring], line: Substring, lineStart: Int) -> [[MarkdownInline]] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var offset = lineStart + (line.utf16.count - trimmed.utf16.count)
        if trimmed.first == "|" { offset += 1 }
        var result: [[MarkdownInline]] = []
        result.reserveCapacity(cells.count)
        for cell in cells {
            let leading = cell.prefix { $0 == " " || $0 == "\t" }.utf16.count
            let value = cell.drop { $0 == " " || $0 == "\t" }
            result.append(parseInlines(value, baseOffset: offset + leading))
            offset += cell.utf16.count + 1
        }
        return result
    }
    private mutating func parseInlines(_ text: Substring, baseOffset: Int) -> [MarkdownInline] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        var offsets = [Int](repeating: 0, count: characters.count + 1)
        for index in characters.indices { offsets[index + 1] = offsets[index] + String(characters[index]).utf16.count }
        var result: [MarkdownInline] = []
        var index = 0
        var plainStart = 0
        func flushPlain(_ end: Int) {
            guard end > plainStart else { return }
            var value = ""
            value.reserveCapacity(end - plainStart)
            var cursor = plainStart
            while cursor < end {
                if characters[cursor] == "\\", cursor + 1 < end, "\\`*_[]()~".contains(characters[cursor + 1]) {
                    value.append(characters[cursor + 1])
                    cursor += 2
                } else {
                    value.append(characters[cursor])
                    cursor += 1
                }
            }
            result.append(MarkdownInline(
                id: "inline-\(baseOffset + offsets[plainStart])-\(baseOffset + offsets[end])",
                kind: .text(value),
                sourceRange: MarkdownSourceRange(location: baseOffset + offsets[plainStart], length: offsets[end] - offsets[plainStart])
            ))
            plainStart = end
        }
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                index += 2
                continue
            }
            var markerLength = 0
            var kind: MarkdownInline.Kind?
            if characters[index] == "`" { markerLength = 1; kind = .inlineCode("") }
            else if index + 1 < characters.count, characters[index] == "*", characters[index + 1] == "*" { markerLength = 2; kind = .strong([]) }
            else if index + 1 < characters.count, characters[index] == "_", characters[index + 1] == "_" { markerLength = 2; kind = .strong([]) }
            else if index + 1 < characters.count, characters[index] == "~", characters[index + 1] == "~" { markerLength = 2; kind = .strikethrough([]) }
            else if characters[index] == "*" || characters[index] == "_" { markerLength = 1; kind = .emphasis([]) }
            else if characters[index] == "[" { markerLength = 1 }

            if characters[index] == "[", index + 1 < characters.count,
               let close = characters[(index + 1)...].firstIndex(of: "]"),
               close + 2 < characters.count,
               characters[close + 1] == "(" {
                if let end = characters[(close + 2)...].firstIndex(of: ")") {
                    flushPlain(index)
                    let label = characters[(index + 1)..<close]
                    let destinationText = String(characters[(close + 2)..<end])
                    let target = linkTarget(destinationText)
                    let labelString = String(label)
                    let children = parseInlines(labelString[...], baseOffset: baseOffset + offsets[index] + 1)
                    result.append(MarkdownInline(
                        id: "inline-\(baseOffset + offsets[index])-\(baseOffset + offsets[end + 1])",
                        kind: .link(destination: target.destination, title: target.title, children: children),
                        sourceRange: MarkdownSourceRange(location: baseOffset + offsets[index], length: offsets[end + 1] - offsets[index])
                    ))
                    index = end + 1
                    plainStart = index
                    continue
                }
            }
            if markerLength > 0, let marker = kind, let close = findClosing(characters, start: index + markerLength, markerLength: markerLength, marker: characters[index]) {
                flushPlain(index)
                let inner = characters[(index + markerLength)..<close]
                let innerString = String(inner)
                let innerValues = parseInlines(innerString[...], baseOffset: baseOffset + offsets[index] + markerLength)
                let finalKind: MarkdownInline.Kind
                switch marker {
                case .inlineCode: finalKind = .inlineCode(innerString)
                case .strong: finalKind = .strong(innerValues)
                case .strikethrough: finalKind = .strikethrough(innerValues)
                default: finalKind = .emphasis(innerValues)
                }
                result.append(MarkdownInline(
                    id: "inline-\(baseOffset + offsets[index])-\(baseOffset + offsets[close + markerLength])",
                    kind: finalKind,
                    sourceRange: MarkdownSourceRange(location: baseOffset + offsets[index], length: offsets[close + markerLength] - offsets[index])
                ))
                index = close + markerLength
                plainStart = index
                continue
            }
            index += 1
        }
        flushPlain(characters.count)
        if inlineCount + result.count > limits.maxInlines {
            inlineLimitExceeded = true
            return []
        }
        inlineCount += result.count
        return result
    }

    private func linkTarget(_ value: String) -> (destination: String, title: String?) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (trimmed, nil)
        }
        let destination = String(trimmed[..<separator])
        let title = String(trimmed[trimmed.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        guard title.count >= 2,
              (title.first == "\"" && title.last == "\"")
                || (title.first == "'" && title.last == "'")
                || (title.first == "(" && title.last == ")") else {
            return (trimmed, nil)
        }
        return (destination, String(title.dropFirst().dropLast()))
    }

    private func findClosing(_ characters: [Character], start: Int, markerLength: Int, marker: Character) -> Int? {
        guard start < characters.count else { return nil }
        var index = start
        while index + markerLength <= characters.count {
            var matches = true
            for offset in 0..<markerLength where characters[index + offset] != marker { matches = false; break }
            if matches { return index }
            index += 1
        }
        return nil
    }
}

private extension Optional {
    var isSome: Bool {
        switch self { case .some: return true; case .none: return false }
    }
}
