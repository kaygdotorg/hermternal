import Foundation
import HermternalCore
import Testing

@Test("successful REST snapshots are complete even at the page boundary")
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
    #expect(!growing.truncated)
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
    var phases = opener.openInteractionPhases(
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
    #expect(await source.resumeCalls == 1)
}

@Test("read-only cached open never resumes")
func cachedReadDoesNotResume() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: "session",
        serverTotal: 1,
        fetchedRows: 1,
        projectedMessages: 1,
        truncated: false,
        fetchedAt: Date()
    )
    _ = await cache.store(
        [ChatMessage(role: .assistant, text: "cached")],
        snapshot: snapshot,
        for: "session"
    )
    let source = OpenStateSuspendedSource(suspendResume: false)
    let opener = TranscriptOpener(
        source: source,
        cache: cache,
        cacheEnabled: true,
        generations: OpenGenerationController()
    )
    let generation = opener.generations.begin()
    var phases = opener.openPhases(
        sessionID: "session",
        serverTotal: 1,
        generation: generation,
        sessionTitle: ""
    ).makeAsyncIterator()

    let first = try #require(await phases.next())
    #expect(first.messages.map(\.text) == ["cached"])
    #expect(await phases.next() == nil)
    #expect(await source.resumeCalls == 0)
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
    #expect(await source.resumeCalls == 0)
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
        await opener.openForInteraction(
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
        await opener.openForInteraction(
            sessionID: "session",
            serverTotal: 2,
            generation: generation,
            sessionTitle: ""
        )
    }
    while await source.authoritativeWaiterCount == 0 {
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
        await opener.openForInteraction(
            sessionID: "session",
            serverTotal: 1,
            generation: generation,
            sessionTitle: ""
        )
    }
    while await source.authoritativeWaiterCount == 0 {
        await Task.yield()
    }

    #expect(await cache.clear())
    await source.finishAuthoritative()
    let result = await task.value
    #expect(result?.cacheStore?.addedEntry != true)
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
    while await source.authoritativeWaiterCount == 0 {
        await Task.yield()
    }
    _ = generations.begin()
    await source.finishAuthoritative()
    let result = await task.value
    #expect(result == nil)
    #expect(await source.authoritativeWaiterCount == 0)
}

@Test("superseded open handles terminate one-for-one")
func supersededOpenHandlesTerminateOneForOne() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = OpenStateSuspendedSource()
    let opener = TranscriptOpener(
        source: source,
        cache: HistoryCache(directory: directory),
        cacheEnabled: false,
        generations: OpenGenerationController()
    )
    var handles: [TranscriptOpenHandle] = []
    for index in 0..<4 {
        let generation = opener.generations.begin()
        let handle = TranscriptOpenHandle()
        var phases = opener.openInteractionPhases(
            sessionID: "session-\(index)",
            serverTotal: 1,
            generation: generation,
            sessionTitle: "",
            handle: handle
        ).makeAsyncIterator()
        _ = await phases.next()
        while await source.resumeCalls < index + 1 {
            await Task.yield()
        }
        if let previous = handles.last {
            previous.cancel()
        }
        handles.append(handle)
    }
    handles.last?.cancel()
    let resumeCalls = await source.resumeCalls
    #expect(resumeCalls == handles.count)
    await source.finishResume(.init(liveSessionID: "live", rows: []))
    while await source.resumeCompletedCount < resumeCalls {
        await Task.yield()
    }
    #expect(await source.resumeWaiterCount == 0)
    #expect(handles.count == handles.filter(\.isTerminated).count)
}

@Test("cancelling an open clears captured transcript state")
func cancellingOpenClearsCapturedTranscriptState() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = HistoryCache(directory: directory)
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: "session",
        serverTotal: 1,
        fetchedRows: 1,
        projectedMessages: 1,
        truncated: false,
        fetchedAt: Date()
    )
    _ = await cache.store(
        [ChatMessage(role: .assistant, text: "retained until cancellation")],
        snapshot: snapshot,
        for: "session"
    )
    let source = OpenStateSuspendedSource()
    let opener = TranscriptOpener(
        source: source,
        cache: cache,
        cacheEnabled: true,
        generations: OpenGenerationController()
    )
    let handle = TranscriptOpenHandle()
    var phases = opener.openInteractionPhases(
        sessionID: "session",
        serverTotal: 1,
        generation: opener.generations.begin(),
        sessionTitle: "",
        handle: handle
    ).makeAsyncIterator()
    _ = try #require(await phases.next())
    while !(await source.resumeStarted) {
        await Task.yield()
    }
    #expect(handle.retainedMessageCount == 1)
    handle.cancel()
    #expect(handle.isTerminated)
    #expect(handle.retainedMessageCount == 0)
    await source.finishResume(.init(liveSessionID: "live", rows: []))
    while await source.resumeCompletedCount < 1 {
        await Task.yield()
    }
    #expect(await source.resumeWaiterCount == 0)
    #expect(await phases.next() == nil)
}

@Test("REST publishes its first page before reconciliation completes")
func restPublishesInitialPageBeforeReconciliation() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = IncrementalOpenSource(
        pages: [
            TranscriptMessagePage(
                messages: [openStateRow(id: 1)],
                returned: 1,
                offset: 0,
                serverTotal: 2,
                byteCount: 32
            ),
            TranscriptMessagePage(
                messages: [openStateRow(id: 2)],
                returned: 1,
                offset: 1,
                serverTotal: 2,
                byteCount: 32
            )
        ],
        pausesAfterFirstPage: true
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
    var phases = opener.openPhases(
        sessionID: "session",
        serverTotal: 2,
        generation: generation,
        sessionTitle: ""
    ).makeAsyncIterator()
    _ = try #require(await phases.next())
    defer {
        Task { await source.releaseFirstPage() }
    }
    let initial = try #require(await phases.next())
    #expect(initial.isInitialPage)
    #expect(initial.messages.map(\.text) == ["row 1"])
    let deliveredSecondPage = await source.secondPageDelivered
    #expect(!deliveredSecondPage)

    let route = try await cache.pagedStore(for: "session").currentRoute()
    let firstPage = try await cache.transcriptPage(
        for: "session",
        request: TranscriptPageRequest(
            maximumBytes: 512,
            maximumRows: 64,
            expectedGeneration: route.generation,
            expectedEpoch: route.epoch
        )
    )
    #expect(firstPage.rows.map(\.text) == ["row 1"])

    await source.releaseFirstPage()
    let final = try #require(await phases.next())
    #expect(!final.isInitialPage)
    #expect(final.messages.map(\.text) == ["row 1", "row 2"])
    #expect(await phases.next() == nil)
}

@Test("a superseded REST route cannot publish its initial page")
func supersededRESTRouteCannotPublishInitialPage() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = IncrementalOpenSource(
        pages: [
            TranscriptMessagePage(
                messages: [openStateRow(id: 1)],
                returned: 1,
                offset: 0,
                serverTotal: 1,
                byteCount: 32
            )
        ],
        pausesBeforeFirstPage: true
    )
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(
        source: source,
        cache: HistoryCache(directory: directory),
        cacheEnabled: true,
        generations: generations
    )
    let generation = generations.begin()
    defer {
        Task { await source.releaseFirstPage() }
    }
    let task = Task {
        var phases: [TranscriptOpenResult] = []
        for await phase in opener.openPhases(
            sessionID: "session",
            serverTotal: 1,
            generation: generation,
            sessionTitle: "",
        ) {
            phases.append(phase)
        }
        return phases
    }
    while !(await source.streamStarted) {
        await Task.yield()
    }
    _ = generations.begin()
    await source.releaseFirstPage()
    await Task.yield()
    let phases = await task.value
    #expect(phases.allSatisfy { !$0.isInitialPage })
}

@Test("40 rapid selections start immediate opens and only latest route commits")
func rapidSelectionBurstIsLatestWins() async throws {
    let directory = try openStateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = LatestWinsGatedSource()
    let cache = HistoryCache(directory: directory)
    let generations = OpenGenerationController()
    let opener = TranscriptOpener(
        source: source,
        cache: cache,
        cacheEnabled: true,
        generations: generations
    )

    var immediateOpenStarts: [String] = []
    let releaseFlushes = 0
    var handles: [TranscriptOpenHandle] = []
    var tasks: [Task<[TranscriptOpenResult], Never>] = []
    var previousHandle: TranscriptOpenHandle?
    var previousTask: Task<[TranscriptOpenResult], Never>?

    for index in 1...40 {
        let generation = generations.begin()
        previousHandle?.cancel()
        if let previousTask {
            _ = await previousTask.value
        }
        await source.waitUntilIdle()

        let sessionID = "chat-\(index)"
        let handle = TranscriptOpenHandle()
        immediateOpenStarts.append(sessionID)
        let task = Task {
            var phases: [TranscriptOpenResult] = []
            for await phase in opener.openPhases(
                sessionID: sessionID,
                serverTotal: 1,
                generation: generation,
                sessionTitle: sessionID,
                handle: handle
            ) {
                phases.append(phase)
            }
            return phases
        }
        handles.append(handle)
        tasks.append(task)
        await source.waitForStreamCall(index)
        previousHandle = handle
        previousTask = task
    }

    await source.releaseLatest()
    var finalPhases: [TranscriptOpenResult] = []
    var nonCachedPublications: [String] = []
    for (index, task) in tasks.enumerated() {
        let phases = await task.value
        if index == tasks.index(before: tasks.endIndex) {
            finalPhases = phases
        }
        nonCachedPublications.append(
            contentsOf: phases
                .filter { !$0.isCachedPhase }
                .map { _ in immediateOpenStarts[index] }
        )
    }
    let finalCache = await cache.transcript(for: "chat-40")

    #expect(immediateOpenStarts == (1...40).map { "chat-\($0)" })
    #expect(await source.streamSessionIDs == immediateOpenStarts)
    #expect(releaseFlushes == 0)
    #expect(finalPhases.contains { $0.didFetchREST })
    #expect(await source.streamCalls == 40)
    #expect(await source.terminatedStreams == 40)
    #expect(await source.pendingGateCount == 0)
    #expect(nonCachedPublications.allSatisfy { $0 == "chat-40" })
    #expect(!nonCachedPublications.isEmpty)
    #expect(finalCache?.messages.map(\.text) == ["row 100"])
    #expect(await source.maxActiveStreams == 1)
    #expect(await source.activeStreams == 0)
    #expect(handles.allSatisfy { handle in handle.isTerminated })
    print(
        "OPEN_BURST|immediateStarts=\(immediateOpenStarts.count) "
            + "releaseFlushes=\(releaseFlushes) "
            + "streamCalls=\(await source.streamCalls) "
            + "maxActive=\(await source.maxActiveStreams) "
            + "active=\(await source.activeStreams) "
            + "producerTerminated=\(await source.terminatedStreams) "
            + "nonCachedPublications=\(nonCachedPublications.count) "
            + "finalStored=\(finalCache != nil)"
    )
}

@Test("gated source cancellation is atomic across continuation insertion")
func gatedSourceCancellationIsAtomicAcrossContinuationInsertion() async throws {
    let cancelledBeforeInsertion = LatestWinsGatedSource(
        pausesBeforeContinuationInsertion: true
    )
    let beforeInsertionTask = Task {
        try await cancelledBeforeInsertion.streamAuthoritative(
            sessionID: "before",
            onPage: { _ in }
        )
    }
    await cancelledBeforeInsertion.waitUntilContinuationInsertionIsBlocked()
    beforeInsertionTask.cancel()
    await cancelledBeforeInsertion.waitUntilCancellationIsRecorded()
    await cancelledBeforeInsertion.allowContinuationInsertion()
    _ = try await beforeInsertionTask.value

    #expect(await cancelledBeforeInsertion.continuationResumeCount == 1)
    #expect(await cancelledBeforeInsertion.pendingGateCount == 0)
    #expect(await cancelledBeforeInsertion.activeStreams == 0)
    #expect(await cancelledBeforeInsertion.terminatedStreams == 1)

    let cancelledAfterInsertion = LatestWinsGatedSource()
    let afterInsertionTask = Task {
        try await cancelledAfterInsertion.streamAuthoritative(
            sessionID: "after",
            onPage: { _ in }
        )
    }
    await cancelledAfterInsertion.waitUntilContinuationIsInserted()
    afterInsertionTask.cancel()
    await cancelledAfterInsertion.waitUntilCancellationIsRecorded()
    _ = try await afterInsertionTask.value

    #expect(await cancelledAfterInsertion.continuationResumeCount == 1)
    #expect(await cancelledAfterInsertion.pendingGateCount == 0)
    #expect(await cancelledAfterInsertion.activeStreams == 0)
    #expect(await cancelledAfterInsertion.terminatedStreams == 1)
}

private actor LatestWinsGatedSource: TranscriptSource {
    private enum GateState {
        case pendingInsertion
        case waiting(CheckedContinuation<Void, Never>)
        case cancelled
    }

    private let pausesBeforeContinuationInsertion: Bool
    private var gates: [UUID: GateState] = [:]
    private var streamCallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var insertionReachedWaiter: CheckedContinuation<Void, Never>?
    private var insertionWaiter: CheckedContinuation<Void, Never>?
    private var insertionWasReached = false
    private var insertionWasAllowed = false
    private var continuationInsertedWaiter: CheckedContinuation<Void, Never>?
    private var continuationWasInserted = false
    private var cancellationRecordedWaiter: CheckedContinuation<Void, Never>?
    private var cancellationWasRecorded = false
    private(set) var streamCalls = 0
    private(set) var streamSessionIDs: [String] = []
    private(set) var activeStreams = 0
    private(set) var maxActiveStreams = 0
    private(set) var terminatedStreams = 0
    private(set) var continuationResumeCount = 0
    var pendingGateCount: Int { gates.count }

    init(pausesBeforeContinuationInsertion: Bool = false) {
        self.pausesBeforeContinuationInsertion = pausesBeforeContinuationInsertion
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        ResumedTranscript(liveSessionID: "live", rows: [])
    }

    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        AuthoritativeTranscript(rows: [openStateRow(id: 100)], serverTotal: 1)
    }

    func streamAuthoritative(
        sessionID: String,
        onPage: @escaping TranscriptMessagePageConsumer
    ) async throws -> AuthoritativeTranscriptMetadata {
        streamSessionIDs.append(sessionID)
        streamCalls += 1
        resumeStreamCallWaiters()
        activeStreams += 1
        maxActiveStreams = max(maxActiveStreams, activeStreams)
        let token = UUID()
        gates[token] = .pendingInsertion
        defer {
            gates.removeValue(forKey: token)
            activeStreams -= 1
            terminatedStreams += 1
            resumeIdleWaitersIfNeeded()
        }
        await withTaskCancellationHandler(operation: {
            if pausesBeforeContinuationInsertion {
                await waitBeforeContinuationInsertion()
            }
            await withCheckedContinuation { continuation in
                switch gates.removeValue(forKey: token) {
                case .some(.pendingInsertion):
                    gates[token] = .waiting(continuation)
                    continuationWasInserted = true
                    continuationInsertedWaiter?.resume()
                    continuationInsertedWaiter = nil
                case .some(.cancelled), .none:
                    continuationResumeCount += 1
                    continuation.resume()
                case .some(.waiting):
                    preconditionFailure("A gate continuation can only be inserted once.")
                }
            }
        }, onCancel: {
            Task { await self.cancel(token) }
        })
        try await onPage(
            TranscriptMessagePage(
                messages: [openStateRow(id: 100)],
                returned: 1,
                offset: 0,
                serverTotal: 1,
                byteCount: 32
            )
        )
        return AuthoritativeTranscriptMetadata(messageCount: 1, serverTotal: 1)
    }

    func waitForStreamCall(_ expected: Int) async {
        guard streamCalls < expected else { return }
        await withCheckedContinuation { continuation in
            streamCallWaiters.append((expected, continuation))
        }
    }

    func waitUntilIdle() async {
        guard activeStreams > 0 else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    func waitUntilContinuationInsertionIsBlocked() async {
        guard !insertionWasReached else { return }
        await withCheckedContinuation { continuation in
            insertionReachedWaiter = continuation
        }
    }

    func allowContinuationInsertion() {
        if let insertionWaiter {
            self.insertionWaiter = nil
            insertionWaiter.resume()
        } else {
            insertionWasAllowed = true
        }
    }

    func waitUntilContinuationIsInserted() async {
        guard !continuationWasInserted else { return }
        await withCheckedContinuation { continuation in
            continuationInsertedWaiter = continuation
        }
    }

    func waitUntilCancellationIsRecorded() async {
        guard !cancellationWasRecorded else { return }
        await withCheckedContinuation { continuation in
            cancellationRecordedWaiter = continuation
        }
    }

    func releaseLatest() {
        let pending = gates.values
        gates.removeAll()
        for case let .waiting(continuation) in pending {
            continuationResumeCount += 1
            continuation.resume()
        }
    }

    private func waitBeforeContinuationInsertion() async {
        insertionWasReached = true
        insertionReachedWaiter?.resume()
        insertionReachedWaiter = nil
        guard !insertionWasAllowed else {
            insertionWasAllowed = false
            return
        }
        await withCheckedContinuation { continuation in
            insertionWaiter = continuation
        }
    }

    private func cancel(_ token: UUID) {
        guard let state = gates.removeValue(forKey: token) else { return }
        cancellationWasRecorded = true
        cancellationRecordedWaiter?.resume()
        cancellationRecordedWaiter = nil
        switch state {
        case .pendingInsertion:
            gates[token] = .cancelled
        case let .waiting(continuation):
            continuationResumeCount += 1
            continuation.resume()
        case .cancelled:
            gates[token] = .cancelled
        }
    }

    private func resumeStreamCallWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expected, continuation) in streamCallWaiters {
            if expected <= streamCalls {
                continuation.resume()
            } else {
                pending.append((expected, continuation))
            }
        }
        streamCallWaiters = pending
    }

    private func resumeIdleWaitersIfNeeded() {
        guard activeStreams == 0 else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}


private actor IncrementalOpenSource: TranscriptSource {
    let pages: [TranscriptMessagePage]
    let pausesAfterFirstPage: Bool
    let pausesBeforeFirstPage: Bool
    private var firstPageContinuation: CheckedContinuation<Void, Never>?
    private var firstPageReleased = false
    private(set) var streamStarted = false
    private(set) var firstPageDelivered = false
    private(set) var secondPageDelivered = false

    init(
        pages: [TranscriptMessagePage],
        pausesAfterFirstPage: Bool = false,
        pausesBeforeFirstPage: Bool = false
    ) {
        self.pages = pages
        self.pausesAfterFirstPage = pausesAfterFirstPage
        self.pausesBeforeFirstPage = pausesBeforeFirstPage
    }

    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        AuthoritativeTranscript(
            rows: pages.flatMap(\.messages),
            serverTotal: pages.last?.serverTotal
        )
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        ResumedTranscript(liveSessionID: "live", rows: [])
    }

    func streamAuthoritative(
        sessionID _: String,
        onPage: @escaping TranscriptMessagePageConsumer
    ) async throws -> AuthoritativeTranscriptMetadata {
        streamStarted = true
        if pausesBeforeFirstPage {
            await waitForFirstPageRelease()
        }
        for (index, page) in pages.enumerated() {
            if index == 0 { firstPageDelivered = true }
            try await onPage(page)
            if index == 0, pausesAfterFirstPage {
                await waitForFirstPageRelease()
            }
            if index == 1 { secondPageDelivered = true }
        }
        return AuthoritativeTranscriptMetadata(
            messageCount: pages.reduce(0) { $0 + $1.messages.count },
            serverTotal: pages.last?.serverTotal
        )
    }

    func releaseFirstPage() {
        if let continuation = firstPageContinuation {
            firstPageContinuation = nil
            continuation.resume()
        } else {
            firstPageReleased = true
        }
    }

    private func waitForFirstPageRelease() async {
        guard !firstPageReleased else {
            firstPageReleased = false
            return
        }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                firstPageContinuation = continuation
            }
        }, onCancel: {
            Task { await self.releaseFirstPage() }
        })
    }
}

private actor OpenStateGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false

    func wait() async {
        started = true
        guard !released else {
            released = false
            return
        }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }, onCancel: {
            Task { await self.release() }
        })
    }

    func release() {
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            released = true
        }
    }
}

private actor OpenStateSuspendedSource: TranscriptSource {
    private let resumed: ResumedTranscript
    private let authoritative: AuthoritativeTranscript
    private let suspendResume: Bool
    private var resumeContinuations: [UUID: CheckedContinuation<ResumedTranscript, Error>] = [:]
    private var authoritativeContinuations: [UUID: CheckedContinuation<AuthoritativeTranscript, Error>] = [:]
    var authoritativeWaiterCount: Int { authoritativeContinuations.count }
    var resumeWaiterCount: Int { resumeContinuations.count }
    private(set) var resumeStarted = false
    private(set) var resumeCalls = 0
    private(set) var authoritativeCalls = 0
    private(set) var resumeCompletedCount = 0

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
        resumeCalls += 1
        resumeStarted = true
        guard suspendResume else {
            resumeCompletedCount += 1
            return resumed
        }
        let token = UUID()
        do {
            let value = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    resumeContinuations[token] = continuation
                }
            }, onCancel: {
                Task { await self.cancelResume(token) }
            })
            resumeCompletedCount += 1
            return value
        } catch {
            resumeCompletedCount += 1
            throw error
        }
    }

    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        authoritativeCalls += 1
        let token = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                authoritativeContinuations[token] = continuation
            }
        }, onCancel: {
            Task { await self.cancelAuthoritative(token) }
        })
    }

    private func cancelResume(_ token: UUID) {
        resumeContinuations.removeValue(forKey: token)?.resume(throwing: CancellationError())
    }

    private func cancelAuthoritative(_ token: UUID) {
        authoritativeContinuations.removeValue(forKey: token)?.resume(throwing: CancellationError())
    }

    func finishResume(_ value: ResumedTranscript) {
        let continuations = resumeContinuations.values
        resumeContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: value)
        }
    }

    func finishAuthoritative() {
        let continuations = authoritativeContinuations.values
        authoritativeContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: authoritative)
        }
    }
}
private final class BlockingOpenStateCodec: CacheCodec, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var startedValue = false
    private var releasePermits = 0

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedValue
    }

    func encode(_ transcript: CachedTranscript) throws -> Data {
        try JSONCacheCodec().encode(transcript)
    }

    func decode(_ data: Data) throws -> CachedTranscript {
        lock.lock()
        startedValue = true
        let consumePermit = releasePermits > 0
        if consumePermit { releasePermits -= 1 }
        lock.unlock()
        if !consumePermit {
            gate.wait()
        }
        return try JSONCacheCodec().decode(data)
    }

    func release() {
        lock.lock()
        if startedValue {
            lock.unlock()
            gate.signal()
        } else {
            releasePermits += 1
            lock.unlock()
        }
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
