import Foundation

/// A complete transcript that can be applied synchronously while a chat opens.
///
/// The message array is a value type backed by copy-on-write storage. Reading a
/// projection does not deep-copy message bodies or the array's elements.
public struct WarmTranscriptProjection: Sendable {
    public let messages: [ChatMessage]
    public let snapshot: AuthoritativeTranscriptSnapshot
    /// Bytes charged against the store budget for this projection.
    public let retainedBytes: Int

    internal init(
        messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot,
        retainedBytes: Int
    ) {
        self.messages = messages
        self.snapshot = snapshot
        self.retainedBytes = retainedBytes
    }
}

/// A bounded, synchronous cache of complete transcript projections.
///
/// The store is deliberately lock-backed rather than actor-backed: callers on
/// the main actor need a warm projection in the same turn as selection changes.
/// Every operation is thread-safe, and lock critical sections contain only
/// dictionary/accounting work. The default budget is a conservative 128 MiB
/// charge for decoded transcript values, message text, metadata, and the LRU
/// entry structures.
public final class TranscriptWarmStore: @unchecked Sendable {
    public static let defaultBudgetBytes = 128 * 1024 * 1024

    public struct Metrics: Sendable, Equatable {
        public let projectionCount: Int
        public let retainedBytes: Int

        public init(projectionCount: Int, retainedBytes: Int) {
            self.projectionCount = projectionCount
            self.retainedBytes = retainedBytes
        }
    }

    private struct Entry {
        let projection: WarmTranscriptProjection
        var previousID: String?
        var nextID: String?
    }

    private let lock = NSLock()
    public let budgetBytes: Int
    private var entries: [String: Entry] = [:]
    private var retainedBytes = 0
    private var lruHead: String?
    private var lruTail: String?


    public init(budgetBytes: Int = TranscriptWarmStore.defaultBudgetBytes) {
        precondition(budgetBytes > 0, "Transcript warm-store budget must be positive")
        self.budgetBytes = budgetBytes
    }

    /// Publishes a projection only when its snapshot proves a complete
    /// authoritative transcript for `sessionID`.
    ///
    /// `minimumServerTotal` lets a caller reject a cache value that predates a
    /// newer session-list total. A replacement is atomic: if it is invalid or
    /// oversized, the existing projection remains available.
    @discardableResult
    public func publish(
        messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot,
        for sessionID: String,
        minimumServerTotal: Int? = nil
    ) -> Bool {
        guard Self.isComplete(
            snapshot: snapshot,
            for: sessionID,
            minimumServerTotal: minimumServerTotal
        ),
        snapshot.projectedMessages == messages.count
        else {
            return false
        }
        let cost = Self.retainedBytes(
            messages: messages,
            snapshot: snapshot,
            sessionID: sessionID
        )
        guard cost <= budgetBytes else {
            return false
        }

        let projection = WarmTranscriptProjection(
            messages: messages,
            snapshot: snapshot,
            retainedBytes: cost
        )

        var contentionRequest = ContentionTrace.beginInteractive(
            resource: "warm-store",
            owner: .warmStore
        )
        let lockStartedAt = contentionRequest == nil
            ? 0
            : DispatchTime.now().uptimeNanoseconds
        lock.lock()
        ContentionTrace.recordLockWait(&contentionRequest, startedAt: lockStartedAt)
        defer {
            lock.unlock()
            ContentionTrace.finishInteractive(&contentionRequest)
        }

        // Replace in place, then append the new entry as most recently used.
        if let old = removeEntry(for: sessionID) {
            retainedBytes -= old.projection.retainedBytes
        }
        insertEntry(projection, for: sessionID)
        retainedBytes += cost
        evictIfNeeded(protecting: sessionID)
        return entries[sessionID] != nil
    }

    /// Snapshot-first spelling for callers that build authoritative metadata
    /// before the projected message array.
    @discardableResult
    public func publish(
        snapshot: AuthoritativeTranscriptSnapshot,
        messages: [ChatMessage],
        for sessionID: String,
        minimumServerTotal: Int? = nil
    ) -> Bool {
        publish(
            messages: messages,
            snapshot: snapshot,
            for: sessionID,
            minimumServerTotal: minimumServerTotal
        )
    }

    /// Returns a complete projection synchronously and records an access for LRU.
    /// A projection that no longer satisfies `minimumServerTotal` is not
    /// returned, but remains stored so a lower requirement can still use it.
    public func projection(
        for sessionID: String,
        minimumServerTotal: Int? = nil
    ) -> WarmTranscriptProjection? {
        var contentionRequest = ContentionTrace.beginInteractive(
            resource: "warm-store",
            owner: .warmStore
        )
        let lockStartedAt = contentionRequest == nil
            ? 0
            : DispatchTime.now().uptimeNanoseconds
        lock.lock()
        ContentionTrace.recordLockWait(&contentionRequest, startedAt: lockStartedAt)
        defer {
            lock.unlock()
            ContentionTrace.finishInteractive(&contentionRequest)
        }
        guard let entry = entries[sessionID],
              Self.isComplete(
                  snapshot: entry.projection.snapshot,
                  for: sessionID,
                  minimumServerTotal: minimumServerTotal
              )
        else {
            return nil
        }
        _ = removeEntry(for: sessionID)
        insertEntry(entry.projection, for: sessionID)
        return entry.projection
    }

    /// Removes the specified sessions from the warm map.
    public func remove(sessionIDs: Set<String>) {
        var contentionRequest = ContentionTrace.beginInteractive(
            resource: "warm-store",
            owner: .warmStore
        )
        let lockStartedAt = contentionRequest == nil
            ? 0
            : DispatchTime.now().uptimeNanoseconds
        lock.lock()
        ContentionTrace.recordLockWait(&contentionRequest, startedAt: lockStartedAt)
        defer {
            lock.unlock()
            ContentionTrace.finishInteractive(&contentionRequest)
        }
        for sessionID in sessionIDs {
            if let entry = removeEntry(for: sessionID) {
                retainedBytes -= entry.projection.retainedBytes
            }
        }
    }

    /// Keeps only the specified sessions in the warm map.
    public func retain(sessionIDs: Set<String>) {
        var contentionRequest = ContentionTrace.beginInteractive(
            resource: "warm-store",
            owner: .warmStore
        )
        let lockStartedAt = contentionRequest == nil
            ? 0
            : DispatchTime.now().uptimeNanoseconds
        lock.lock()
        ContentionTrace.recordLockWait(&contentionRequest, startedAt: lockStartedAt)
        defer {
            lock.unlock()
            ContentionTrace.finishInteractive(&contentionRequest)
        }
        guard !entries.isEmpty else { return }
        let staleSessionIDs = entries.keys.filter { !sessionIDs.contains($0) }
        for sessionID in staleSessionIDs {
            if let entry = removeEntry(for: sessionID) {
                retainedBytes -= entry.projection.retainedBytes
            }
        }
    }

    /// Removes all projections and resets accounting.
    public func clear() {
        var contentionRequest = ContentionTrace.beginInteractive(
            resource: "warm-store",
            owner: .warmStore
        )
        let lockStartedAt = contentionRequest == nil
            ? 0
            : DispatchTime.now().uptimeNanoseconds
        lock.lock()
        ContentionTrace.recordLockWait(&contentionRequest, startedAt: lockStartedAt)
        entries.removeAll(keepingCapacity: true)
        retainedBytes = 0
        lruHead = nil
        lruTail = nil
        lock.unlock()
        ContentionTrace.finishInteractive(&contentionRequest)
    }

    public var metrics: Metrics {
        var contentionRequest = ContentionTrace.beginInteractive(
            resource: "warm-store",
            owner: .warmStore
        )
        let lockStartedAt = contentionRequest == nil
            ? 0
            : DispatchTime.now().uptimeNanoseconds
        lock.lock()
        ContentionTrace.recordLockWait(&contentionRequest, startedAt: lockStartedAt)
        defer {
            lock.unlock()
            ContentionTrace.finishInteractive(&contentionRequest)
        }
        return Metrics(projectionCount: entries.count, retainedBytes: retainedBytes)
    }

    private func insertEntry(_ projection: WarmTranscriptProjection, for sessionID: String) {
        let entry = Entry(projection: projection, previousID: lruTail, nextID: nil)
        if let lruTail {
            entries[lruTail]?.nextID = sessionID
        } else {
            lruHead = sessionID
        }
        entries[sessionID] = entry
        self.lruTail = sessionID
    }

    @discardableResult
    private func removeEntry(for sessionID: String) -> Entry? {
        guard let entry = entries.removeValue(forKey: sessionID) else { return nil }
        if let previousID = entry.previousID {
            entries[previousID]?.nextID = entry.nextID
        } else {
            lruHead = entry.nextID
        }
        if let nextID = entry.nextID {
            entries[nextID]?.previousID = entry.previousID
        } else {
            lruTail = entry.previousID
        }
        return entry
    }

    /// The linked list makes each victim selection and unlink O(1), while the
    /// loop evicts only as many entries as needed to restore the byte budget.
    private func evictIfNeeded(protecting sessionID: String) {
        while retainedBytes > budgetBytes,
              let victimID = lruHead,
              victimID != sessionID,
              let victim = removeEntry(for: victimID)
        {
            retainedBytes -= victim.projection.retainedBytes
        }
    }

    private static func isComplete(
        snapshot: AuthoritativeTranscriptSnapshot,
        for sessionID: String,
        minimumServerTotal: Int?
    ) -> Bool {
        guard snapshot.sessionID == sessionID, !snapshot.truncated else { return false }
        if let serverTotal = snapshot.serverTotal, snapshot.fetchedRows < serverTotal {
            return false
        }
        if let minimumServerTotal, snapshot.fetchedRows < minimumServerTotal {
            return false
        }
        return true
    }

    /// Charge the decoded values plus every store-owned container/reference
    /// needed to retain one entry. Message and snapshot strings are charged by
    /// their complete UTF-8 payload; the dictionary key and LRU links share
    /// those String buffers, so only their value storage is charged again.
    /// Fixed allocator slack is intentionally conservative and bounds the
    /// otherwise implementation-specific dictionary bucket bookkeeping.
    private static func retainedBytes(
        messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot,
        sessionID: String
    ) -> Int {
        let transcript = CachedTranscript(
            version: HistoryCache.version,
            messages: messages,
            snapshot: snapshot
        )
        let fixed = MemoryLayout<WarmTranscriptProjection>.stride
            + MemoryLayout<Entry>.stride
            + MemoryLayout<String>.stride * 2
            + 64
        let payload = transcript.retainedBytes
        let withFixed = payload > Int.max - fixed ? Int.max : payload + fixed
        return withFixed > Int.max - sessionID.utf8.count
            ? Int.max
            : withFixed + sessionID.utf8.count
    }
}
