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
