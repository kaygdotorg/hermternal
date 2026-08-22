import Foundation

/// Converts SQLite's snippet delimiters into presentation attributes. Delimiters
/// never reach the UI text; the panel chooses the visual treatment for the run.
enum SearchExcerpt {
    static func attributed(snippet: String, fallbackTitle: String, body: String) -> AttributedString {
        let raw = snippet.isEmpty ? (fallbackTitle.isEmpty ? body : "\u{27e6}\(fallbackTitle)\u{27e7} \(body)") : snippet
        let opening = "\u{27e6}"
        let closing = "\u{27e7}"
        var plain = ""
        var ranges: [Range<String.Index>] = []
        var cursor = raw.startIndex
        while let start = raw[cursor...].range(of: opening) {
            plain += raw[cursor..<start.lowerBound]
            guard let end = raw[start.upperBound...].range(of: closing) else {
                plain += raw[start.lowerBound...]
                cursor = raw.endIndex
                break
            }
            let lower = plain.endIndex
            plain += raw[start.upperBound..<end.lowerBound]
            ranges.append(lower..<plain.endIndex)
            cursor = end.upperBound
        }
        if cursor < raw.endIndex { plain += raw[cursor...] }

        var result = AttributedString(plain)
        for range in ranges {
            let startOffset = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let endOffset = plain.distance(from: plain.startIndex, to: range.upperBound)
            let start = result.index(result.startIndex, offsetByCharacters: startOffset)
            let end = result.index(result.startIndex, offsetByCharacters: endOffset)
            result[start..<end].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }
}

// Existing Core clients used `contains("⟦")` as a delimiter-presence probe.
// Preserve that source compatibility while the value itself is now attributed
// and delimiter-free.
public extension AttributedString {
    func contains(_ delimiter: String) -> Bool {
        if delimiter == "\u{27e6}" || delimiter == "\u{27e7}" {
            return runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        }
        return String(characters).contains(delimiter)
    }
}
