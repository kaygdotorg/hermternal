import Foundation

/// A durable transcript that should be reconciled with the upstream history.
///
/// Requests intentionally carry only immutable session metadata. Selection is
/// not part of this seam: callers may enqueue any sessions in response to an
/// update or an explicit refresh without coupling syncing to sidebar opens.
public struct TranscriptSyncRequest: Sendable, Equatable {
    public let id: String
    public let serverTotal: Int?
    public let title: String
    public let forceRefresh: Bool

    public init(
        id: String,
        serverTotal: Int?,
        title: String,
        forceRefresh: Bool = false
    ) {
        self.id = id
        self.serverTotal = serverTotal
        self.title = title
        self.forceRefresh = forceRefresh
    }
}

/// The result of one successful sync item. AppModel owns UI publication and
/// warm-store publication; this value only crosses the background seam.
public struct TranscriptSyncResult: Sendable {
    public let id: String
    public let title: String
    public let messages: [ChatMessage]
    public let snapshot: AuthoritativeTranscriptSnapshot
    public let cacheStore: CacheStoreResult?
    /// Number of non-streaming assistant rows whose Markdown was segmented
    /// before this result crossed back to the main actor.
    public let presegmentedRows: Int

    public init(
        id: String,
        title: String,
        messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot,
        cacheStore: CacheStoreResult?,
        presegmentedRows: Int = 0
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.snapshot = snapshot
        self.cacheStore = cacheStore
        self.presegmentedRows = presegmentedRows
    }
}

/// Segments only the rows that the first transcript frame will render. This
/// function is called from the coordinator's non-main-actor worker closure,
/// before AppModel publishes the projection into the warm store.
private func presegmentInitialWindow(_ messages: [ChatMessage]) -> Int? {
    let start = max(0, messages.count - TranscriptWindowPolicy.initialWindowSize)
    var segmentedRows = 0
    for message in messages[start...] {
        guard !Task.isCancelled else { return nil }
        guard message.role == .assistant, !message.isStreaming else { continue }
        _ = MarkdownSegment.parse(
            message.text,
            owner: .backgroundPrefetch
        )
        segmentedRows += 1
    }
    return segmentedRows
}

/// Reconciles durable transcript cache entries with upstream history without
/// registering live gateway sessions.
///
/// This is deliberately a value-type façade over the existing bounded worker.
/// It owns no AppModel state and delivers partial results when cancellation or
/// a cache epoch change supersedes the pass. The caller decides which results
/// remain relevant to the current selection/generation before publishing them.
public struct TranscriptSyncCoordinator: Sendable {
    public let concurrency: Int
    private let lanes: BoundedPrefetchCoordinator

    public init(concurrency: Int = 4) {
        let bounded = BoundedPrefetchCoordinator(limit: concurrency)
        self.concurrency = bounded.limit
        self.lanes = bounded
    }

    /// Reconciles requests against cache and authoritative REST history,
    /// delivering each completed item directly to `onResult`.
    ///
    /// A complete cache hit is returned without a network call unless the
    /// request explicitly forces refresh. Missing/incomplete/growing entries
    /// use `fetchAuthoritative`; `resume` is never called here. Cache writes
    /// flow through `storeForWarming`, so decorated caches update search too.
    public func reconcile(
        _ requests: [TranscriptSyncRequest],
        cache: any TranscriptPersisting,
        source: any TranscriptSource,
        onResult: @escaping @Sendable (TranscriptSyncResult) async -> Void
    ) async {
        guard !requests.isEmpty, !Task.isCancelled else { return }
        let expectedEpoch = await cache.currentEpoch()
        guard !Task.isCancelled else { return }

        await lanes.prefetch(
            requests,
            operation: { request in
                ContentionTrace.beginBackgroundWork()
                defer { ContentionTrace.endBackgroundWork() }
                guard !Task.isCancelled else { return nil }
                let read = await cache.readForWarming(for: request.id)
                guard !Task.isCancelled else { return nil }
                guard read.epoch == expectedEpoch,
                      await cache.currentEpoch() == expectedEpoch,
                      !Task.isCancelled
                else { return nil }

                let cached = read.transcript
                let shouldFetch = request.forceRefresh
                    || CacheFirstOpenPolicy.shouldFetchREST(
                        snapshot: cached?.snapshot,
                        serverTotal: request.serverTotal
                    )

                if !shouldFetch,
                   let cached,
                   let snapshot = cached.snapshot,
                   snapshot.sessionID == request.id,
                   snapshot.projectedMessages == cached.messages.count {
                    guard let presegmentedRows = presegmentInitialWindow(cached.messages) else {
                        return nil
                    }
                    return TranscriptSyncResult(
                        id: request.id,
                        title: request.title,
                        messages: cached.messages,
                        snapshot: snapshot,
                        cacheStore: nil,
                        presegmentedRows: presegmentedRows
                    )
                }

                guard let authoritative = try? await source.fetchAuthoritative(sessionID: request.id),
                      !Task.isCancelled
                else { return nil }
                let projected = ChatMessage.projectREST(historyRows: authoritative.rows)
                let snapshot = CacheFirstOpenPolicy.snapshot(
                    sessionID: request.id,
                    rows: authoritative.rows,
                    projectedMessages: projected.count,
                    serverTotal: authoritative.serverTotal ?? request.serverTotal
                )
                guard !Task.isCancelled,
                      await cache.currentEpoch() == expectedEpoch
                else { return nil }
                let stored = try? await cache.storeForWarming(
                    projected,
                    snapshot: snapshot,
                    title: request.title,
                    for: request.id,
                    expectedEpoch: expectedEpoch
                )
                guard !Task.isCancelled,
                      await cache.currentEpoch() == expectedEpoch
                else { return nil }
                guard let presegmentedRows = presegmentInitialWindow(projected) else {
                    return nil
                }
                return TranscriptSyncResult(
                    id: request.id,
                    title: request.title,
                    messages: projected,
                    snapshot: snapshot,
                    cacheStore: stored,
                    presegmentedRows: presegmentedRows
                )
            },
            onResult: onResult
        )
    }
}
