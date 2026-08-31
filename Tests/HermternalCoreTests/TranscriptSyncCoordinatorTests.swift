import Foundation
import HermternalCore
import Testing

private actor SyncSourceProbe: TranscriptSource {
    private(set) var authoritativeCalls = 0
    private(set) var resumeCalls = 0
    var rows: [JSONValue] = []

    init(rows: [JSONValue] = []) {
        self.rows = rows
    }
    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        authoritativeCalls += 1
        return AuthoritativeTranscript(rows: rows, serverTotal: 0)
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        resumeCalls += 1
        return ResumedTranscript(liveSessionID: "live", rows: [])
    }
}

private actor SyncResultCollector {
    private(set) var results: [TranscriptSyncResult] = []

    func append(_ result: TranscriptSyncResult) {
        results.append(result)
    }
}

private func syncTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hermternal-sync-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test("sync returns complete cache hits without invoking resume or REST")
func syncCacheHitDoesNotUseNetwork() async throws {
    let directory = try syncTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let snapshot = CacheFirstOpenPolicy.snapshot(
        sessionID: "cached",
        rows: [],
        projectedMessages: 0,
        serverTotal: 0
    )
    _ = await cache.storeForWarming(
        [],
        snapshot: snapshot,
        title: "Cached",
        for: "cached",
        expectedEpoch: nil
    )
    let source = SyncSourceProbe()
    let collector = SyncResultCollector()
    await TranscriptSyncCoordinator(concurrency: 2).reconcile(
        [TranscriptSyncRequest(id: "cached", serverTotal: 0, title: "Cached")],
        cache: cache,
        source: source,
        onResult: { result in
            await collector.append(result)
        }
    )
    let results = await collector.results

    #expect(results.map(\.id) == ["cached"])
    #expect(await source.authoritativeCalls == 0)
    #expect(await source.resumeCalls == 0)
}

@Test("forced sync uses authoritative history and persists through warming seam")
func forcedSyncUsesAuthoritativeHistory() async throws {
    let directory = try syncTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let source = SyncSourceProbe()
    let collector = SyncResultCollector()
    await TranscriptSyncCoordinator().reconcile(
        [TranscriptSyncRequest(id: "fresh", serverTotal: 0, title: "Fresh", forceRefresh: true)],
        cache: cache,
        source: source,
        onResult: { result in
            await collector.append(result)
        }
    )
    let results = await collector.results

    #expect(results.map(\.id) == ["fresh"])
    #expect(results.first?.cacheStore != nil)
    #expect(await source.authoritativeCalls == 1)
    #expect(await source.resumeCalls == 0)
    #expect((await cache.readForWarming(for: "fresh")).transcript?.snapshot?.sessionID == "fresh")
}

@Test("sync merges interleaved durable wire rows before turn projection")
func syncMergesInterleavedDurableWireRows() async throws {
    let directory = try syncTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let source = SyncSourceProbe(rows: [
        .object([
            "id": .number(100),
            "role": .string("assistant"),
            "text": .string("first answer"),
            "turn_id": .string("first")
        ]),
        .object([
            "id": .number(200),
            "role": .string("assistant"),
            "text": .string("second answer"),
            "turn_id": .string("second")
        ]),
        .object([
            "id": .number(101),
            "role": .string("tool"),
            "text": .string(""),
            "display_kind": .string("tool_event"),
            "tool_call_id": .string("first-tool"),
            "tool_name": .string("shell"),
            "tool_status": .string("completed"),
            "turn_id": .string("first")
        ]),
        .object([
            "id": .number(102),
            "role": .string("assistant"),
            "text": .string(""),
            "reasoning": .string("first reasoning"),
            "turn_id": .string("first")
        ]),
        .object([
            "id": .number(201),
            "role": .string("tool"),
            "text": .string(""),
            "display_kind": .string("tool_event"),
            "tool_call_id": .string("second-tool"),
            "tool_name": .string("shell"),
            "tool_status": .string("completed"),
            "turn_id": .string("second")
        ])
    ])
    let collector = SyncResultCollector()

    await TranscriptSyncCoordinator().reconcile(
        [TranscriptSyncRequest(id: "interleaved", serverTotal: 5, title: "Interleaved", forceRefresh: true)],
        cache: cache,
        source: source,
        onResult: { result in
            await collector.append(result)
        }
    )
    let store = try await cache.pagedStore(for: "interleaved")
    let turns = try await store.turnPage(TranscriptTurnPageRequest(maximumRows: 10))

    #expect(turns.turns.map(\.answer) == ["first answer", "second answer"])
    #expect(turns.turns[0].reasoning?.text == "first reasoning")
    #expect(turns.turns.map { $0.tools.count } == [1, 1])
    #expect(turns.turns.allSatisfy { !$0.answer.isEmpty })
    #expect((await collector.results).count == 1)
}
