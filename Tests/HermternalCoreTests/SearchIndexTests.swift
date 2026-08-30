import Foundation
@testable import HermternalCore
import Testing
@Test("query compiler quotes every token and joins AND")
func searchCompilerIsLiteral() {
    #expect(SearchIndex.compile(query: "alpha OR beta") == "\"alpha\"* AND \"OR\"* AND \"beta\"*")
    #expect(SearchIndex.compile(query: "  ") == "")
    #expect(SearchIndex.compile(query: "a\"b") == "\"a\"\"b\"*")
}

@Test("FTS prefix, AND, case, and diacritics")
func ftsMatchingSemantics() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "", documents: [
        document(1, "The café has a cacao aroma."),
        document(2, "An unrelated apple sentence."),
        document(3, "cafe racer notes")
    ]))
    #expect((try await index.search("caf", limit: 10)).hits.map(\.messageID.rawValue).sorted() == [1, 3])
    #expect((try await index.search("café aroma", limit: 10)).hits.map(\.messageID.rawValue) == [1])
    #expect(try await index.search("aro", limit: 10).hits.count == 1)
    #expect(try await index.search("afé", limit: 10).hits.isEmpty)
}

@Test("title receives a stronger BM25 weight")
func titleOutranksRepeatedBody() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "", documents: [
        document(1, "needle needle needle needle needle"),
        document(2, "needle")
    ]))
    // Each document's title is indexed from the session snapshot. Replace the
    // second session to make the title-vs-body distinction explicit.
    try await index.replace(SearchSessionSnapshot(sessionID: "title", title: "needle", documents: [document(3, "ordinary body")]))
    let hits = try await index.search("needle", limit: 10).hits
    #expect(hits.first?.messageID.rawValue == 3)
}

@Test("snippets retain UI highlighting delimiters")
func snippetsHaveDelimiters() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "", documents: [document(1, "a distinctive zebra phrase")]))
    let hit = try #require(try await index.search("zebra", limit: 10).hits.first)
    #expect(hit.excerpt.contains("⟦"))
    #expect(hit.excerpt.contains("⟧"))
}

@Test("replace is digest-aware and title-only changes invalidate rows")
func replaceAndTitleChange() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let docs = [document(1, "body")]
    let first = SearchSessionSnapshot(sessionID: "s", title: "old title", documents: docs)
    try await index.replace(first)
    let digest = try await index.storedDigest(for: "s")
    try await index.replace(first)
    #expect(try await index.storedDigest(for: "s") == digest)
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "new title", documents: docs))
    #expect(try await index.search("new", limit: 10).hits.first?.sessionTitle == "new title")
    #expect(try await index.search("old", limit: 10).hits.isEmpty)
}

@Test("remove, clear, disable, and recreate")
func lifecycleOperations() async throws {
    let index = try makeIndex()
    let url = index.url
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "title", documents: [document(1, "body")], truncated: true))
    #expect(try await index.pendingIndexingSessionCount() == 0)
    #expect(try await index.truncatedSessionCount() == 1)
    try await index.remove(sessionID: "s")
    #expect(try await index.pendingIndexingSessionCount() == 0)
    #expect(try await index.truncatedSessionCount() == 0)
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "title", documents: [document(1, "body")]))
    try await index.clear()
    #expect(try await index.indexedMessageCount() == 0)
    try await index.disable()
    #expect(await index.isDisabled())
    let recreated = try SearchIndex(url: url)
    #expect(try await recreated.indexedMessageCount() == 0)
    try await recreated.disable()
    removeIndex(url)
}

@Test("schema mismatch deterministically rebuilds")
func schemaVersionRebuild() async throws {
    let url: URL
    do {
        let index = try makeIndex()
        url = index.url
        try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "title", documents: [document(1, "body")]))
        try await index._setSchemaVersionForTesting(999)
    }
    // Deinitialization closes the connection but deliberately does not delete
    // the database, so reopening observes and rebuilds the wrong metadata.
    let recreated = try SearchIndex(url: url)
    #expect(try await recreated.indexedMessageCount() == 0)
    try await recreated.disable()
    removeIndex(url)
}

@Test("truncated sessions are reported independently of row limit")
func truncationMetadata() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.replace(SearchSessionSnapshot(sessionID: "short", title: "", documents: [document(1, "needle")], truncated: true))
    try await index.replace(SearchSessionSnapshot(sessionID: "complete", title: "", documents: [document(2, "needle")]))
    let results = try await index.search("needle", limit: 1)
    #expect(results.hits.count == 1)
    #expect(results.pendingIndexingSessions == 0)
    #expect(results.truncatedSessions == 1)
}

@Test("unwarmed sessions are reported as pending indexing")
func unwarmedSessionsArePendingIndexing() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.replace(SearchSessionSnapshot(
        sessionID: "warmed",
        title: "",
        documents: [document(1, "needle")]
    ))
    try await index.markUnwarmed(sessionIDs: ["cold"])

    let results = try await index.search("needle", limit: 10)
    #expect(results.pendingIndexingSessions == 1)
    #expect(results.truncatedSessions == 0)
}

@Test("rapid queries are latest-wins and recover after cancellation")
func latestWinsQueries() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let documents = (0..<500).map { document(Int64($0), String(repeating: "common ", count: 8) + " rare\($0)") }
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "", documents: documents))

    let gate = QueryStartGate()
    await index._setQueryStartHook { gate.queryStarted() }
    let old = Task { try? await index.search("common", limit: 100) }
    await gate.waitUntilStarted()
    await index._setQueryStartHook(nil)

    let newestTask = Task { try? await index.search("rare499", limit: 10) }
    gate.release()
    let newest = try #require(await newestTask.value)
    #expect(newest.hits.first?.messageID.rawValue == 499)
    _ = await old.value
    let recovered = try await index.search("rare1", limit: 10)
    #expect(recovered.hits.first?.messageID.rawValue == 1)
}

@Test("rapid search, replace, disable, and recreate keeps lifecycle serialized")
func lifecycleRaceStress() async throws {
    for iteration in 0..<20 {
        let index = try makeIndex()
        let url = index.url
        try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "old", documents: [document(1, "common old")]))
        let gate = QueryStartGate()
        await index._setQueryStartHook { gate.queryStarted() }
        let query = Task { try? await index.search("common", limit: 10) }
        await gate.waitUntilStarted()
        await index._setQueryStartHook(nil)
        let replacement = Task {
            try? await index.replace(SearchSessionSnapshot(sessionID: "s", title: "replacement", documents: [document(3, "replacement")]))
        }
        let disable = Task { try? await index.disable() }
        gate.release()
        _ = await query.value
        _ = await replacement.value
        _ = await disable.value

        let recreated = try SearchIndex(url: url)
        try await recreated.replace(SearchSessionSnapshot(sessionID: "s", title: "new-\(iteration)", documents: [document(2, "fresh")]))
        let result = try await recreated.search("fresh", limit: 10)
        #expect(result.hits.first?.messageID.rawValue == 2)
        try await recreated.disable()
        removeIndex(url)
    }
}

@Test("warm benchmark reports timing without a brittle assertion")
func warmBenchmarkReport() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let documents = (0..<900).map { document(Int64($0), "benchmark common text row \($0)") }
    try await index.replace(SearchSessionSnapshot(sessionID: "bench", title: "", documents: documents))
    _ = try await index.search("common", limit: 100)
    let start = ContinuousClock.now
    _ = try await index.search("common", limit: 100)
    let elapsed = start.duration(to: .now)
    print("SearchIndex warm benchmark: \(elapsed)")
}

@Test("paged replacement ingests incrementally and preserves digest")
func pagedReplacementIngestsPages() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let pages = AsyncThrowingStream<SearchDocumentPage, Error> { continuation in
        continuation.yield(SearchDocumentPage(documents: [document(1, "first needle")]))
        continuation.yield(SearchDocumentPage(documents: [document(2, "second needle")]))
        continuation.finish()
    }
    try await index.replacePaged(sessionID: "paged", title: "Paged", truncated: false, pages: pages)
    #expect(try await index.indexedMessageCount(sessionID: "paged") == 2)
    #expect(try await index.search("needle", limit: 10).hits.count == 2)
    let firstDigest = try await index.storedDigest(for: "paged")
    try await index.replacePaged(sessionID: "paged", title: "Paged", truncated: false, pages: AsyncThrowingStream { continuation in
        continuation.yield(SearchDocumentPage(documents: [document(1, "first needle"), document(2, "second needle")]))
        continuation.finish()
    })
    #expect(try await index.storedDigest(for: "paged") == firstDigest)
}

private func document(_ id: Int64, _ body: String, role: Role = .user) -> SearchDocument {
    SearchDocument(messageID: ServerMessageID(rawValue: id), body: body, role: role)
}

private func makeIndex() throws -> SearchIndex {
    let url = FileManager.default.temporaryDirectory.appending(path: "HermternalSearch-\(UUID().uuidString).sqlite")
    return try SearchIndex(url: url)
}

private func removeIndex(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
}

private final class QueryStartGate: @unchecked Sendable {
    private let state = NSLock()
    private var didStart = false
    private var waiter: CheckedContinuation<Void, Never>?
    private let releaseGate = DispatchSemaphore(value: 0)

    func queryStarted() {
        state.lock()
        didStart = true
        let waiter = self.waiter
        self.waiter = nil
        state.unlock()
        waiter?.resume()
        releaseGate.wait()
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.lock()
            if didStart {
                state.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                state.unlock()
            }
        }
    }

    func release() {
        releaseGate.signal()
    }
}

