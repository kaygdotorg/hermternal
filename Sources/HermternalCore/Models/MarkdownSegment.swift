import Foundation

/// A message body split into prose and fenced-code runs.
public enum MarkdownSegment: Identifiable, Sendable {
    case prose(id: Int, AttributedString)
    case code(id: Int, language: String, body: String)

    public var id: Int {
        switch self {
        case .prose(let id, _): id
        case .code(let id, _, _): id
        }
    }

    public static func parse(_ text: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var proseBuffer: [Substring] = []
        var codeBuffer: [Substring] = []
        var language = ""
        var inFence = false
        var nextID = 0

        func flushProse() {
            let joined = proseBuffer.joined(separator: "\n")
            proseBuffer.removeAll()
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            segments.append(.prose(id: nextID, attributed(from: trimmed)))
            nextID += 1
        }

        func flushCode() {
            let body = codeBuffer.joined(separator: "\n")
            codeBuffer.removeAll()
            segments.append(.code(id: nextID, language: language, body: body))
            nextID += 1
            language = ""
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                if inFence {
                    flushCode()
                    inFence = false
                } else {
                    flushProse()
                    language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inFence = true
                }
                continue
            }
            if inFence { codeBuffer.append(line) } else { proseBuffer.append(line) }
        }
        if inFence { flushCode() } else { flushProse() }
        return segments
    }

    private static func attributed(from markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }
}
