import Foundation

private final class SyncTailAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [JSONValue] = []

    func append(_ page: [JSONValue]) {
        lock.lock()
        rows.append(contentsOf: page)
        let overflow = rows.count - TranscriptPublicationPolicy.initialMessageCount
        if overflow > 0 { rows.removeFirst(overflow) }
        lock.unlock()
    }

    var value: [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }
}
private final class SyncCompatibilityAccumulator: @unchecked Sendable {
    static let maximumBytes = 16 * 1024 * 1024
    private let lock = NSLock()
    private var rows: [JSONValue] = []
    private var bytes = 0
    private var oversized = false

    func append(_ page: TranscriptMessagePage) {
        lock.lock()
        defer { lock.unlock() }
        guard !oversized else { return }
        let estimated = page.messages.reduce(into: 0) { total, value in
            total += Self.estimatedBytes(value)
        }
        let amount = max(page.byteCount, estimated)
        guard amount <= Self.maximumBytes - min(bytes, Self.maximumBytes) else {
            rows.removeAll(keepingCapacity: false)
            oversized = true
            return
        }
        bytes += amount
        rows.append(contentsOf: page.messages)
    }

    var value: [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }

    var isOversized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return oversized
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
private func presegmentInitialPublication(_ messages: [ChatMessage]) -> Int? {
    let start = max(0, messages.count - TranscriptPublicationPolicy.initialMessageCount)
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
                    let tail = Array(cached.messages.suffix(TranscriptPublicationPolicy.initialMessageCount))
                    guard let presegmentedRows = presegmentInitialPublication(tail) else {
                        return nil
                    }
                    return TranscriptSyncResult(
                        id: request.id,
                        title: request.title,
                        messages: tail,
                        snapshot: snapshot,
                        cacheStore: nil,
                        presegmentedRows: presegmentedRows
                    )
                }
                let compatibility = SyncCompatibilityAccumulator()

                let tail = SyncTailAccumulator()
                let metadata: AuthoritativeTranscriptMetadata
                do {
                    metadata = try await source.streamAuthoritative(sessionID: request.id) { page in
                        try Task.checkCancellation()
                        if let pagedCache = cache as? HistoryCache {
                            _ = try await pagedCache.appendTranscriptPage(
                                page,
                                for: request.id,
                                expectedEpoch: expectedEpoch
                            )
                        }
                        compatibility.append(page)
                        tail.append(page.messages)
                    }
                } catch {
                    return nil
                }
                guard !Task.isCancelled,
                      await cache.currentEpoch() == expectedEpoch
                else { return nil }
                let compatibilityRows = compatibility.value
                let projectedRows = compatibility.isOversized ? tail.value : compatibilityRows
                let projected = ChatMessage.projectREST(historyRows: projectedRows)
                let snapshot = AuthoritativeTranscriptSnapshot(
                    sessionID: request.id,
                    serverTotal: metadata.serverTotal ?? request.serverTotal,
                    fetchedRows: metadata.messageCount,
                    projectedMessages: projected.count,
                    truncated: false,
                    fetchedAt: Date()
                )
                let stored: CacheStoreResult?
                if !compatibility.isOversized {
                    stored = try? await cache.storeForWarming(
                        projected,
                        snapshot: snapshot,
                        title: request.title,
                        for: request.id,
                        expectedEpoch: expectedEpoch
                    )
                } else {
                    stored = nil
                }
                guard !Task.isCancelled,
                      await cache.currentEpoch() == expectedEpoch
                else { return nil }
                guard let presegmentedRows = presegmentInitialPublication(projected) else {
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
