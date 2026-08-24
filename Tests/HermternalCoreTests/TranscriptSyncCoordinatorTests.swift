import Foundation
import HermternalCore
import Testing

private actor SyncSourceProbe: TranscriptSource {
    private(set) var authoritativeCalls = 0
    private(set) var resumeCalls = 0
    var rows: [JSONValue] = []

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
