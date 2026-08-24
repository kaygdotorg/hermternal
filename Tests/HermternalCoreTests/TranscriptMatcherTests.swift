import Foundation
@testable import HermternalCore
import Testing

@Test("find uses token-prefix matching")
func tokenPrefixMatching() {
    #expect(TranscriptMatcher.ranges(in: "prerun run", query: "run") == [7..<10])
}

@Test("find requires every query term and ignores term order")
func multiTermAndIsOrderIndependent() {
    let first = TranscriptMatcher.matches(in: ["A blue bird", "A blue sky", "bird only"], query: "bird blue")
    let second = TranscriptMatcher.matches(in: ["A blue bird", "A blue sky", "bird only"], query: "blue bird")
    #expect(first == [
        TranscriptMatch(messageIndex: 0, range: 2..<6),
        TranscriptMatch(messageIndex: 0, range: 7..<11)
    ])
    #expect(second == first)
}

@Test("find folds case and diacritics")
func caseAndDiacriticInsensitive() {
    #expect(TranscriptMatcher.ranges(in: "CAFÉ café", query: "cafe") == [0..<4, 5..<9])
}

@Test("find keeps overlapping and adjacent word-prefix occurrences")
func overlappingAndAdjacentOccurrences() {
    #expect(TranscriptMatcher.ranges(in: "aa", query: "a aa") == [0..<1, 0..<2])
    #expect(TranscriptMatcher.ranges(in: "aa aa", query: "aa") == [0..<2, 3..<5])
}

@Test("empty and unmatched queries produce no positions")
func emptyAndUnmatchedQueries() {
    #expect(TranscriptMatcher.matches(in: ["anything", "else"], query: "").isEmpty)
    #expect(TranscriptMatcher.matches(in: ["anything", "else"], query: "missing").isEmpty)
    #expect(TranscriptMatcher.matches(in: ["one"], query: "one absent").isEmpty)
}

@Test("matches are ordered by transcript message then position")
func transcriptOrdering() {
    let matches = TranscriptMatcher.matches(
        in: ["zulu alpha alpha", "alpha", "alpha bravo"],
        query: "alpha"
    )
    #expect(matches == [
        TranscriptMatch(messageIndex: 0, range: 5..<10),
        TranscriptMatch(messageIndex: 0, range: 11..<16),
        TranscriptMatch(messageIndex: 1, range: 0..<5),
        TranscriptMatch(messageIndex: 2, range: 0..<5)
    ])
}

@Test("find scans a transcript once before row projection")
func transcriptProjectionScansOnceForLargeTranscripts() {
    let counter = MatcherInvocationCounter()
    TranscriptMatcher.$_scanHook.withValue({ counter.increment() }) {
        for messageCount in [500, 5_000] {
            let messages = (0..<messageCount).map { index in
                index.isMultiple(of: 97)
                    ? "row \(index) target token"
                    : "row \(index) filler"
            }
            let expected = TranscriptMatcher.matches(in: messages, query: "target")
            let rangesByMessage = Dictionary(
                grouping: expected,
                by: \.messageIndex
            ).mapValues { $0.map(\.range) }
            let projected = messages.indices.flatMap { index in
                rangesByMessage[index, default: []].map {
                    TranscriptMatch(messageIndex: index, range: $0)
                }
            }

            #expect(projected == expected)
            #expect(counter.value == (messageCount == 500 ? 1 : 2))
        }
    }
}

@Test("one transcript Find pass invokes its matcher once")
func transcriptFindPassInvokesMatcherOnce() {
    let messages = [
        ChatMessage(role: .user, text: "target"),
        ChatMessage(role: .assistant, text: "other")
    ]
    let counter = MatcherInvocationCounter()
    let matches = TranscriptFindPass.matches(
        in: messages,
        query: "target",
        using: { texts, query in
            counter.increment()
            #expect(texts == ["target", "other"])
            #expect(query == "target")
            return [TranscriptMatch(messageIndex: 0, range: 0..<6)]
        }
    )

    #expect(matches == [TranscriptMatch(messageIndex: 0, range: 0..<6)])
    #expect(counter.value == 1)
    let empty = TranscriptFindPass.matches(
        in: messages,
        query: "   ",
        using: { _, _ in
            counter.increment()
            return []
        }
    )
    #expect(empty.isEmpty)
    #expect(counter.value == 1)
}

private final class MatcherInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
