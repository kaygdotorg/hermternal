import Foundation

public enum CacheFirstOpenPolicy {
    /// A missing snapshot always requires an authoritative REST read. A
    /// truncated snapshot is trusted until the next explicit session-list
    /// refresh; reopening must not repeat the capped request.
    public static func shouldFetchREST(
        snapshot: AuthoritativeTranscriptSnapshot?,
        serverTotal: Int?,
        resumeMessageCount: Int? = nil,
        resumeMessagesOmitted: Int? = nil
    ) -> Bool {
        guard let snapshot else { return true }
        guard !snapshot.truncated else { return false }
        let knownTotal = max(
            serverTotal ?? 0,
            snapshot.serverTotal ?? 0,
            resumeMessageCount ?? 0
        )
        return knownTotal > snapshot.fetchedRows || (resumeMessagesOmitted ?? 0) > 0
    }

    public static func snapshot(
        sessionID: String,
        rows: [JSONValue],
        projectedMessages: Int,
        serverTotal: Int?,
        fetchedAt: Date = Date()
    ) -> AuthoritativeTranscriptSnapshot {
        let truncated: Bool
        if let serverTotal {
            truncated = serverTotal > rows.count
        } else {
            truncated = rows.count >= 500
        }
        return AuthoritativeTranscriptSnapshot(
            sessionID: sessionID,
            serverTotal: serverTotal,
            fetchedRows: rows.count,
            projectedMessages: projectedMessages,
            truncated: truncated,
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

public struct TranscriptOpenResult: Sendable {
    public let liveSessionID: String?
    public let messages: [ChatMessage]
    public let cacheStore: CacheStoreResult?
    public let notice: String?
    public let didFetchREST: Bool
    /// True only for the immediate cache-first paint; later phases are
    /// authoritative and may intentionally carry a nil live id on failure.
    public let isCachedPhase: Bool

    public init(
        liveSessionID: String?,
        messages: [ChatMessage],
        cacheStore: CacheStoreResult? = nil,
        notice: String? = nil,
        didFetchREST: Bool = false,
        isCachedPhase: Bool = false
    ) {
        self.liveSessionID = liveSessionID
        self.messages = messages
        self.cacheStore = cacheStore
        self.notice = notice
        self.didFetchREST = didFetchREST
        self.isCachedPhase = isCachedPhase
    }
}

public struct TranscriptReconciliationResult: Sendable {
    public let messages: [ChatMessage]
    public let cacheStore: CacheStoreResult?
    public let notice: String?
    /// A first turn has no durable id; the caller should refresh its sidebar.
    public let requiresSessionRefresh: Bool

    public init(
        messages: [ChatMessage],
        cacheStore: CacheStoreResult? = nil,
        notice: String? = nil,
        requiresSessionRefresh: Bool = false
    ) {
        self.messages = messages
        self.cacheStore = cacheStore
        self.notice = notice
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

    /// Opens a transcript as a stream of progressively stronger results.
    ///
    /// A provisional phase (cached messages, or empty when unavailable) is
    /// yielded before any resume or REST await. The subsequent result carries
    /// the live session id and, when needed, the authoritative REST projection.
    /// `sessionTitle` is the authoritative session-list title used by the
    /// search index digest. Keeping it unchanged avoids an FTS rewrite;
    /// changing it intentionally refreshes title-bearing rows.
    public func openPhases(
        sessionID: String,
        serverTotal: Int?,
        generation: Int,
        sessionTitle: String
    ) -> AsyncStream<TranscriptOpenResult> {
        AsyncStream { continuation in
            let task = Task {
                let cached: CachedTranscript?
                let cacheEpoch: UInt64?
                if cacheEnabled {
                    let read = await cache.read(for: sessionID)
                    cached = read.transcript
                    cacheEpoch = read.epoch
                } else {
                    cached = nil
                    cacheEpoch = nil
                }
                guard isCurrent(generation) else {
                    continuation.finish()
                    return
                }
                continuation.yield(
                    TranscriptOpenResult(
                        liveSessionID: nil,
                        messages: cached?.messages ?? [],
                        isCachedPhase: true
                    )
                )

                var liveSessionID: String?
                var resumeNotice: String?
                var resumed: ResumedTranscript?
                do {
                    resumed = try await source.resume(sessionID: sessionID)
                    guard isCurrent(generation) else {
                        continuation.finish()
                        return
                    }
                    liveSessionID = resumed?.liveSessionID
                } catch {
                    guard isCurrent(generation) else {
                        continuation.finish()
                        return
                    }
                    resumeNotice = error.localizedDescription
                }

                guard isCurrent(generation) else {
                    continuation.finish()
                    return
                }
                guard CacheFirstOpenPolicy.shouldFetchREST(
                    snapshot: cached?.snapshot,
                    serverTotal: serverTotal,
                    resumeMessageCount: resumed?.messageCount,
                    resumeMessagesOmitted: resumed?.messagesOmitted
                ) else {
                    continuation.yield(
                        TranscriptOpenResult(
                            liveSessionID: liveSessionID,
                            messages: cached?.messages ?? [],
                            notice: resumeNotice
                        )
                    )
                    continuation.finish()
                    return
                }

                do {
                    let authoritative = try await source.fetchAuthoritative(sessionID: sessionID)
                    guard isCurrent(generation) else {
                        continuation.finish()
                        return
                    }
                    let total = authoritative.serverTotal ?? serverTotal
                    let projected = ChatMessage.projectREST(historyRows: authoritative.rows)
                    let snapshot = CacheFirstOpenPolicy.snapshot(
                        sessionID: sessionID,
                        rows: authoritative.rows,
                        projectedMessages: projected.count,
                        serverTotal: total
                    )
                    var cacheStore: CacheStoreResult?
                    if cacheEnabled {
                        guard isCurrent(generation) else {
                            continuation.finish()
                            return
                        }
                        cacheStore = try await cache.store(
                            projected,
                            snapshot: snapshot,
                            title: sessionTitle,
                            for: sessionID,
                            expectedEpoch: cacheEpoch
                        )
                        guard isCurrent(generation) else {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.yield(
                        TranscriptOpenResult(
                            liveSessionID: liveSessionID,
                            messages: projected,
                            cacheStore: cacheStore,
                            notice: resumeNotice,
                            didFetchREST: true
                        )
                    )
                } catch {
                    guard isCurrent(generation) else {
                        continuation.finish()
                        return
                    }
                    continuation.yield(
                        TranscriptOpenResult(
                            liveSessionID: liveSessionID,
                            messages: cached?.messages ?? [],
                            notice: error.localizedDescription,
                            didFetchREST: true
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Compatibility convenience for callers that only need the final phase.
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
            let authoritative = try await source.fetchAuthoritative(sessionID: sessionID)
            guard isCurrent(generation) else { return nil }
            let total = authoritative.serverTotal ?? serverTotal
            let projected = ChatMessage.projectREST(historyRows: authoritative.rows)
            let snapshot = CacheFirstOpenPolicy.snapshot(
                sessionID: sessionID,
                rows: authoritative.rows,
                projectedMessages: projected.count,
                serverTotal: total
            )
            var cacheStore: CacheStoreResult?
            if cacheEnabled {
                guard isCurrent(generation) else { return nil }
                cacheStore = try await cache.store(
                    projected,
                    snapshot: snapshot,
                    title: sessionTitle,
                    for: sessionID,
                    expectedEpoch: cacheEpoch
                )
                guard isCurrent(generation) else { return nil }
            }
            return TranscriptReconciliationResult(
                messages: projected,
                cacheStore: cacheStore
            )
        } catch {
            guard isCurrent(generation) else { return nil }
            // A failed REST reconciliation retains the already displayed
            // transcript and leaves its prior cache snapshot untouched.
            return TranscriptReconciliationResult(
                messages: currentMessages,
                notice: error.localizedDescription
            )
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && generations.isCurrent(generation)
    }
}
