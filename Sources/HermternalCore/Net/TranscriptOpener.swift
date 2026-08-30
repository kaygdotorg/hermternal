import Foundation
private enum TranscriptSwitchTrace {

    static func opener(
        _ event: String,
        sessionID: String,
        generation: Int,
        messages: Int? = nil,
        detail: String? = nil
    ) {
        guard MeasurementGate.isEnabled(.switchPhases) else { return }
        var hash: UInt64 = 14695981039346656037 ^ 0x01
        for byte in sessionID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        let line = "[DEBUG-switch-7F3A] ns=\(DispatchTime.now().uptimeNanoseconds)"
            + " event=\(event)"
            + " gen=\(generation)"
            + " messages=\(messages.map { String($0) } ?? "-")"
            + " token=\(String(hash, radix: 16))"
            + (detail.map { " detail=\($0)" } ?? "")
            + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func resume(
        sessionID: String,
        generation: Int,
        messages: Int,
        detail: String
    ) {
        opener(
            "resume.complete",
            sessionID: sessionID,
            generation: generation,
            messages: messages,
            detail: detail
        )
    }
}

/// Explicit cancellation for one cache-first open.
///
/// `AsyncStream` cancellation normally reaches its producer through
/// `onTermination`. The handle additionally clears the producer's retained
/// transcript state synchronously, so cancellation does not depend on the
/// producer reaching its next actor or network suspension point.
public final class TranscriptOpenHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelAction: (@Sendable () -> Void)?
    private var terminatedValue = false
    private var retainedMessageCountValue = 0

    public init() {}

    public var isTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminatedValue
    }

    public func cancel() {
        let action: (@Sendable () -> Void)?
        lock.lock()
        action = cancelAction
        lock.unlock()
        action?()
    }
    public var retainedMessageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedMessageCountValue
    }
    fileprivate func setRetainedMessageCount(_ count: Int) {
        lock.lock()
        retainedMessageCountValue = count
        lock.unlock()
    }

    fileprivate func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if terminatedValue {
            lock.unlock()
            action()
            return
        }
        cancelAction = action
        lock.unlock()
    }

    fileprivate func markTerminated() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminatedValue else { return false }
        terminatedValue = true
        cancelAction = nil
        return true
    }
}

private final class TranscriptInitialPageState: @unchecked Sendable {
    private let lock = NSLock()
    private var didPublish = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didPublish else { return false }
        didPublish = true
        return true
    }
}

private final class TranscriptTailAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [JSONValue] = []

    func append(_ page: [JSONValue]) {
        lock.lock()
        values.append(contentsOf: page)
        let overflow = values.count - TranscriptPublicationPolicy.initialMessageCount
        if overflow > 0 { values.removeFirst(overflow) }
        lock.unlock()
    }

    var rows: [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
private final class TranscriptCompatibilityAccumulator: @unchecked Sendable {
    static let maximumBytes = 16 * 1024 * 1024
    private let lock = NSLock()
    private var values: [JSONValue] = []
    private var bytes = 0
    private var didOverflow = false

    func append(_ page: TranscriptMessagePage) {
        lock.lock()
        defer { lock.unlock() }
        guard !didOverflow else { return }
        let estimated = page.messages.reduce(into: 0) { total, value in
            total += Self.estimatedBytes(value)
        }
        let pageBytes = max(page.byteCount, estimated)
        guard pageBytes <= Self.maximumBytes - min(bytes, Self.maximumBytes) else {
            values.removeAll(keepingCapacity: false)
            didOverflow = true
            return
        }
        bytes += pageBytes
        values.append(contentsOf: page.messages)
    }

    var rows: [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var isOversized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didOverflow
    }

    private static func estimatedBytes(_ value: JSONValue) -> Int {
        switch value {
        case .string(let value): return value.utf8.count
        case .array(let values): return values.reduce(0) { $0 + estimatedBytes($1) }
        case .object(let fields):
            return fields.reduce(0) { $0 + $1.key.utf8.count + estimatedBytes($1.value) }
        default: return 16
        }
    }
}

private final class TranscriptOpenState: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedValue: CachedTranscript?
    private var resumedValue: ResumedTranscript?
    private var authoritativeValue: AuthoritativeTranscript?
    private var projectedValue: [ChatMessage]?
    private var cacheEpochValue: UInt64?

    var cached: CachedTranscript? {
        lock.lock()
        defer { lock.unlock() }
        return cachedValue
    }

    var resumed: ResumedTranscript? {
        lock.lock()
        defer { lock.unlock() }
        return resumedValue
    }

    var authoritative: AuthoritativeTranscript? {
        lock.lock()
        defer { lock.unlock() }
        return authoritativeValue
    }

    var projected: [ChatMessage]? {
        lock.lock()
        defer { lock.unlock() }
        return projectedValue
    }

    var cacheEpoch: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return cacheEpochValue
    }

    func setCached(_ value: CachedTranscript?, epoch: UInt64?) {
        lock.lock()
        cachedValue = value
        cacheEpochValue = epoch
        lock.unlock()
    }

    func setResumed(_ value: ResumedTranscript?) {
        lock.lock()
        resumedValue = value
        lock.unlock()
    }

    func setAuthoritative(_ value: AuthoritativeTranscript?) {
        lock.lock()
        authoritativeValue = value
        lock.unlock()
    }

    func setProjected(_ value: [ChatMessage]?) {
        lock.lock()
        projectedValue = value
        lock.unlock()
    }

    func clear() {
        lock.lock()
        cachedValue = nil
        resumedValue = nil
        authoritativeValue = nil
        projectedValue = nil
        cacheEpochValue = nil
        lock.unlock()
    }
}


public enum CacheFirstOpenPolicy {
    /// A missing or previously incomplete snapshot requires an authoritative
    /// REST read. A complete snapshot is refreshed only when the server knows
    /// that more rows exist than the cache contains.
    public static func shouldFetchREST(
        snapshot: AuthoritativeTranscriptSnapshot?,
        serverTotal: Int?,
        resumeMessageCount: Int? = nil
    ) -> Bool {
        guard let snapshot else { return true }
        if snapshot.truncated { return true }
        let knownTotal = max(
            serverTotal ?? 0,
            snapshot.serverTotal ?? 0,
            resumeMessageCount ?? 0
        )
        return knownTotal > snapshot.fetchedRows
    }

    public static func snapshot(
        sessionID: String,
        rows: [JSONValue],
        projectedMessages: Int,
        serverTotal: Int?,
        complete: Bool = true,
        fetchedAt: Date = Date()
    ) -> AuthoritativeTranscriptSnapshot {
        AuthoritativeTranscriptSnapshot(
            sessionID: sessionID,
            serverTotal: serverTotal,
            fetchedRows: rows.count,
            projectedMessages: projectedMessages,
            truncated: !complete,
            fetchedAt: fetchedAt
        )
    }
}

/// Thread-safe generation control for cache-first asynchronous operations.
public final class OpenGenerationController: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    public init() {}

    public func begin() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    public func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == value
    }
}
private final class TranscriptOpenTaskRef: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
}
}

public struct TranscriptOpenResult: Sendable {
    public let liveSessionID: String?
    /// Only the bounded tail needed for the first frame. Full history lives
    /// in PagedTranscriptStore and is requested by ordinal pages.
    public let messages: [ChatMessage]
    public let cacheStore: CacheStoreResult?
    public let notice: String?
    public let didFetchREST: Bool
    public let isCachedPhase: Bool
    /// True when this result publishes the first REST page before the
    /// authoritative stream has finished.
    public let isInitialPage: Bool
    public let snapshot: AuthoritativeTranscriptSnapshot?
    public let summary: TranscriptSummary?

    public init(
        liveSessionID: String?,
        messages: [ChatMessage],
        cacheStore: CacheStoreResult? = nil,
        notice: String? = nil,
        didFetchREST: Bool = false,
        isCachedPhase: Bool = false,
        isInitialPage: Bool = false,
        snapshot: AuthoritativeTranscriptSnapshot? = nil,
        summary: TranscriptSummary? = nil
    ) {
        self.liveSessionID = liveSessionID
        self.messages = messages
        self.cacheStore = cacheStore
        self.notice = notice
        self.didFetchREST = didFetchREST
        self.isCachedPhase = isCachedPhase
        self.isInitialPage = isInitialPage
        self.snapshot = snapshot
        self.summary = summary
    }
}

public struct TranscriptReconciliationResult: Sendable {
    public let messages: [ChatMessage]
    public let cacheStore: CacheStoreResult?
    public let notice: String?
    public let snapshot: AuthoritativeTranscriptSnapshot?
    /// A first turn has no durable id; the caller should refresh its sidebar.
    public let requiresSessionRefresh: Bool

    public init(
        messages: [ChatMessage],
        cacheStore: CacheStoreResult? = nil,
        notice: String? = nil,
        snapshot: AuthoritativeTranscriptSnapshot? = nil,
        requiresSessionRefresh: Bool = false
    ) {
        self.messages = messages
        self.cacheStore = cacheStore
        self.notice = notice
        self.snapshot = snapshot
        self.requiresSessionRefresh = requiresSessionRefresh
    }
}

/// Production cache-first opening and terminal reconciliation policy.
/// AppModel only publishes the returned state; it does not duplicate the
/// resume, growth, truncation, REST, or cache branching here.
public struct TranscriptOpener: Sendable {
    public let source: any TranscriptSource
    public let cache: any TranscriptPersisting
    public let cacheEnabled: Bool
    public let generations: OpenGenerationController

    public init(
        source: any TranscriptSource,
        cache: any TranscriptPersisting,
        cacheEnabled: Bool,
        generations: OpenGenerationController
    ) {
        self.source = source
        self.cache = cache
        self.cacheEnabled = cacheEnabled
        self.generations = generations
    }

    /// Opens a transcript for read-only browsing as a stream of progressively
    /// stronger results. This path reads the local cache and, when its
    /// completeness policy requires it, fetches authoritative history. It
    /// never resumes a live server-side session.
    ///
    /// `sessionTitle` is the authoritative session-list title used by the
    /// search index digest. Keeping it unchanged avoids an FTS rewrite;
    /// changing it intentionally refreshes title-bearing rows.

    /// Opens a transcript for an interaction that needs a live session.
    ///
    /// The cache phase is still yielded first, but this explicit path resumes
    /// exactly once before applying resume growth metadata and fetching REST
    /// authority when needed.
    public func openPhases(
        sessionID: String,
        serverTotal: Int?,
        generation: Int,
        sessionTitle: String,
        handle: TranscriptOpenHandle? = nil
    ) -> AsyncStream<TranscriptOpenResult> {
        openPhases(
            sessionID: sessionID,
            serverTotal: serverTotal,
            generation: generation,
            sessionTitle: sessionTitle,
            mode: .readOnly,
            handle: handle
        )
    }

    /// Opens a transcript for an interaction that needs a live session.
    ///
    /// The cache phase is still yielded first, but this explicit path resumes
    /// exactly once before applying resume growth metadata and fetching REST
    /// authority when needed.
    public func openInteractionPhases(
        sessionID: String,
        serverTotal: Int?,
        generation: Int,
        sessionTitle: String,
        handle: TranscriptOpenHandle? = nil
    ) -> AsyncStream<TranscriptOpenResult> {
        openPhases(
            sessionID: sessionID,
            serverTotal: serverTotal,
            generation: generation,
            sessionTitle: sessionTitle,
            mode: .interaction,
            handle: handle
        )
    }

    private enum OpenMode: Sendable, Equatable {
        case readOnly
        case interaction
    }

    private func openPhases(
        sessionID: String,
        serverTotal: Int?,
        generation: Int,
        sessionTitle: String,
        mode: OpenMode,
        handle: TranscriptOpenHandle?
    ) -> AsyncStream<TranscriptOpenResult> {
        let state = TranscriptOpenState()
        let ownedHandle = handle ?? TranscriptOpenHandle()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let taskRef = TranscriptOpenTaskRef()
            let terminate: @Sendable (String) -> Void = { detail in
                state.clear()
                ownedHandle.setRetainedMessageCount(0)
                taskRef.cancel()
                if ownedHandle.markTerminated() {
                    TranscriptSwitchTrace.opener(
                        "opener.terminate",
                        sessionID: sessionID,
                        generation: generation,
                        detail: detail
                    )
                }
            }
            TranscriptSwitchTrace.opener(
                "opener.create",
                sessionID: sessionID,
                generation: generation
            )
            let task = Task {
                defer { terminate("task") }
                var resumeNotice: String?
                if cacheEnabled {
                    guard !Task.isCancelled else {
                        terminate("cancelled")
                        continuation.finish()
                        return
                    }
                    let read = await cache.read(for: sessionID)
                    guard !Task.isCancelled else {
                        terminate("cancelled")
                        continuation.finish()
                        return
                    }
                    state.setCached(read.transcript, epoch: read.epoch)
                    let cachedMessages = Self.boundedTail(read.transcript?.messages ?? [])
                    ownedHandle.setRetainedMessageCount(cachedMessages.count)
                }
                guard isCurrent(generation) else {
                    continuation.finish()
                    return
                }
                continuation.yield(
                    TranscriptOpenResult(
                        liveSessionID: nil,
                        messages: Self.boundedTail(state.cached?.messages ?? []),
                        isCachedPhase: true,
                        snapshot: state.cached?.snapshot
                    )
                )

                if mode == .interaction {
                    guard isCurrent(generation) else {
                        continuation.finish()
                        return
                    }
                    do {
                        let resumed = try await source.resume(sessionID: sessionID)
                        guard !Task.isCancelled else {
                            terminate("cancelled")
                            continuation.finish()
                            return
                        }
                        ownedHandle.setRetainedMessageCount(
                            min(resumed.rows.count, TranscriptPublicationPolicy.initialMessageCount)
                        )
                        state.setResumed(resumed)
                        TranscriptSwitchTrace.resume(
                            sessionID: sessionID,
                            generation: generation,
                            messages: resumed.messageCount ?? 0,
                            detail: "success"
                        )
                        guard isCurrent(generation) else {
                            continuation.finish()
                            return
                        }
                    } catch {
                        guard !Task.isCancelled else {
                            terminate("cancelled")
                            continuation.finish()
                            return
                        }
                        TranscriptSwitchTrace.resume(
                            sessionID: sessionID,
                            generation: generation,
                            messages: 0,
                            detail: "failed"
                        )
                        resumeNotice = error.localizedDescription
                        guard isCurrent(generation) else {
                            continuation.finish()
                            return
                        }
                    }
                }

                guard isCurrent(generation) else {
                    continuation.finish()
                    return
                }
                guard CacheFirstOpenPolicy.shouldFetchREST(
                    snapshot: state.cached?.snapshot,
                    serverTotal: serverTotal,
                    resumeMessageCount: state.resumed?.messageCount
                ) else {
                    if mode == .readOnly {
                        continuation.finish()
                        return
                    }
                    continuation.yield(
                        TranscriptOpenResult(
                            liveSessionID: state.resumed?.liveSessionID,
                            messages: state.cached?.messages ?? [],
                            notice: resumeNotice,
                            snapshot: state.cached?.snapshot
                        )
                    )
                    continuation.finish()
                    return
                }
                do {
                    // Keep only the bounded tail for the first frame. A
                    // concrete HistoryCache persists every incoming page in
                    // PagedTranscriptStore before the next page is fetched.
                    let tail = TranscriptTailAccumulator()
                    let compatibility = TranscriptCompatibilityAccumulator()
                    var metadata: AuthoritativeTranscriptMetadata?
                    let initialPageState = TranscriptInitialPageState()
                    metadata = try await source.streamAuthoritative(
                        sessionID: sessionID
                    ) { page in
                        guard self.isCurrent(generation) else {
                            throw CancellationError()
                        }
                        if cacheEnabled,
                           let pagedCache = cache as? any PagedTranscriptPersisting {
                            _ = try await pagedCache.appendTranscriptPage(
                                page,
                                title: sessionTitle,
                                for: sessionID,
                                expectedEpoch: state.cacheEpoch
                            )
                        } else if cacheEnabled,
                                  let pagedCache = cache as? HistoryCache {
                            _ = try await pagedCache.appendTranscriptPage(
                                page,
                                for: sessionID,
                                expectedEpoch: state.cacheEpoch
                            )
                        }
                        guard self.isCurrent(generation) else {
                            throw CancellationError()
                        }
                        compatibility.append(page)
                        tail.append(page.messages)
                        let initialMessages = Self.boundedTail(
                            ChatMessage.projectREST(historyRows: page.messages)
                        )
                        guard !initialMessages.isEmpty,
                              initialPageState.claim()
                        else { return }
                        ownedHandle.setRetainedMessageCount(initialMessages.count)
                        continuation.yield(
                            TranscriptOpenResult(
                                liveSessionID: state.resumed?.liveSessionID,
                                messages: initialMessages,
                                didFetchREST: true,
                                isInitialPage: true
                            )
                        )
                    }
                    guard let metadata, !Task.isCancelled else {
                        terminate("cancelled")
                        continuation.finish()
                        return
                    }
                    let compatibilityRows = compatibility.rows
                    let projectedRows = compatibility.isOversized ? tail.rows : compatibilityRows
                    let projected = ChatMessage.projectREST(historyRows: projectedRows)
                    let published = Self.boundedTail(projected)
                    ownedHandle.setRetainedMessageCount(published.count)
                    let total = metadata.serverTotal ?? serverTotal
                    let snapshot = AuthoritativeTranscriptSnapshot(
                        sessionID: sessionID,
                        serverTotal: total,
                        fetchedRows: metadata.messageCount,
                        projectedMessages: projected.count,
                        truncated: false,
                        fetchedAt: Date()
                    )
                    var cacheStore: CacheStoreResult?
                    // Non-paged third-party caches retain compatibility only
                    // for a single bounded page.
                    if cacheEnabled, !compatibility.isOversized {
                        guard isCurrent(generation) else {
                            continuation.finish()
                            return
                        }
                        cacheStore = try await cache.store(
                            projected,
                            snapshot: snapshot,
                            title: sessionTitle,
                            for: sessionID,
                            expectedEpoch: state.cacheEpoch
                        )
                    }
                    guard isCurrent(generation) else {
                        continuation.finish()
                        return
                    }
                    continuation.yield(
                        TranscriptOpenResult(
                            liveSessionID: state.resumed?.liveSessionID,
                            messages: published,
                            cacheStore: cacheStore,
                            notice: resumeNotice,
                            didFetchREST: true,
                            snapshot: snapshot,
                            summary: TranscriptSummary(
                                rowCount: metadata.messageCount,
                                messageCount: metadata.messageCount,
                                countKind: .exact
                            )
                        )
                    )
                } catch {
                    guard !Task.isCancelled, isCurrent(generation) else {
                        terminate("cancelled")
                        continuation.finish()
                        return
                    }
                    continuation.yield(
                        TranscriptOpenResult(
                            liveSessionID: state.resumed?.liveSessionID,
                            messages: Self.boundedTail(state.cached?.messages ?? []),
                            notice: error.localizedDescription,
                            didFetchREST: true,
                            snapshot: state.cached?.snapshot
                        )
                    )
                }
                continuation.finish()
            }
            taskRef.set(task)
            let cancel: @Sendable () -> Void = {
                terminate("cancelled")
                continuation.finish()
            }
            ownedHandle.install(cancel)
            continuation.onTermination = { _ in cancel() }
        }
    }

    /// Final-phase convenience for read-only browsing.
    public func open(
        sessionID: String,
        serverTotal: Int?,
        generation: Int,
        sessionTitle: String
    ) async -> TranscriptOpenResult? {
        var final: TranscriptOpenResult?
        for await result in openPhases(
            sessionID: sessionID,
            serverTotal: serverTotal,
            generation: generation,
            sessionTitle: sessionTitle
        ) {
            final = result
        }
        guard isCurrent(generation) else { return nil }
        return final
    }

    /// Final-phase convenience for an interaction that needs a live session.
    public func openForInteraction(
        sessionID: String,
        serverTotal: Int?,
        generation: Int,
        sessionTitle: String
    ) async -> TranscriptOpenResult? {
        var final: TranscriptOpenResult?
        for await result in openInteractionPhases(
            sessionID: sessionID,
            serverTotal: serverTotal,
            generation: generation,
            sessionTitle: sessionTitle
        ) {
            final = result
        }
        guard isCurrent(generation) else { return nil }
        return final
    }

    public func reconcileTerminal(
        sessionID: String?,
        serverTotal: Int?,
        currentMessages: [ChatMessage],
        generation: Int,
        sessionTitle: String
    ) async -> TranscriptReconciliationResult? {
        guard isCurrent(generation) else { return nil }
        guard let sessionID else {
            return TranscriptReconciliationResult(
                messages: currentMessages,
                requiresSessionRefresh: true
            )
        }
        let cacheEpoch = cacheEnabled ? await cache.currentEpoch() : nil
        do {
            let tail = TranscriptTailAccumulator()
            let compatibility = TranscriptCompatibilityAccumulator()
            let metadata = try await source.streamAuthoritative(sessionID: sessionID) { page in
                try Task.checkCancellation()
                guard self.isCurrent(generation) else { throw CancellationError() }
                if cacheEnabled,
                   let pagedCache = cache as? any PagedTranscriptPersisting {
                    _ = try await pagedCache.appendTranscriptPage(
                        page,
                        title: sessionTitle,
                        for: sessionID,
                        expectedEpoch: cacheEpoch
                    )
                } else if cacheEnabled,
                          let pagedCache = cache as? HistoryCache {
                    _ = try await pagedCache.appendTranscriptPage(
                        page,
                        for: sessionID,
                        expectedEpoch: cacheEpoch
                    )
                }
                guard self.isCurrent(generation) else {
                    throw CancellationError()
                }
                compatibility.append(page)
                tail.append(page.messages)
            }
            guard isCurrent(generation) else { return nil }
            let compatibilityRows = compatibility.rows
            let projectedRows = compatibility.isOversized ? tail.rows : compatibilityRows
            let projected = ChatMessage.projectREST(historyRows: projectedRows)
            let published = Self.boundedTail(projected)
            let total = metadata.serverTotal ?? serverTotal
            let snapshot = AuthoritativeTranscriptSnapshot(
                sessionID: sessionID,
                serverTotal: total,
                fetchedRows: metadata.messageCount,
                projectedMessages: projected.count,
                truncated: false,
                fetchedAt: Date()
            )
            var cacheStore: CacheStoreResult?
            if cacheEnabled, !compatibility.isOversized {
                cacheStore = try await cache.store(
                    projected,
                    snapshot: snapshot,
                    title: sessionTitle,
                    for: sessionID,
                    expectedEpoch: cacheEpoch
                )
            }
            guard isCurrent(generation) else { return nil }
            return TranscriptReconciliationResult(
                messages: published,
                cacheStore: cacheStore,
                snapshot: snapshot
            )
        } catch {
            guard isCurrent(generation) else { return nil }
            // A failed REST reconciliation retains the already displayed
            // transcript and leaves its prior cache snapshot untouched.
            return TranscriptReconciliationResult(
                messages: Self.boundedTail(currentMessages),
                notice: error.localizedDescription
            )
        }
    }

    private static func boundedTail(_ messages: [ChatMessage]) -> [ChatMessage] {
        Array(messages.suffix(TranscriptPublicationPolicy.initialMessageCount))
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && generations.isCurrent(generation)
    }
}
