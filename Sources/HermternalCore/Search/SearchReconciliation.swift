import Foundation


/// Core-owned policy boundary between HistoryCache and SearchIndex.
///
/// Transcript persistence must go through `store(_:snapshot:title:for:)` or
/// `storeForWarming(_:snapshot:title:for:)`, and cache deletion/clear must go
/// through `remove(sessionID:)`/`clear()`. This
/// keeps adapters from having to remember a second UI-side indexing call. The
/// coordinator is deliberately an actor: cache epoch checks and the resulting
/// index mutation are serialized here, so a clear cannot be followed by an
/// index write derived from an older read.
public actor SearchIndexReconciliation: TranscriptPersisting {
    private let cache: HistoryCache
    private let index: SearchIndex
    private var degraded = false

    public init(cache: HistoryCache, index: SearchIndex) {
        self.cache = cache
        self.index = index
    }
    public func isDegraded() -> Bool { degraded }

    private func recordIndexFailure(_ error: Error, operation: String) {
        degraded = true
        Log.error("Search index \(operation) failed; transcript persistence remains authoritative: \(error.localizedDescription)")
    }
    public func read(for id: String) async -> (transcript: CachedTranscript?, epoch: UInt64) {
        await cache.read(for: id)
    }
    public func readForWarming(for id: String) async -> (transcript: CachedTranscript?, epoch: UInt64) {
        await cache.readForWarming(for: id)
    }

    public func currentEpoch() async -> UInt64 {
        await cache.currentEpoch()
    }


    /// Stores the authoritative cache payload and immediately replaces the
    /// corresponding durable rows. Provisional live rows are filtered before
    /// they can reach SearchIndex.
    @discardableResult
    public func store(
        _ messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot?,
        title: String,
        for sessionID: String,
        expectedEpoch: UInt64? = nil
    ) async -> CacheStoreResult {
        let result = await cache.store(messages, snapshot: snapshot, for: sessionID, expectedEpoch: expectedEpoch)
        guard snapshot != nil, !Task.isCancelled else { return result }
        _ = await reconcile(sessionID: sessionID, title: title, expectedEpoch: expectedEpoch)
        return result
    }

    /// Stores and indexes a warm payload without causing HistoryCache to
    /// retain the decoded transcript in its ordinary-open LRU.
    @discardableResult
    public func storeForWarming(
        _ messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot?,
        title: String,
        for sessionID: String,
        expectedEpoch: UInt64? = nil
    ) async -> CacheStoreResult {
        let result = await cache.storeForWarming(
            messages,
            snapshot: snapshot,
            title: title,
            for: sessionID,
            expectedEpoch: expectedEpoch
        )
        guard snapshot != nil, !Task.isCancelled else { return result }
        if let expectedEpoch,
           await cache.currentEpoch() != expectedEpoch {
            return result
        }
        _ = await reconcilePayload(
            messages: messages,
            snapshot: snapshot,
            sessionID: sessionID,
            title: title
        )
        return result
    }

    private func reconcilePayload(
        messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot?,
        sessionID: String,
        title: String
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let snapshot, snapshot.sessionID == sessionID else {
            do { try await index.remove(sessionID: sessionID) }
            catch { recordIndexFailure(error, operation: "remove") }
            return false
        }

        let documents = messages.compactMap { message -> SearchDocument? in
            guard case .server(let messageID) = message.id else { return nil }
            return SearchDocument(messageID: messageID, body: message.text, role: message.role, timestamp: message.timestamp)
        }
        do {
            try await index.replace(SearchSessionSnapshot(
                sessionID: sessionID,
                title: title,
                documents: documents,
                truncated: snapshot.truncated
            ))
            return true
        } catch {
            recordIndexFailure(error, operation: "replace")
            return false
        }
    }

    /// Reconciles a cache entry that was already stored. A read from a
    /// superseded epoch is a no-op, never an index write.
    @discardableResult
    public func reconcile(
        sessionID: String,
        title: String,
        expectedEpoch: UInt64? = nil
    ) async -> Bool {
        let read = await cache.read(for: sessionID)
        if let expectedEpoch, expectedEpoch != read.epoch { return false }
        return await reconcilePayload(
            messages: read.transcript?.messages ?? [],
            snapshot: read.transcript?.snapshot,
            sessionID: sessionID,
            title: title
        )
    }

    /// Removes one cache entry and its search rows as one typed operation.
    /// Each store reports its own outcome, so callers can distinguish a
    /// durable cache failure from an index failure.
    public func remove(sessionID: String) async -> SessionLocalCleanupResult {
        let cacheResult = await cache.remove(sessionID: sessionID)

        let indexOutcome: SessionLocalCleanupResult.Outcome
        do {
            try await index.remove(sessionID: sessionID)
            indexOutcome = .removed
        } catch {
            recordIndexFailure(error, operation: "remove")
            indexOutcome = .failed(error.localizedDescription)
        }
        return SessionLocalCleanupResult(
            sessionID: sessionID,
            cache: cacheResult.cache,
            index: indexOutcome
        )
    }

    /// Clears both stores. The index is cleared only when HistoryCache's epoch
    /// advancing clear actually succeeded.
    @discardableResult
    public func clear() async -> Bool {
        guard await cache.clear() else { return false }
        do { try await index.clear() }
        catch { recordIndexFailure(error, operation: "clear") }
        return true
    }


    public func reconcile(validIDs: [String]) async -> CacheStatistics {
        let statistics = await cache.reconcile(validIDs: validIDs)
        do {
            let indexed = try await index.indexedSessionIDs()
            let valid = Set(validIDs)
            for sessionID in indexed where !valid.contains(sessionID) {
                try await index.remove(sessionID: sessionID)
            }
            try await index.markUnwarmed(sessionIDs: validIDs)
        } catch {
            recordIndexFailure(error, operation: "reconcile")
        }
        return statistics
    }
}
