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
