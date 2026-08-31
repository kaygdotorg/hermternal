import Foundation

/// Extended persistence seam for bounded transcript ingestion.
public protocol PagedTranscriptPersisting: TranscriptPersisting {
    func appendTranscriptPage(
        _ page: TranscriptMessagePage,
        title: String,
        for sessionID: String,
        expectedEpoch: UInt64?
    ) async throws -> TranscriptSummary
    func pagedSummary(for sessionID: String) async throws -> TranscriptSummary
}


/// Core-owned policy boundary between HistoryCache and SearchIndex.
///
/// Transcript persistence must go through `store(_:snapshot:title:for:)` or
/// `storeForWarming(_:snapshot:title:for:)`, and cache deletion/clear must go
/// through `remove(sessionID:)`/`clear()`. This
/// keeps adapters from having to remember a second UI-side indexing call. The
/// coordinator is deliberately an actor: cache epoch checks and the resulting
/// index mutation are serialized here, so a clear cannot be followed by an
/// index write derived from an older read.
public actor SearchIndexReconciliation: PagedTranscriptPersisting {
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
            title: title,
            expectedEpoch: expectedEpoch
        )
        return result
    }

    private func reconcilePayload(
        messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot?,
        sessionID: String,
        title: String,
        expectedEpoch: UInt64? = nil
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let expectedEpoch, await cache.currentEpoch() != expectedEpoch { return false }
        guard let snapshot, snapshot.sessionID == sessionID else {
            do { try await index.remove(sessionID: sessionID) }
            catch { recordIndexFailure(error, operation: "remove") }
            return false
        }

        do {
            // Use a paged store only after the append flow created it.
            // Indexing must not migrate the authoritative raw cache payload.
            if let paged = await cache.existingPagedStore(for: sessionID),
               let pagedSummary = try? await paged.summary(),
               (pagedSummary.messageCount > 0 || messages.isEmpty) {
                let pages: @Sendable () -> AsyncThrowingStream<SearchDocumentPage, Error> = {
                    let cursor = PagedSearchReplayCursor(store: paged, summary: pagedSummary)
                    return SearchReplayStream.demandDriven {
                        try await cursor.next()
                    }
                }
                try await index.replacePaged(
                    sessionID: sessionID,
                    title: title,
                    truncated: snapshot.truncated,
                    pages: pages
                )
            } else {
                let documents = messages.compactMap { message -> SearchDocument? in
                    guard case .server(let messageID) = message.id else { return nil }
                    return SearchDocument(messageID: messageID, body: message.text, role: message.role, timestamp: message.timestamp)
                }
                try await index.replace(SearchSessionSnapshot(
                    sessionID: sessionID,
                    title: title,
                    documents: documents,
                    truncated: snapshot.truncated
                ))
            }
            return true
        } catch {
            recordIndexFailure(error, operation: "replace")
            return false
        }
    }

    /// Forwards a bounded transcript page through the decorator.
    @discardableResult
    public func appendTranscriptPage(
        _ page: TranscriptMessagePage,
        title: String,
        for sessionID: String,
        expectedEpoch: UInt64? = nil
    ) async throws -> TranscriptSummary {
        let appendResult = try await cache.appendTranscriptPage(page, for: sessionID, expectedEpoch: expectedEpoch)
        let documents = appendResult.appliedRecords.compactMap { record -> SearchDocument? in
            guard record.isSearchable,
                  let messageID = Int64(record.messageID),
                  let role = Role(rawValue: record.role)
            else { return nil }
            return SearchDocument(
                messageID: ServerMessageID(rawValue: messageID),
                body: record.text,
                role: role,
                timestamp: record.timestamp,
                displayKind: record.displayKind,
                isTool: record.isToolEvent
            )
        }
        do {
            try await index.append(
                SearchDocumentPage(documents: documents),
                sessionID: sessionID,
                title: title
            )
        } catch {
            recordIndexFailure(error, operation: "append")
        }
        return appendResult.summary
    }

    public func pagedSummary(for sessionID: String) async throws -> TranscriptSummary {
        try await cache.pagedSummary(for: sessionID)
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
            title: title,
            expectedEpoch: expectedEpoch
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

internal enum SearchReplayStream {
    static func demandDriven(
        _ next: @escaping @Sendable () async throws -> SearchDocumentPage?
    ) -> AsyncThrowingStream<SearchDocumentPage, Error> {
        AsyncThrowingStream(unfolding: next)
    }
}

private actor PagedSearchReplayCursor {
    private let store: PagedTranscriptStore
    private let summary: TranscriptSummary
    private var ordinal = 0
    private var previousMessageID: String?
    private var finished = false

    init(store: PagedTranscriptStore, summary: TranscriptSummary) {
        self.store = store
        self.summary = summary
    }

    func next() async throws -> SearchDocumentPage? {
        guard !finished else { return nil }
        try Task.checkCancellation()
        let page = try await store.page(TranscriptPageRequest(
            startOrdinal: ordinal,
            maximumBytes: TranscriptPageRequest.hardMaximumBytes,
            maximumRows: TranscriptPageRequest.hardMaximumRows,
            expectedGeneration: summary.generation,
            expectedEpoch: summary.epoch
        ))
        ordinal = page.nextOrdinal
        finished = !page.hasMore

        var documents: [SearchDocument] = []
        documents.reserveCapacity(page.rows.count)
        for row in page.rows {
            let record = row.message
            guard record.messageID != previousMessageID else { continue }
            previousMessageID = record.messageID
            guard record.isSearchable,
                  let messageID = Int64(record.messageID),
                  let role = Role(rawValue: record.role)
            else { continue }
            documents.append(SearchDocument(
                messageID: ServerMessageID(rawValue: messageID),
                body: record.text,
                role: role,
                timestamp: record.timestamp,
                displayKind: record.displayKind,
                isTool: record.isToolEvent
            ))
        }
        return SearchDocumentPage(documents: documents)
    }
}
