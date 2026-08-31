import Foundation
import HermternalCore
import Testing

@Test("terminal reconciliation replaces durable rows but first turns stay provisional")
func terminalReconciliationUsesRESTAuthority() async throws {
    let source = FixtureSource(
        resumed: ResumedTranscript(liveSessionID: "live", rows: []),
        authoritative: AuthoritativeTranscript(rows: [row(id: 9, role: .assistant, text: "authoritative")], serverTotal: 1)
    )
    let cache = HistoryCache(directory: try temporaryDirectory())
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(source: source, cache: cache, cacheEnabled: true, generations: generations)
    let generation = generations.begin()
    let durable = try #require(await opener.reconcileTerminal(
        sessionID: "durable",
        serverTotal: 1,
        currentMessages: [ChatMessage(role: .assistant, text: "live")],
        generation: generation,
        sessionTitle: ""
    ))
    #expect(durable.messages.map(\.text) == ["authoritative"])
    #expect(durable.messages[0].id == .server(ServerMessageID(rawValue: 9)))
    #expect(durable.cacheStore != nil)

    let firstTurn = try #require(await opener.reconcileTerminal(
        sessionID: nil,
        serverTotal: nil,
        currentMessages: [ChatMessage(role: .assistant, text: "live")],
        generation: generation,
        sessionTitle: ""
    ))
    #expect(firstTurn.requiresSessionRefresh)
    #expect(firstTurn.messages[0].id != durable.messages[0].id)
}

@Test("opening uses resume growth metadata without caching resume rows")
func openingUsesResumeGrowthAndRESTAuthority() async throws {
    let source = FixtureSource(
        resumed: ResumedTranscript(
            liveSessionID: "live",
            rows: [row(id: 1, role: .assistant, text: "partial")],
            messageCount: 2
        ),
        authoritative: AuthoritativeTranscript(
            rows: [row(id: 1, role: .assistant, text: "one"), row(id: 2, role: .user, text: "two")],
            serverTotal: 2
        )
    )
    let cache = HistoryCache(directory: try temporaryDirectory())
    let opener = TranscriptOpener(source: source, cache: cache, cacheEnabled: true, generations: OpenGenerationController())
    let result = try #require(await opener.openForInteraction(
        sessionID: "session",
        serverTotal: 1,
        generation: opener.generations.begin(),
        sessionTitle: ""
    ))
    #expect(result.didFetchREST)
    #expect(result.messages.count == 2)
    #expect((await cache.transcript(for: "session"))?.messages.count == 2)
}

@Test("incomplete cache snapshots retry the authoritative REST read")
func incompleteSnapshotRetriesREST() async throws {
    let source = FixtureSource(
        resumed: ResumedTranscript(liveSessionID: "live", rows: [], messageCount: 834),
        authoritative: AuthoritativeTranscript(rows: [], serverTotal: 834)
    )
    let cache = HistoryCache(directory: try temporaryDirectory())
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: "session",
        serverTotal: 834,
        fetchedRows: 500,
        projectedMessages: 500,
        truncated: true,
        fetchedAt: Date()
    )
    _ = await cache.store([ChatMessage(role: .assistant, text: "cached")], snapshot: snapshot, for: "session")
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(source: source, cache: cache, cacheEnabled: true, generations: generations)
    let result = try #require(await opener.openForInteraction(
        sessionID: "session",
        serverTotal: 834,
        generation: generations.begin(),
        sessionTitle: ""
    ))
    #expect(result.didFetchREST)
    #expect(result.messages.isEmpty)
    #expect(await source.authoritativeCalls == 1)
}

@Test("generation changes publish no delayed open result")
func delayedOpenIsSuperseded() async throws {
    let source = FixtureSource(
        resumed: ResumedTranscript(liveSessionID: "live", rows: []),
        authoritative: AuthoritativeTranscript(rows: [], serverTotal: 0),
        resumeDelay: 50_000_000
    )
    let cache = HistoryCache(directory: try temporaryDirectory())
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(source: source, cache: cache, cacheEnabled: false, generations: generations)
    let generation = generations.begin()
    let task = Task {
        await opener.openForInteraction(sessionID: "session", serverTotal: 0, generation: generation, sessionTitle: "")
    }
    try await Task.sleep(nanoseconds: 5_000_000)
    _ = generations.begin()
    #expect(await task.value == nil)
}

@Test("REST failure retains the prior cached transcript")
func restFailureRetainsCache() async throws {
    let source = FixtureSource(
        resumed: ResumedTranscript(liveSessionID: "live", rows: []),
        shouldFailREST: true
    )
    let cache = HistoryCache(directory: try temporaryDirectory())
    let cached = ChatMessage(
        id: .server(ServerMessageID(rawValue: 4)),
        role: .assistant,
        text: "prior"
    )
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: "session",
        serverTotal: 9,
        fetchedRows: 1,
        projectedMessages: 1,
        truncated: false,
        fetchedAt: Date()
    )
    _ = await cache.store([cached], snapshot: snapshot, for: "session")
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(source: source, cache: cache, cacheEnabled: true, generations: generations)
    let result = try #require(await opener.openForInteraction(
        sessionID: "session",
        serverTotal: 10,
        generation: generations.begin(),
        sessionTitle: ""
    ))
    #expect(result.messages.map(\.text) == ["prior"])
    #expect(result.notice != nil)
    #expect((await cache.transcript(for: "session"))?.messages.map(\.text) == ["prior"])
}

@Test("production reducer handles message start delta and complete")
func productionReducerReducesStreamingEvents() {
    var reducer = StreamingEventReducer()
    _ = reducer.reduce(event("message.start"))
    _ = reducer.reduce(event("message.delta", text: "hel"))
    let complete = reducer.reduce(event("message.complete", text: "hello"))
    #expect(complete.messages.map(\.text) == ["hello"])
    #expect(!complete.messages[0].isStreaming)
    #expect(complete.terminal == .complete)
}

@Test("production reducer surfaces nested error text and defaults empty payloads")
func productionReducerSurfacesDeferredErrorText() {
    var reducer = StreamingEventReducer()
    let nestedError = reducer.reduce(GatewayEvent(
        type: "error",
        sessionID: "session",
        payload: .object(["error": .object(["message": .string("Missing model.")])])
    ))
    #expect(nestedError.terminal == .error)
    #expect(nestedError.notice == "Missing model.")

    var fallbackReducer = StreamingEventReducer()
    let emptyError = fallbackReducer.reduce(GatewayEvent(
        type: "error",
        sessionID: "session",
        payload: .object([:])
    ))
    #expect(emptyError.terminal == .error)
    #expect(emptyError.notice == "The agent reported an error.")
}

@Test("prefetch coordinator bounds active work and cancels queued work")
func prefetchConcurrencyAndCancellation() async {
    let coordinator = BoundedPrefetchCoordinator(limit: 2)
    let probe = PrefetchProbe()
    let values = PrefetchValueProbe()
    await coordinator.prefetch(
        Array(0..<8),
        operation: { value in
            probe.enter()
            defer { probe.leave() }
            try? await Task.sleep(nanoseconds: 10_000_000)
            return value
        },
        onResult: { value in
            await values.append(value)
        }
    )
    let deliveredValues = await values.values
    #expect(Set(deliveredValues) == Set(0..<8))
    #expect(deliveredValues.count == 8)

    let canceledProbe = PrefetchProbe()
    let task = Task {
        await coordinator.prefetch(
            Array(0..<8),
            operation: { value in
                canceledProbe.enter()
                defer { canceledProbe.leave() }
                try? await Task.sleep(nanoseconds: 50_000_000)
                return value
            },
            onResult: { _ in }
        )
    }
    try? await Task.sleep(nanoseconds: 5_000_000)
    task.cancel()
    _ = await task.value
    #expect(canceledProbe.started <= 2)
}

private struct FixtureSource: TranscriptSource, Sendable {
    let resumed: ResumedTranscript
    let authoritative: AuthoritativeTranscript
    let resumeDelay: UInt64
    let shouldFailREST: Bool
    let calls: CallCounter

    init(
        resumed: ResumedTranscript,
        authoritative: AuthoritativeTranscript = AuthoritativeTranscript(rows: [], serverTotal: 0),
        resumeDelay: UInt64 = 0,
        shouldFailREST: Bool = false
    ) {
        self.resumed = resumed
        self.authoritative = authoritative
        self.resumeDelay = resumeDelay
        self.shouldFailREST = shouldFailREST
        self.calls = CallCounter()
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        if resumeDelay > 0 { try await Task.sleep(nanoseconds: resumeDelay) }
        return resumed
    }

    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        await calls.increment()
        if shouldFailREST { throw FixtureError.failed }
        return authoritative
    }

    var authoritativeCalls: Int {
        get async { await calls.value }
    }
}

private actor CallCounter {
    private var count = 0
    func increment() { count += 1 }
    var value: Int { count }
}

private final class PrefetchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var active = 0
    private(set) var maximum = 0
    private(set) var started = 0

    func enter() {
        lock.lock(); defer { lock.unlock() }
        started += 1
        active += 1
        maximum = max(maximum, active)
    }

    func leave() {
        lock.lock(); defer { lock.unlock() }
        active -= 1
    }
}
private actor PrefetchValueProbe {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}

private enum FixtureError: Error { case failed }

private func event(_ type: String, text: String? = nil) -> GatewayEvent {
    GatewayEvent(type: type, sessionID: "session", payload: text.map { .object(["text": .string($0)]) })
}

private func row(id: Int64, role: Role, text: String) -> JSONValue {
    .object([
        "id": .integer(id),
        "role": .string(role.rawValue),
        "content": .string(text)
    ])
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "HermternalProduction-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
