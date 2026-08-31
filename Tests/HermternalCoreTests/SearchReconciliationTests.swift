import Foundation
@testable import HermternalCore
import Testing

@Test("reconciliation stores only server identities and removes rows")
func reconciliationStoresAndRemoves() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "HermternalReconcile-\(UUID().uuidString)")
    let cache = HistoryCache(directory: root.appending(path: "cache"))
    let index = try SearchIndex(url: root.appending(path: "search.sqlite"))
    let coordinator = SearchIndexReconciliation(cache: cache, index: index)
    let snapshot = AuthoritativeTranscriptSnapshot(sessionID: "s", serverTotal: 2, fetchedRows: 2, projectedMessages: 2, truncated: false, fetchedAt: Date())
    _ = await coordinator.store([
        ChatMessage(id: .provisional(UUID()), role: .assistant, text: "live only"),
        ChatMessage(id: .server(ServerMessageID(rawValue: 7)), role: .user, text: "durable needle")
    ], snapshot: snapshot, title: "Chat", for: "s")
    let removal = await coordinator.remove(sessionID: "s")
    #expect(removal.cache.succeeded)
    #expect(removal.index.succeeded)
    #expect(try await index.indexedMessageCount(sessionID: "s") == 0)
    try await index.disable()
    try? FileManager.default.removeItem(at: root)
}

@Test("paged reconciliation indexes a complete long message once")
func reconciliationIndexesLongPagedMessage() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "HermternalReconcile-\(UUID().uuidString)")
    let cache = HistoryCache(directory: root.appending(path: "cache"))
    let index = try SearchIndex(url: root.appending(path: "search.sqlite"))
    let coordinator = SearchIndexReconciliation(cache: cache, index: index)
    let text = "beginning-needle " + String(repeating: "x", count: 600) + " middle-needle " + String(repeating: "y", count: 600) + " ending-needle"
    let snapshot = AuthoritativeTranscriptSnapshot(sessionID: "long", serverTotal: 1, fetchedRows: 1, projectedMessages: 1, truncated: false, fetchedAt: Date())
    _ = await coordinator.store(
        [ChatMessage(id: .server(ServerMessageID(rawValue: 11)), role: .user, text: text)],
        snapshot: snapshot,
        title: "Long",
        for: "long"
    )

    for term in ["beginning-needle", "middle-needle", "ending-needle"] {
        #expect(try await index.search(term, limit: 10).hits.first?.messageID.rawValue == 11)
    }
    try await index.disable()
    try? FileManager.default.removeItem(at: root)
}

@Test("search replay loads pages only on consumer demand")
func searchReplayAppliesBackpressure() async throws {
    let counter = ReplayLoadCounter()
    let stream = SearchReplayStream.demandDriven {
        let load = await counter.load()
        return load <= 2 ? SearchDocumentPage(documents: []) : nil
    }
    var iterator = stream.makeAsyncIterator()

    _ = try await iterator.next()
    await Task.yield()
    #expect(await counter.count == 1)

    _ = try await iterator.next()
    #expect(await counter.count == 2)
}

@Test("warming reconciliation indexes without retaining cache payload")
func warmingReconciliationDoesNotPopulateCacheMemory() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "HermternalReconcile-\(UUID().uuidString)")
    let cache = HistoryCache(directory: root.appending(path: "cache"))
    let index = try SearchIndex(url: root.appending(path: "search.sqlite"))
    let coordinator = SearchIndexReconciliation(cache: cache, index: index)
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: "s",
        serverTotal: 1,
        fetchedRows: 1,
        projectedMessages: 1,
        truncated: false,
        fetchedAt: Date()
    )
    _ = await coordinator.storeForWarming(
        [ChatMessage(id: .server(ServerMessageID(rawValue: 1)), role: .user, text: "needle")],
        snapshot: snapshot,
        title: "Chat",
        for: "s"
    )
    #expect(await cache.memoryEntryCount() == 0)
    #expect(try await index.indexedMessageCount(sessionID: "s") == 1)
    try await index.disable()
    try? FileManager.default.removeItem(at: root)
}

@Test("stale epoch reconciliation does not write")
func staleEpochReconciliationDoesNotWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "HermternalReconcile-\(UUID().uuidString)")
    let cache = HistoryCache(directory: root.appending(path: "cache"))
    let index = try SearchIndex(url: root.appending(path: "search.sqlite"))
    let coordinator = SearchIndexReconciliation(cache: cache, index: index)
    let snapshot = AuthoritativeTranscriptSnapshot(sessionID: "s", serverTotal: 1, fetchedRows: 1, projectedMessages: 1, truncated: false, fetchedAt: Date())
    _ = await coordinator.store([ChatMessage(id: .server(ServerMessageID(rawValue: 1)), role: .user, text: "old")], snapshot: snapshot, title: "Chat", for: "s")
    let read = await cache.read(for: "s")
    #expect(try await index.indexedMessageCount() == 1)
    #expect(await cache.clear())
    #expect(await coordinator.reconcile(sessionID: "s", title: "Chat", expectedEpoch: read.epoch) == false)
    #expect(try await index.indexedMessageCount() == 1)
    try await index.disable()
    try? FileManager.default.removeItem(at: root)
}

@Test("index failure does not make cache persistence fail")
func indexFailureLeavesCacheAuthoritative() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "HermternalReconcile-\(UUID().uuidString)")
    let cache = HistoryCache(directory: root.appending(path: "cache"))
    let index = try SearchIndex(url: root.appending(path: "search.sqlite"))
    let coordinator = SearchIndexReconciliation(cache: cache, index: index)
    try await index.disable()
    let snapshot = AuthoritativeTranscriptSnapshot(sessionID: "s", serverTotal: 1, fetchedRows: 1, projectedMessages: 1, truncated: false, fetchedAt: Date())
    let result = await coordinator.store([ChatMessage(id: .server(ServerMessageID(rawValue: 1)), role: .user, text: "durable")], snapshot: snapshot, title: "Chat", for: "s")
    #expect(result.addedEntry)
    #expect(await cache.messages(for: "s")?.first?.text == "durable")
    let removal = await coordinator.remove(sessionID: "s")
    #expect(removal.cache.succeeded)
    #expect(!removal.index.succeeded)

    #expect(await coordinator.isDegraded())
    try? FileManager.default.removeItem(at: root)
}

@Test("diversity gives each conversation a turn and counts pending sessions")
func diversityAndPendingCorpus() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "HermternalReconcile-\(UUID().uuidString)")
    let cache = HistoryCache(directory: root.appending(path: "cache"))
    let index = try SearchIndex(url: root.appending(path: "search.sqlite"))
    let coordinator = SearchIndexReconciliation(cache: cache, index: index)
    let makeSnapshot: (String) -> AuthoritativeTranscriptSnapshot = { id in
        AuthoritativeTranscriptSnapshot(sessionID: id, serverTotal: nil, fetchedRows: 4, projectedMessages: 4, truncated: false, fetchedAt: Date())
    }
    _ = await coordinator.store((1...4).map { ChatMessage(id: .server(ServerMessageID(rawValue: Int64($0))), role: .user, text: "common a\($0)") }, snapshot: makeSnapshot("a"), title: "A", for: "a")
    _ = await coordinator.store([ChatMessage(id: .server(ServerMessageID(rawValue: 9)), role: .assistant, text: "common b")], snapshot: makeSnapshot("b"), title: "B", for: "b")
    _ = await coordinator.reconcile(validIDs: ["a", "b", "cold"])
    let results = try await index.search("common", limit: 5)
    #expect(results.hits.prefix(2).map(\.location.sessionID).sorted() == ["a", "b"])
    #expect(results.pendingIndexingSessions == 1)
    #expect(results.truncatedSessions == 0)
    try await index.disable()
    try? FileManager.default.removeItem(at: root)
}
@Test("stale paged revision does not reach the search index")
func stalePagedRevisionRemainsCacheAndSearchNoOp() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "HermternalReconcile-\(UUID().uuidString)")
    let cache = HistoryCache(directory: root.appending(path: "cache"))
    let index = try SearchIndex(url: root.appending(path: "search.sqlite"))
    let coordinator = SearchIndexReconciliation(cache: cache, index: index)
    let row: (String, UInt64) -> JSONValue = { text, revision in
        .object([
            "id": .integer(12),
            "role": .string(Role.user.rawValue),
            "content": .string(text),
            "revision": .integer(Int64(revision)),
            "timestamp": .string("2024-01-01T00:00:00Z")
        ])
    }
    _ = try await coordinator.appendTranscriptPage(
        TranscriptMessagePage(messages: [row("new revision", 2)], offset: 0),
        title: "Revisions",
        for: "revisions"
    )
    try await index._resetPersistentMutationCount()
    let stale = try await coordinator.appendTranscriptPage(
        TranscriptMessagePage(messages: [row("old revision", 1)], offset: 0),
        title: "Revisions",
        for: "revisions"
    )

    let cached = try await cache.transcriptPage(
        for: "revisions",
        request: TranscriptPageRequest(maximumBytes: 1_024, maximumRows: 10)
    )
    #expect(stale.messageCount == 1)
    #expect(cached.rows.first?.text == "new revision")
    #expect(try await index.search("old", limit: 10).hits.isEmpty)
    #expect(try await index._persistentMutationCount() == 0)
    try await index._resetPersistentMutationCount()
    try await index.replace(SearchSessionSnapshot(
        sessionID: "revisions",
        title: "Revisions",
        documents: [SearchDocument(
            messageID: ServerMessageID(rawValue: 12),
            body: "new revision",
            role: .user,
            timestamp: Date(timeIntervalSince1970: 1_704_067_200)
        )]
    ))
    #expect(try await index._persistentMutationCount() == 0)
    #expect(try await index.search("new", limit: 10).hits.first?.messageID.rawValue == 12)
    try await index.disable()
    try? FileManager.default.removeItem(at: root)
}

private actor ReplayLoadCounter {
    private(set) var count = 0

    func load() -> Int {
        count += 1
        return count
    }
}
