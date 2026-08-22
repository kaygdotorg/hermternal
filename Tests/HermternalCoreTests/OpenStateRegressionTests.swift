import Foundation
import HermternalCore
import Testing

@Test("known totals make exactly 500 rows complete")
func exactlyFiveHundredRowsUseKnownTotal() {
    let rows = (0..<500).map { openStateRow(id: Int64($0)) }
    let complete = CacheFirstOpenPolicy.snapshot(
        sessionID: "session",
        rows: rows,
        projectedMessages: 500,
        serverTotal: 500
    )
    let growing = CacheFirstOpenPolicy.snapshot(
        sessionID: "session",
        rows: rows,
        projectedMessages: 500,
        serverTotal: 501
    )
    #expect(!complete.truncated)
    #expect(growing.truncated)
    #expect(CacheFirstOpenPolicy.shouldFetchREST(snapshot: complete, serverTotal: 501))
}

@Test("cache phase arrives before suspended resume")
func cachedPhasePrecedesResume() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let cached = ChatMessage(role: .assistant, text: "cached")
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: "session",
        serverTotal: 1,
        fetchedRows: 1,
        projectedMessages: 1,
        truncated: false,
        fetchedAt: Date()
    )
    _ = await cache.store([cached], snapshot: snapshot, for: "session")

    let source = OpenStateSuspendedSource()
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(
        source: source,
        cache: cache,
        cacheEnabled: true,
        generations: generations
    )
    let generation = generations.begin()
    var phases = opener.openPhases(
        sessionID: "session",
        serverTotal: 1,
        generation: generation,
        sessionTitle: ""
    ).makeAsyncIterator()

    let first = try #require(await phases.next())
    #expect(first.isCachedPhase)
    #expect(first.messages.map(\.text) == ["cached"])
    while !(await source.resumeStarted) {
        await Task.yield()
    }
    #expect(await source.authoritativeCalls == 0)

    await source.finishResume(.init(liveSessionID: "live", rows: []))
    let final = try #require(await phases.next())
    #expect(final.liveSessionID == "live")
    #expect(final.messages.map(\.text) == ["cached"])
    #expect(await phases.next() == nil)
}

@Test("a cache miss emits an empty provisional phase")
func cacheMissEmitsEmptyPhase() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = OpenStateSuspendedSource(suspendResume: false)
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(
        source: source,
        cache: HistoryCache(directory: directory),
        cacheEnabled: true,
        generations: generations
    )
    let generation = generations.begin()
    var phases = opener.openPhases(
        sessionID: "session",
        serverTotal: 1,
        generation: generation,
        sessionTitle: ""
    ).makeAsyncIterator()

    let first = try #require(await phases.next())
    #expect(first.isCachedPhase)
    #expect(first.messages.isEmpty)
    while await source.authoritativeCalls == 0 {
        await Task.yield()
    }
    await source.finishAuthoritative()
    _ = try #require(await phases.next())
}

@Test("a disabled cache emits an empty provisional phase")
func disabledCacheEmitsEmptyPhase() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = OpenStateSuspendedSource(suspendResume: false)
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(
        source: source,
        cache: HistoryCache(directory: directory),
        cacheEnabled: false,
        generations: generations
    )
    let generation = generations.begin()
    var phases = opener.openPhases(
        sessionID: "session",
        serverTotal: 1,
        generation: generation,
        sessionTitle: ""
    ).makeAsyncIterator()

    let first = try #require(await phases.next())
    #expect(first.isCachedPhase)
    #expect(first.messages.isEmpty)
    while await source.authoritativeCalls == 0 {
        await Task.yield()
    }
    await source.finishAuthoritative()
    _ = try #require(await phases.next())
}

@Test("a generation change during cache read suppresses cached phase")
func staleCachePhaseIsDiscarded() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let seedCache = HistoryCache(directory: directory)
    _ = await seedCache.store(
        [ChatMessage(role: .assistant, text: "cached")],
        for: "session"
    )
    let codec = BlockingOpenStateCodec()
    let cache = HistoryCache(directory: directory, codec: codec)
    let source = OpenStateSuspendedSource()
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(
        source: source,
        cache: cache,
        cacheEnabled: true,
        generations: generations
    )
    let generation = generations.begin()
    let task = Task {
        var phases: [TranscriptOpenResult] = []
        for await phase in opener.openPhases(
            sessionID: "session",
            serverTotal: 1,
            generation: generation,
            sessionTitle: ""
        ) {
            phases.append(phase)
        }
        return phases
    }
    while !codec.started {
        await Task.yield()
    }
    _ = generations.begin()
    codec.release()
    #expect(await task.value.isEmpty)
}


@Test("a disabled cache cannot be repopulated by delayed resume")
func delayedResumeCannotRestoreAfterCacheDisable() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let source = OpenStateSuspendedSource(
        resumed: .init(liveSessionID: "live", rows: [openStateRow(id: 1)]),
        suspendResume: true
    )
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(
        source: source,
        cache: cache,
        cacheEnabled: true,
        generations: generations
    )
    let generation = generations.begin()
    let task = Task {
        await opener.open(
            sessionID: "session",
            serverTotal: 1,
            generation: generation,
            sessionTitle: ""
        )
    }
    while !(await source.resumeStarted) {
        await Task.yield()
    }
    _ = generations.begin()
    await source.finishResume(.init(liveSessionID: "live", rows: []))

    #expect(await task.value == nil)
    #expect(await cache.transcript(for: "session") == nil)
}

@Test("a disabled cache cannot be repopulated by delayed REST")
func delayedRESTCannotRestoreAfterCacheDisable() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let prior = ChatMessage(role: .assistant, text: "prior")
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: "session",
        serverTotal: 1,
        fetchedRows: 1,
        projectedMessages: 1,
        truncated: false,
        fetchedAt: Date()
    )
    _ = await cache.store([prior], snapshot: snapshot, for: "session")

    let source = OpenStateSuspendedSource(
        resumed: .init(liveSessionID: "live", rows: []),
        authoritative: .init(rows: [openStateRow(id: 2)], serverTotal: 2),
        suspendResume: false
    )
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(
        source: source,
        cache: cache,
        cacheEnabled: true,
        generations: generations
    )
    let generation = generations.begin()
    let task = Task {
        await opener.open(
            sessionID: "session",
            serverTotal: 2,
            generation: generation,
            sessionTitle: ""
        )
    }
    while await source.authoritativeCalls == 0 {
        await Task.yield()
    }


    _ = generations.begin()
    await source.finishAuthoritative()

    #expect(await task.value == nil)
    #expect((await cache.transcript(for: "session"))?.messages.map(\.text) == ["prior"])
}
@Test("cache clear rejects an authorized delayed REST store")
func delayedRESTStoreAfterCacheClearIsRejected() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = OpenStateSuspendedSource(
        resumed: .init(liveSessionID: "live", rows: []),
        authoritative: .init(rows: [openStateRow(id: 4)], serverTotal: 1),
        suspendResume: false
    )
    let cache = HistoryCache(directory: directory)
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(
        source: source,
        cache: cache,
        cacheEnabled: true,
        generations: generations
    )
    let generation = generations.begin()
    let task = Task {
        await opener.open(
            sessionID: "session",
            serverTotal: 1,
            generation: generation,
            sessionTitle: ""
        )
    }
    while await source.authoritativeCalls == 0 {
        await Task.yield()
    }

    #expect(await cache.clear())
    await source.finishAuthoritative()
    let result = await task.value
    #expect(result != nil)
    #expect(result?.cacheStore?.addedEntry == false)
    #expect(try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).isEmpty)
}

@Test("cache clear rejects a delayed prefetch store")
func delayedPrefetchStoreAfterCacheClearIsRejected() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let gate = OpenStateGate()
    let task = Task {
        let read = await cache.read(for: "session")
        guard !Task.isCancelled, read.transcript == nil else {
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        await gate.wait()
        return await cache.store(
            [ChatMessage(role: .assistant, text: "prefetched")],
            for: "session",
            expectedEpoch: read.epoch
        )
    }
    while !(await gate.started) {
        await Task.yield()
    }

    #expect(await cache.clear())
    await gate.release()
    let result = await task.value
    #expect(!result.addedEntry)
    #expect(try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).isEmpty)
}

@Test("stale first-turn reconciliation is discarded")
func staleFirstTurnReconciliationIsDiscarded() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let opener = TranscriptOpener(
        source: OpenStateSuspendedSource(),
        cache: HistoryCache(directory: directory),
        cacheEnabled: false,
        generations: OpenGenerationController()
    )
    let generation = opener.generations.begin()
    _ = opener.generations.begin()
    #expect(await opener.reconcileTerminal(
        sessionID: nil,
        serverTotal: nil,
        currentMessages: [],
        generation: generation,
        sessionTitle: ""
    ) == nil)
}

@Test("terminal reconciliation cannot publish after a newer turn")
func staleTerminalReconciliationIsDiscarded() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = OpenStateSuspendedSource(
        authoritative: .init(rows: [openStateRow(id: 3)], serverTotal: 1),
        suspendResume: false
    )
    let cache = HistoryCache(directory: directory)
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(
        source: source,
        cache: cache,
        cacheEnabled: false,
        generations: generations
    )
    let generation = generations.begin()
    let task = Task {
        await opener.reconcileTerminal(
            sessionID: "session",
            serverTotal: 1,
            currentMessages: [ChatMessage(role: .user, text: "new turn")],
            generation: generation,
            sessionTitle: ""
        )
    }
    while await source.authoritativeCalls == 0 {
        await Task.yield()
    }
    _ = generations.begin()
    await source.finishAuthoritative()
    #expect(await task.value == nil)
}

private actor OpenStateGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor OpenStateSuspendedSource: TranscriptSource {
    private let resumed: ResumedTranscript
    private let authoritative: AuthoritativeTranscript
    private let suspendResume: Bool
    private var resumeContinuation: CheckedContinuation<ResumedTranscript, Error>?
    private var authoritativeContinuation: CheckedContinuation<AuthoritativeTranscript, Error>?
    private(set) var resumeStarted = false
    private(set) var authoritativeCalls = 0

    init(

        resumed: ResumedTranscript = .init(liveSessionID: "live", rows: []),
        authoritative: AuthoritativeTranscript = .init(rows: [], serverTotal: 0),
        suspendResume: Bool = true
    ) {
        self.resumed = resumed
        self.authoritative = authoritative
        self.suspendResume = suspendResume
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        resumeStarted = true
        guard suspendResume else { return resumed }
        return try await withCheckedThrowingContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        authoritativeCalls += 1
        return try await withCheckedThrowingContinuation { continuation in
            authoritativeContinuation = continuation
        }
    }

    func finishResume(_ value: ResumedTranscript) {
        resumeContinuation?.resume(returning: value)
        resumeContinuation = nil
    }

    func finishAuthoritative() {
        authoritativeContinuation?.resume(returning: authoritative)
        authoritativeContinuation = nil
    }
}
private final class BlockingOpenStateCodec: CacheCodec, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private(set) var started = false

    func encode(_ transcript: CachedTranscript) throws -> Data {
        try JSONCacheCodec().encode(transcript)
    }

    func decode(_ data: Data) throws -> CachedTranscript {
        started = true
        gate.wait()
        return try JSONCacheCodec().decode(data)
    }

    func release() {
        gate.signal()
    }
}

private func openStateRow(id: Int64) -> JSONValue {
    .object([
        "id": .integer(id),
        "role": .string(Role.assistant.rawValue),
        "content": .string("row \(id)")
    ])
}

private func openStateTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "HermternalOpenState-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
