import Foundation
import HermternalCore
import Testing

@Test("REST identity is durable and repeatable")
func restIdentityIsDurable() {
    let rows = [historyRow(id: 42, timestamp: .string("2026-08-22T10:20:30Z"), role: .assistant, text: "hello")]
    let first = ChatMessage.projectREST(historyRows: rows)
    let second = ChatMessage.projectREST(historyRows: rows)

    #expect(first.count == 1)
    #expect(first[0].id == .server(ServerMessageID(rawValue: 42)))
    #expect(first.map(\.id) == second.map(\.id))
}

@Test("timestamps decode from ISO and epoch REST values")
func timestampsDecodeLeniently() throws {
    let iso = ChatMessage.projectREST(historyRows: [
        historyRow(id: 1, timestamp: .string("2026-08-22T10:20:30Z"), role: .user, text: "iso")
    ])[0].timestamp
    let epoch = ChatMessage.projectREST(historyRows: [
        historyRow(id: 2, timestamp: .number(1_750_000_000), role: .assistant, text: "epoch")
    ])[0].timestamp
    #expect(iso != nil)
    #expect(epoch == Date(timeIntervalSince1970: 1_750_000_000))
}

@Test("live rows remain provisional")
func liveRowsAreProvisional() {
    let message = ChatMessage(role: .assistant, text: "streaming", isStreaming: true)
    guard case .provisional = message.id else { Issue.record("live row was assigned a server identity"); return }
}

@Test("cache round trip preserves server identity and timestamps")
func cacheRoundTripPreservesIdentity() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
    let message = ChatMessage(
        id: .server(ServerMessageID(rawValue: 99)),
        role: .user,
        text: "cached",
        timestamp: timestamp
    )
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: "session",
        serverTotal: 1,
        fetchedRows: 1,
        projectedMessages: 1,
        truncated: false,
        fetchedAt: timestamp
    )

    _ = await cache.store([message], snapshot: snapshot, for: "session")
    let loaded = try #require(await cache.transcript(for: "session"))
    #expect(loaded.messages[0].id == message.id)
    #expect(loaded.messages[0].timestamp == timestamp)
    #expect(loaded.snapshot?.sessionID == snapshot.sessionID)
    #expect(loaded.snapshot?.fetchedRows == snapshot.fetchedRows)
}

@Test("incomplete snapshots request another authoritative read")
func incompleteSnapshotRequestsREST() {
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: "session",
        serverTotal: 834,
        fetchedRows: 500,
        projectedMessages: 480,
        truncated: true,
        fetchedAt: Date()
    )
    #expect(CacheFirstOpenPolicy.shouldFetchREST(snapshot: snapshot, serverTotal: 834))
}

@Test("complete snapshots refetch only when resume or server totals grow")
func cacheOpenRefetchPolicy() {
    #expect(CacheFirstOpenPolicy.shouldFetchREST(snapshot: nil, serverTotal: 0))
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: "session",
        serverTotal: 10,
        fetchedRows: 10,
        projectedMessages: 10,
        truncated: false,
        fetchedAt: Date()
    )
    #expect(!CacheFirstOpenPolicy.shouldFetchREST(
        snapshot: snapshot,
        serverTotal: 10,
        resumeMessageCount: 10
    ))
    #expect(CacheFirstOpenPolicy.shouldFetchREST(snapshot: snapshot, serverTotal: 11))
    #expect(CacheFirstOpenPolicy.shouldFetchREST(
        snapshot: snapshot,
        serverTotal: 10,
        resumeMessageCount: 11
    ))
}

@Test("prefetch coordinator delivers completed items incrementally")
func prefetchIsIncremental() async {
    let coordinator = BoundedPrefetchCoordinator(limit: 2)
    let delivered = PrefetchValueCollector()
    await coordinator.prefetch(
        [0, 1, 2, 3],
        operation: { value in
            try? await Task.sleep(for: .milliseconds(value == 0 ? 20 : 1))
            return value * 2
        },
        onResult: { value in
            await delivered.append(value)
        }
    )
    let values = await delivered.values
    #expect(Set(values) == Set([0, 2, 4, 6]))
    #expect(values.count == 4)
}

@Test("NDJSON parser and accumulator preserve frame boundaries")
func streamingSeamsAreDeterministic() {
    var parser = NDJSONFrameParser()
    #expect(parser.append("{\"a\":1}\n{\"b\":").count == 1)
    #expect(parser.append("2}\n").count == 1)
    var accumulator = StreamingTextAccumulator()
    accumulator.start()
    accumulator.append("hel")
    accumulator.append("lo")
    #expect(accumulator.complete("authoritative") == "authoritative")
    #expect(!accumulator.isStreaming)
}

private func historyRow(id: Int64, timestamp: JSONValue, role: Role, text: String) -> JSONValue {
    .object([
        "id": .number(Double(id)),
        "timestamp": timestamp,
        "role": .string(role.rawValue),
        "content": .string(text)
    ])
}
private actor PrefetchValueCollector {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
