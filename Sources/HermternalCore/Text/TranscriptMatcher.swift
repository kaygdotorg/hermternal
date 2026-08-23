import Foundation

/// One prefix-token occurrence in a transcript message.
///
/// `range` uses UTF-16 offsets into the original message text. UTF-16 offsets
/// are stable across the Foundation and SwiftUI boundary and let a renderer
/// map a match onto either a plain `Text` value or a parsed markdown segment.
public struct TranscriptMatch: Hashable, Sendable {
    public let messageIndex: Int
    public let range: Range<Int>

    public init(messageIndex: Int, range: Range<Int>) {
        self.messageIndex = messageIndex
        self.range = range
    }
}

/// Local, synchronous find semantics shared by transcript UIs and tests.
///
/// Every non-empty whitespace-delimited query term is a token prefix: its
/// occurrence must begin at a word boundary. A message contributes occurrences
/// only when it contains at least one match for every term (AND semantics);
/// all term occurrences are returned in transcript order. Matching ignores
/// case and diacritics while retaining the global FTS word-prefix behavior.
public enum TranscriptMatcher {
    @TaskLocal
    internal static var _scanHook: (@Sendable () -> Void)?

    public static func matches(in messages: [String], query: String) -> [TranscriptMatch] {
        let terms = normalizedTerms(query)
        guard !terms.isEmpty else { return [] }
        _scanHook?()

        return messages.enumerated().flatMap { messageIndex, text in
            matches(in: text, terms: terms).map {
                TranscriptMatch(messageIndex: messageIndex, range: $0)
            }
        }
    }

    /// Returns UTF-16 ranges for one message. This overload is useful when a
    /// renderer needs to highlight a parsed segment rather than raw markdown.
    public static func ranges(in text: String, query: String) -> [Range<Int>] {
        let terms = normalizedTerms(query)
        guard !terms.isEmpty else { return [] }
        return matches(in: text, terms: terms)
    }

    private struct NormalizedText {
        let characters: [Character]
        let sourceRanges: [Range<Int>]
    }

    private static func normalizedTerms(_ query: String) -> [[Character]] {
        query.split(whereSeparator: \.isWhitespace).compactMap { term in
            let normalized = normalize(String(term)).characters
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func matches(in text: String, terms: [[Character]]) -> [Range<Int>] {
        let normalized = normalize(text)
        guard !normalized.characters.isEmpty else { return [] }

        var termRanges = Set<Range<Int>>()
        var hasAllTerms = true
        for term in terms {
            let occurrences = occurrences(of: term, in: normalized)
            guard !occurrences.isEmpty else {
                hasAllTerms = false
                break
            }
            for occurrence in occurrences {
                termRanges.insert(
                    normalized.sourceRanges[occurrence.lowerBound].lowerBound
                        ..< normalized.sourceRanges[occurrence.upperBound - 1].upperBound
                )
            }
        }
        guard hasAllTerms else { return [] }
        return termRanges.sorted { lhs, rhs in
            if lhs.lowerBound != rhs.lowerBound { return lhs.lowerBound < rhs.lowerBound }
            if lhs.upperBound != rhs.upperBound { return lhs.upperBound < rhs.upperBound }
            return false
        }
    }

    private static func occurrences(of term: [Character], in text: NormalizedText) -> [Range<Int>] {
        guard !term.isEmpty, text.characters.count >= term.count else { return [] }
        var result: [Range<Int>] = []
        for start in 0...(text.characters.count - term.count) {
            let end = start + term.count
            guard Array(text.characters[start..<end]) == term else { continue }
            if start > 0, isTokenCharacter(text.characters[start - 1]) { continue }
            result.append(start..<end)
        }
        return result
    }

    private static func normalize(_ text: String) -> NormalizedText {
        var characters: [Character] = []
        var sourceRanges: [Range<Int>] = []
        var utf16Offset = 0

        for sourceCharacter in text {
            let sourceLength = String(sourceCharacter).utf16.count
            let sourceRange = utf16Offset..<(utf16Offset + sourceLength)
            let folded = String(sourceCharacter).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            )
            for character in folded {
                characters.append(character)
                sourceRanges.append(sourceRange)
            }
            utf16Offset += sourceLength
        }
        return NormalizedText(characters: characters, sourceRanges: sourceRanges)
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_"
        }
    }
}
