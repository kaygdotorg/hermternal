import Foundation
import HermternalCore
import Testing

@Test("reopening an unchanged titled session does not rewrite FTS rows")
func reopeningUnchangedTitledSessionDoesNotRewriteFTSRows() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "HermternalTitleIndex-\(UUID().uuidString)")
    let cache = HistoryCache(directory: root.appending(path: "cache"))
    let index = try SearchIndex(url: root.appending(path: "search.sqlite"))
    let coordinator = SearchIndexReconciliation(cache: cache, index: index)
    let opener = TranscriptOpener(
        source: FixedTitleTranscriptSource(),
        cache: coordinator,
        cacheEnabled: true,
        generations: OpenGenerationController()
    )
    let firstGeneration = opener.generations.begin()
    _ = try #require(await opener.reconcileTerminal(
        sessionID: "session",
        serverTotal: 1,
        currentMessages: [],
        generation: firstGeneration,
        sessionTitle: "Quarterly plan"
    ))
    let firstDigest = try await index.storedDigest(for: "session")

    let secondGeneration = opener.generations.begin()
    _ = try #require(await opener.reconcileTerminal(
        sessionID: "session",
        serverTotal: 1,
        currentMessages: [],
        generation: secondGeneration,
        sessionTitle: "Quarterly plan"
    ))

    #expect(try await index.storedDigest(for: "session") == firstDigest)
    #expect(try await index.indexedMessageCount(sessionID: "session") == 1)
    try await index.disable()
    try? FileManager.default.removeItem(at: root)
}

@Test("retitling a session rewrites FTS rows")
func retitlingSessionRewritesFTSRows() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "HermternalTitleIndex-\(UUID().uuidString)")
    let cache = HistoryCache(directory: root.appending(path: "cache"))
    let index = try SearchIndex(url: root.appending(path: "search.sqlite"))
    let coordinator = SearchIndexReconciliation(cache: cache, index: index)
    let opener = TranscriptOpener(
        source: FixedTitleTranscriptSource(),
        cache: coordinator,
        cacheEnabled: true,
        generations: OpenGenerationController()
    )
    _ = try #require(await opener.reconcileTerminal(
        sessionID: "session",
        serverTotal: 1,
        currentMessages: [],
        generation: opener.generations.begin(),
        sessionTitle: "Quarterly plan"
    ))
    let firstDigest = try await index.storedDigest(for: "session")

    _ = try #require(await opener.reconcileTerminal(
        sessionID: "session",
        serverTotal: 1,
        currentMessages: [],
        generation: opener.generations.begin(),
        sessionTitle: "Annual plan"
    ))

    #expect(try await index.storedDigest(for: "session") != firstDigest)
    #expect(try await index.search("annual", limit: 10).hits.first?.sessionTitle == "Annual plan")
    #expect(try await index.search("quarterly", limit: 10).hits.isEmpty)
    try await index.disable()
    try? FileManager.default.removeItem(at: root)
}

private struct FixedTitleTranscriptSource: TranscriptSource, Sendable {
    func resume(sessionID _: String) async throws -> ResumedTranscript {
        ResumedTranscript(liveSessionID: "live", rows: [])
    }

    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        AuthoritativeTranscript(
            rows: [
                .object([
                    "id": .integer(1),
                    "role": .string("assistant"),
                    "content": .string("The plan is ready.")
                ])
            ],
            serverTotal: 1
        )
    }
}
