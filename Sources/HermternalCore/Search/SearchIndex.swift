import Foundation
import SQLite3

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct SearchDocument: Sendable {
    public let messageID: ServerMessageID
    public let body: String
    public let role: Role
    public let timestamp: Date?
    public let displayKind: String?
    public let isTool: Bool

    public init(
        messageID: ServerMessageID,
        body: String,
        role: Role,
        timestamp: Date? = nil,
        displayKind: String? = nil,
        isTool: Bool = false
    ) {
        self.messageID = messageID
        self.body = body
        self.role = role
        self.timestamp = timestamp
        self.displayKind = displayKind
        self.isTool = isTool
    }

    /// Metadata and tool rows never enter FTS, even when a caller forgets to filter.
    public var isSearchable: Bool {
        guard displayKind != "model_switch", displayKind != "hidden" else { return false }
        guard !isTool else { return false }
        if let displayKind {
            return !(displayKind == "tool" || displayKind.hasPrefix("tool_") || displayKind.hasPrefix("tool."))
        }
        return true
    }
}
/// A bounded page supplied to the search index during transcript ingestion.
///
/// Callers must keep pages small. The index never retains more than one page.
public struct SearchDocumentPage: Sendable {
    public let documents: [SearchDocument]

    public init(documents: [SearchDocument]) {
        self.documents = documents
    }
}


/// A single message match in the persisted transcript corpus.
public struct SearchHit: Sendable {
    public let location: MessageLocation
    public let sessionTitle: String
    public let excerpt: AttributedString
    public let role: Role
    public let timestamp: Date?

    public init(
        location: MessageLocation,
        sessionTitle: String,
        excerpt: AttributedString,
        role: Role,
        timestamp: Date?
    ) {
        self.location = location
        self.sessionTitle = sessionTitle
        self.excerpt = excerpt
        self.role = role
        self.timestamp = timestamp
    }

    // Compatibility accessors keep callers that only need identity source
    // compatible while the public contract uses one value object.
    public var sessionID: String { location.sessionID }
    public var messageID: ServerMessageID { location.messageID }
}

public struct SearchResults: Sendable {
    public let hits: [SearchHit]
    public let pendingIndexingSessions: Int
    public let truncatedSessions: Int

    public init(
        hits: [SearchHit],
        pendingIndexingSessions: Int,
        truncatedSessions: Int
    ) {
        self.hits = hits
        self.pendingIndexingSessions = pendingIndexingSessions
        self.truncatedSessions = truncatedSessions
    }
}

public protocol SearchQuerying: Sendable {
    func search(_ query: String, limit: Int) async throws -> SearchResults
}

public struct SearchSessionSnapshot: Sendable {
    public let sessionID: String
    public let title: String
    public let documents: [SearchDocument]
    public let truncated: Bool

    public init(sessionID: String, title: String, documents: [SearchDocument], truncated: Bool = false) {
        self.sessionID = sessionID
        self.title = title
        self.documents = documents
        self.truncated = truncated
    }
}

public enum SearchIndexError: Error, LocalizedError, Sendable {
    case disabled
    case sqlite(code: Int32, message: String)
    case invalidDatabaseURL
    case unavailableSQLite
    case replayChanged

    public var errorDescription: String? {
        switch self {
        case .disabled: "The search index is disabled."
        case .sqlite(let code, let message): "SQLite error \(code): \(message)"
        case .invalidDatabaseURL: "The search index URL is not a file URL."
        case .unavailableSQLite: "The system SQLite library is unavailable."
        case .replayChanged: "The transcript changed while it was being indexed."
        }
    }
}

public actor SearchIndex: SearchQuerying {
    public static let schemaVersion = 4
    public static let defaultLimit = 100
    /// A chat contributes at most three rows per query. Round-robin diversity
    /// makes a large transcript useful without letting it exhaust the panel.
    public static let perSessionHitCap = 3
    public static let sqlitePageCacheBytes = 16 * 1024 * 1024
    public static let maxSearchWorkspaceBytes = 32 * 1024 * 1024
    public static let maxDiversitySessions = 512

    public nonisolated let url: URL
    private var database: SQLiteConnection?
    private var disabled = false
    private var generation: UInt64 = 0
    private var runningQuery: RunningQuery?
    private var queryGateReleaseHook: (@Sendable () async -> Void)?
    private let mutationGate = SearchIndexMutationGate()



    public init(url: URL) throws {
        guard url.isFileURL else { throw SearchIndexError.invalidDatabaseURL }
        self.url = url
        let connection = try SQLiteConnection(url: url)
        do { try connection.prepareSchema() } catch { connection.close(); throw error }
        database = connection
    }

    deinit {
        runningQuery?.task.cancel()
        database?.close()
    }

    // Actor methods can re-enter while a replacement awaits a page. The
    // mutation gate keeps a replacement and an accepted append in one order.
    public func replace(_ snapshot: SearchSessionSnapshot) async throws {
        try await replacePaged(
            sessionID: snapshot.sessionID,
            title: snapshot.title,
            truncated: snapshot.truncated,
            pages: {
                AsyncThrowingStream { continuation in
                    continuation.yield(SearchDocumentPage(documents: snapshot.documents))
                    continuation.finish()
                }
            }
        )
    }

    /// Replaces one session from replayable bounded pages.
    ///
    /// The first pass calculates the digest without SQLite writes. A changed
    /// digest gets a second pass in one exclusive database transaction.
    public func replacePaged(
        sessionID: String,
        title: String,
        truncated: Bool,
        pages: @escaping @Sendable () -> AsyncThrowingStream<SearchDocumentPage, Error>
    ) async throws {
        try await mutationGate.acquire()
        do {
            try Task.checkCancellation()
            generation &+= 1
            stopRunningQuery()
            guard !disabled, let database else { throw SearchIndexError.disabled }
            let requestGeneration = generation
            let value = try await digest(
                sessionID: sessionID,
                title: title,
                truncated: truncated,
                pages: pages,
                generation: requestGeneration
            )
            let unchanged = try database.withExclusive {
                try database.sessionMatches(
                    sessionID: sessionID,
                    digest: value,
                    title: title,
                    incomplete: truncated
                )
            }
            guard !unchanged else {
                await mutationGate.release()
                return
            }

            let transaction = try database.beginExclusiveTransaction()
            do {
                try database.deleteSession(sessionID)
                try database.deleteSessionMetadata(sessionID)
                var replay = SearchDigest.Multiset(
                    sessionID: sessionID,
                    title: title,
                    truncated: truncated
                )
                for try await page in pages() {
                    guard requestGeneration == generation, !Task.isCancelled else {
                        throw CancellationError()
                    }
                    for document in page.documents where document.isSearchable {
                        replay.append(document)
                        try database.insertIndexed(
                            title: title,
                            document: document,
                            sessionID: sessionID
                        )
                    }
                }
                guard requestGeneration == generation, !Task.isCancelled else {
                    throw CancellationError()
                }
                guard replay.finalize() == value else {
                    throw SearchIndexError.replayChanged
                }
                try database.upsertSessionMetadata(
                    sessionID: sessionID,
                    digest: value,
                    title: title,
                    incomplete: truncated
                )
                try transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
            await mutationGate.release()
        } catch {
            await mutationGate.release()
            throw error
        }
    }

    /// Appends one bounded page to an existing indexed session.
    ///
    /// Replayed documents and matching status leave persistent storage alone.
    /// A changed document invalidates the completed digest; a title change
    /// updates session rows through their keyed FTS row identities.
    public func append(
        _ page: SearchDocumentPage,
        sessionID: String,
        title: String,
        truncated: Bool = false
    ) async throws {
        try await mutationGate.acquire()
        do {
            try Task.checkCancellation()
            guard !disabled, let database else { throw SearchIndexError.disabled }
            let documents = Self.lastDocuments(in: page.documents)
            try database.withExclusive {
                let metadata = try database.sessionMetadata(sessionID)
                var changed: [(SearchDocument, SearchIdentity?)] = []
                changed.reserveCapacity(documents.count)
                for document in documents {
                    let identity = try database.identity(
                        sessionID: sessionID,
                        messageID: document.messageID.rawValue
                    )
                    guard let identity else {
                        changed.append((document, nil))
                        continue
                    }
                    guard !identity.matches(document) else { continue }
                    guard identity.isLowerRank(than: document) else { continue }
                    changed.append((document, identity))
                }
                let titleChanged = metadata.map { $0.title != title } ?? false
                let statusChanged = metadata?.incomplete != truncated || metadata?.warmed != true
                guard !changed.isEmpty || titleChanged || statusChanged else { return }

                try database.begin()
                do {
                    for (document, identity) in changed {
                        if let identity {
                            try database.deleteIndexedRow(rowID: identity.ftsRowID)
                        }
                        let rowID = try database.insert(
                            title: title,
                            body: document.body,
                            sessionID: sessionID,
                            messageID: document.messageID.rawValue,
                            role: document.role.rawValue,
                            timestamp: document.timestamp
                        )
                        try database.upsertIdentity(
                            document,
                            sessionID: sessionID,
                            ftsRowID: rowID
                        )
                    }
                    if titleChanged {
                        try database.updateSessionTitle(sessionID: sessionID, title: title)
                    }
                    if !changed.isEmpty {
                        try database.upsertSessionMetadata(
                            sessionID: sessionID,
                            digest: try database.digest(
                                for: sessionID,
                                title: title,
                                truncated: truncated
                            ),
                            title: title,
                            incomplete: truncated
                        )
                    } else {
                        try database.upsertSessionMetadata(
                            sessionID: sessionID,
                            digest: metadata.map {
                                SearchDigest.Multiset.replacingHeader(
                                    in: $0.digest,
                                    sessionID: sessionID,
                                    title: title,
                                    truncated: truncated
                                )
                            } ?? SearchDigest.Multiset(
                                sessionID: sessionID,
                                title: title,
                                truncated: truncated
                            ).finalize(),
                            title: title,
                            incomplete: truncated
                        )
                    }
                    try database.commit()
                } catch {
                    database.rollback()
                    throw error
                }
            }
            await mutationGate.release()
        } catch {
            await mutationGate.release()
            throw error
        }
    }


    public func remove(sessionID: String) async throws {
        try await mutationGate.acquire()
        do {
            try Task.checkCancellation()
            generation &+= 1
            stopRunningQuery()
            guard !disabled, let database else { throw SearchIndexError.disabled }
            try database.withExclusive {
                try database.begin()
                do {
                    try database.deleteSession(sessionID)
                    try database.deleteSessionMetadata(sessionID)
                    try database.commit()
                } catch {
                    database.rollback()
                    throw error
                }
            }
            await mutationGate.release()
        } catch {
            await mutationGate.release()
            throw error
        }
    }

    public func clear() async throws {
        try await mutationGate.acquire()
        do {
            try Task.checkCancellation()
            generation &+= 1
            stopRunningQuery()
            guard !disabled, let database else { throw SearchIndexError.disabled }
            try database.withExclusive {
                try database.begin()
                do {
                    try database.clearContent()
                    try database.commit()
                } catch {
                    database.rollback()
                    throw error
                }
            }
            await mutationGate.release()
        } catch {
            await mutationGate.release()
            throw error
        }
    }

    public func disable() async throws {
        try await mutationGate.acquire()
        do {
            try Task.checkCancellation()
            generation &+= 1
            stopRunningQuery()
            guard !disabled else {
                await mutationGate.release()
                return
            }
            disabled = true
            database?.close()
            database = nil
            try removeFileIfPresent(url)
            try removeFileIfPresent(URL(fileURLWithPath: url.path + "-wal"))
            try removeFileIfPresent(URL(fileURLWithPath: url.path + "-shm"))
            await mutationGate.release()
        } catch {
            await mutationGate.release()
            throw error
        }
    }
    public func isDisabled() -> Bool { disabled }

    public func search(_ query: String, limit requestedLimit: Int = SearchIndex.defaultLimit) async throws -> SearchResults {
        var lease: SQLiteQueryLease?
        let database: SQLiteConnection
        let compiled: String
        let limit: Int
        let requestGeneration: UInt64
        let runningQuery: RunningQuery

        try await mutationGate.acquire()
        do {
            try Task.checkCancellation()
            guard !disabled, let openDatabase = self.database else {
                throw SearchIndexError.disabled
            }
            database = openDatabase
            generation &+= 1
            requestGeneration = generation
            stopRunningQuery()
            compiled = Self.compile(query: query)
            guard !compiled.isEmpty else {
                await mutationGate.release()
                return SearchResults(hits: [], pendingIndexingSessions: 0, truncatedSessions: 0)
            }
            limit = max(0, min(requestedLimit, SearchIndex.defaultLimit))
            let queryLease = try database.beginQuery()
            lease = queryLease
            try Task.checkCancellation()
            let task = Task.detached(priority: .userInitiated) { () throws -> SearchResults in
                defer { queryLease.finish() }
                try Task.checkCancellation()
                database.queryStarted()
                try Task.checkCancellation()
                do {
                    return try database.query(ftsQuery: compiled, limit: limit)
                } catch SearchIndexError.sqlite(code: 9, message: _) {
                    throw CancellationError()
                }
            }
            runningQuery = RunningQuery(lease: queryLease, task: task)
            self.runningQuery = runningQuery
            await mutationGate.release()
            await queryGateReleaseHook?()
        } catch {
            lease?.finish()
            await mutationGate.release()
            throw error
        }

        do {
            let results = try await runningQuery.task.value
            guard requestGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            clearRunningQuery(runningQuery)
            return results
        } catch {
            clearRunningQuery(runningQuery)
            throw error
        }
    }
    public func search(query: String, limit: Int = SearchIndex.defaultLimit) async throws -> SearchResults {
        try await search(query, limit: limit)
    }

    // Diagnostics used by integration tests and migration checks.
    public func storedDigest(for sessionID: String) async throws -> String? {
        try await withMutationGate {
            guard !disabled, let database else { throw SearchIndexError.disabled }
            return try database.withExclusive { try database.sessionDigest(sessionID) }
        }
    }

    public func pendingIndexingSessionCount() async throws -> Int {
        try await withMutationGate {
            guard !disabled, let database else { throw SearchIndexError.disabled }
            return try database.withExclusive { Int(try database.pendingIndexingSessionCount()) }
        }
    }

    public func truncatedSessionCount() async throws -> Int {
        try await withMutationGate {
            guard !disabled, let database else { throw SearchIndexError.disabled }
            return try database.withExclusive { Int(try database.truncatedSessionCount()) }
        }
    }

    public func indexedMessageCount(sessionID: String? = nil) async throws -> Int {
        try await withMutationGate {
            guard !disabled, let database else { throw SearchIndexError.disabled }
            return try database.withExclusive { Int(try database.messageCount(sessionID: sessionID)) }
        }
    }

    public func markUnwarmed(sessionIDs: [String]) async throws {
        try await withMutationGate {
            guard !disabled, let database else { throw SearchIndexError.disabled }
            try database.withExclusive {
                try database.begin()
                do {
                    for sessionID in Set(sessionIDs) { try database.markUnwarmed(sessionID: sessionID) }
                    try database.commit()
                } catch {
                    database.rollback()
                    throw error
                }
            }
        }
    }

    public func indexedSessionIDs() async throws -> [String] {
        try await withMutationGate {
            guard !disabled, let database else { throw SearchIndexError.disabled }
            return try database.withExclusive { try database.sessionIDs() }
        }
    }

    internal static func compile(query: String) -> String {
        query.split(whereSeparator: { $0.isWhitespace }).map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " AND ")
    }

    internal func _setQueryStartHook(_ hook: (@Sendable () -> Void)?) {
        database?.setQueryStartHook(hook)
    }

    internal func _setQueryGateReleaseHook(_ hook: (@Sendable () async -> Void)?) {
        queryGateReleaseHook = hook
    }

    internal func _setSchemaVersionForTesting(_ version: Int) async throws {
        try await withMutationGate {
            guard !disabled, let database else { throw SearchIndexError.disabled }
            try database.withExclusive { try database.setSchemaVersion(version) }
        }
    }

    private func stopRunningQuery() {
        guard let runningQuery else { return }
        runningQuery.task.cancel()
        runningQuery.lease.interrupt()
        runningQuery.lease.waitUntilFinished()
        clearRunningQuery(runningQuery)
    }

    private func clearRunningQuery(_ query: RunningQuery) {
        if runningQuery?.lease === query.lease { runningQuery = nil }
    }

    private func removeFileIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private static func canonicalOrder(_ lhs: SearchDocument, _ rhs: SearchDocument) -> Bool {
        if lhs.messageID.rawValue != rhs.messageID.rawValue { return lhs.messageID.rawValue < rhs.messageID.rawValue }
        let lhsTimestamp = lhs.timestamp?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude
        let rhsTimestamp = rhs.timestamp?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude
        if lhsTimestamp != rhsTimestamp { return lhsTimestamp < rhsTimestamp }
        if lhs.role.rawValue != rhs.role.rawValue { return lhs.role.rawValue < rhs.role.rawValue }
        return lhs.body < rhs.body
    }

    private static func lastDocuments(in documents: [SearchDocument]) -> [SearchDocument] {
        let sorted = documents.filter(\.isSearchable).sorted(by: canonicalOrder)
        var result: [SearchDocument] = []
        result.reserveCapacity(sorted.count)
        for document in sorted {
            if result.last?.messageID == document.messageID {
                result[result.count - 1] = document
            } else {
                result.append(document)
            }
        }
        return result
    }


    private func digest(
        sessionID: String,
        title: String,
        truncated: Bool,
        pages: @escaping @Sendable () -> AsyncThrowingStream<SearchDocumentPage, Error>,
        generation requestGeneration: UInt64
    ) async throws -> String {
        var value = SearchDigest.Multiset(sessionID: sessionID, title: title, truncated: truncated)
        for try await page in pages() {
            guard requestGeneration == generation, !Task.isCancelled else {
                throw CancellationError()
            }
            for document in page.documents where document.isSearchable {
                value.append(document)
            }
        }
        return value.finalize()
    }

    private func withMutationGate<T: Sendable>(
        _ operation: () throws -> T
    ) async throws -> T {
        try await mutationGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try operation()
            await mutationGate.release()
            return result
        } catch {
            await mutationGate.release()
            throw error
        }
    }


    internal func _persistentMutationCount() async throws -> Int {
        try await withMutationGate {
            guard !disabled, let database else { throw SearchIndexError.disabled }
            return try database.withExclusive { database.persistentMutationCount() }
        }
    }

    internal func _resetPersistentMutationCount() async throws {
        try await withMutationGate {
            guard !disabled, let database else { throw SearchIndexError.disabled }
            try database.withExclusive { database.resetPersistentMutationCount() }
        }
    }

    internal func _identityLookupCount() async throws -> Int {
        try await withMutationGate {
            guard !disabled, let database else { throw SearchIndexError.disabled }
            return try database.withExclusive { database.identityLookupCount() }
        }
    }

    internal func _resetIdentityLookupCount() async throws {
        try await withMutationGate {
            guard !disabled, let database else { throw SearchIndexError.disabled }
            try database.withExclusive { database.resetIdentityLookupCount() }
        }
    }

    internal func _mutationGateWaiterCount() async -> Int {
        await mutationGate.waiterCount()
    }

    internal func _waitForMutationGateWaiters(atLeast count: Int) async {
        await mutationGate.waitForWaiters(atLeast: count)
    }

    internal func _setMutationGateGrantHook(_ hook: (@Sendable () async -> Void)?) async {
        await mutationGate.setGrantHook(hook)
    }
    private struct RunningQuery {
        let lease: SQLiteQueryLease
        let task: Task<SearchResults, Error>
    }
}

private final class SearchIndexMutationSignal: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        var continuation: AsyncStream<Void>.Continuation?
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.continuation = continuation!
    }

    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func finish() {
        continuation.finish()
    }
}

private final class SearchIndexMutationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var granted = false

    func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = granted ? nil : self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    func grant() -> Bool {
        lock.lock()
        guard !cancelled, !granted, let continuation else {
            lock.unlock()
            return false
        }
        granted = true
        self.continuation = nil
        lock.unlock()
        continuation.resume()
        return true
    }
}

private actor SearchIndexMutationGate {
    private static let maximumRetainedWaiters = 64

    private var held = false
    private var waiters: [SearchIndexMutationWaiter] = []
    private var overflowSignal: SearchIndexMutationSignal?
    private var waiterThreshold: (count: Int, continuation: CheckedContinuation<Void, Never>)?
    private var grantHook: (@Sendable () async -> Void)?

    func acquire() async throws {
        try Task.checkCancellation()
        while true {
            guard held else {
                held = true
                await notifyGrant()
                return
            }

            if waiters.count < Self.maximumRetainedWaiters {
                let waiter = SearchIndexMutationWaiter()
                try await withTaskCancellationHandler(operation: {
                    try await withCheckedThrowingContinuation { continuation in
                        if waiter.install(continuation) {
                            waiters.append(waiter)
                            resumeWaiterThresholdIfNeeded()
                        }
                    }
                }, onCancel: {
                    waiter.cancel()
                })
                await notifyGrant()
                return
            }

            let signal: SearchIndexMutationSignal
            if let overflowSignal {
                signal = overflowSignal
            } else {
                let newSignal = SearchIndexMutationSignal()
                overflowSignal = newSignal
                signal = newSignal
            }
            try await withTaskCancellationHandler(operation: {
                await signal.wait()
                try Task.checkCancellation()
            }, onCancel: {
                signal.finish()
            })
            if overflowSignal === signal {
                overflowSignal = nil
            }
        }
    }

    func setGrantHook(_ hook: (@Sendable () async -> Void)?) {
        grantHook = hook
    }

    private func notifyGrant() async {
        await grantHook?()
    }

    func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if waiter.grant() {
                signalOverflowWaiters()
                return
            }
        }
        held = false
        signalOverflowWaiters()
    }

    func waiterCount() -> Int {
        waiters.count
    }

    func waitForWaiters(atLeast count: Int) async {
        guard waiters.count < count else { return }
        await withCheckedContinuation { continuation in
            precondition(waiterThreshold == nil)
            waiterThreshold = (count, continuation)
        }
    }

    private func signalOverflowWaiters() {
        overflowSignal?.finish()
        overflowSignal = nil
    }

    private func resumeWaiterThresholdIfNeeded() {
        guard let waiterThreshold, waiters.count >= waiterThreshold.count else { return }
        self.waiterThreshold = nil
        waiterThreshold.continuation.resume()
    }
}

private struct SearchSessionMetadata {
    let digest: String
    let title: String
    let incomplete: Bool
    let warmed: Bool
}

private struct SearchIdentity {
    let body: String
    let role: String
    let timestamp: Double?
    let ftsRowID: Int64

    func matches(_ document: SearchDocument) -> Bool {
        body == document.body
            && role == document.role.rawValue
            && timestamp == document.timestamp?.timeIntervalSince1970
    }

    func isLowerRank(than document: SearchDocument) -> Bool {
        let documentTimestamp = document.timestamp?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude
        let timestamp = timestamp ?? -.greatestFiniteMagnitude
        if timestamp != documentTimestamp { return timestamp < documentTimestamp }
        if role != document.role.rawValue { return role < document.role.rawValue }
        return body < document.body
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    private let api: SQLiteAPI
    private var handle: OpaquePointer?
    private var closed = false
    private let lifecycle = NSCondition()
    private var activeQuery: SQLiteQueryLease?
    private var exclusiveOperation = false
    private let testHooks = SearchIndexTestHooks()
    private var persistentMutations = 0
    private var identityLookups = 0

    func persistentMutationCount() -> Int { persistentMutations }
    func resetPersistentMutationCount() { persistentMutations = 0 }
    func identityLookupCount() -> Int { identityLookups }
    func resetIdentityLookupCount() { identityLookups = 0 }

    func setQueryStartHook(_ hook: (@Sendable () -> Void)?) {
        testHooks.setQueryStarted(hook)
    }

    func queryStarted() {
        testHooks.queryStarted()
    }

    init(url: URL) throws {
        api = SQLiteAPI()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        let result = url.path.withCString { api.open($0, &db, SQLiteAPI.readWriteCreate, nil) }
        guard result == SQLiteAPI.ok, let db else {
            // SQLite may return a partially opened handle with a failure code.
            // Closing that handle is best-effort because the open error is the
            // authoritative failure we report.
            if let db { _ = api.close(db) }
            throw SearchIndexError.sqlite(code: result, message: api.errorMessage(db))
        }
        let timeoutResult = api.busyTimeout(db, 5_000)
        guard timeoutResult == SQLiteAPI.ok else {
            _ = api.close(db)
            throw SearchIndexError.sqlite(code: timeoutResult, message: api.errorMessage(db))
        }
        let cacheResult = "PRAGMA cache_size = -\(SearchIndex.sqlitePageCacheBytes / 1024)".withCString {
            api.exec(db, $0, nil, nil, nil)
        }
        guard cacheResult == SQLiteAPI.ok else {
            _ = api.close(db)
            throw SearchIndexError.sqlite(code: cacheResult, message: api.errorMessage(db))
        }
        handle = db
    }

    // The lease is the lifecycle invariant: one query or one exclusive operation
    // owns the handle, and close waits until that owner has released it.
    func beginQuery() throws -> SQLiteQueryLease {
        lifecycle.lock()
        while activeQuery != nil || exclusiveOperation { lifecycle.wait() }
        guard !closed, handle != nil else {
            lifecycle.unlock()
            throw SearchIndexError.disabled
        }
        let lease = SQLiteQueryLease(connection: self)
        activeQuery = lease
        lifecycle.unlock()
        return lease
    }

    func withExclusive<T>(_ operation: () throws -> T) throws -> T {
        lifecycle.lock()
        while activeQuery != nil || exclusiveOperation { lifecycle.wait() }
        guard !closed, handle != nil else {
            lifecycle.unlock()
            throw SearchIndexError.disabled
        }
        exclusiveOperation = true
        lifecycle.unlock()
        defer {
            lifecycle.lock()
            exclusiveOperation = false
            lifecycle.broadcast()
            lifecycle.unlock()
        }
        return try operation()
    }

    func close() {
        lifecycle.lock()
        guard !closed else {
            lifecycle.unlock()
            return
        }
        if let handle { api.interrupt(handle) }
        while activeQuery != nil || exclusiveOperation { lifecycle.wait() }
        guard let handle else {
            closed = true
            lifecycle.unlock()
            return
        }
        self.handle = nil
        closed = true
        lifecycle.unlock()
        _ = api.close(handle)
    }

    fileprivate func finishQuery(_ lease: SQLiteQueryLease) {
        lifecycle.lock()
        if activeQuery === lease {
            activeQuery = nil
            lifecycle.broadcast()
        }
        lifecycle.unlock()
        lease.markFinished()
    }

    func interrupt() {
        lifecycle.lock()
        if let handle { api.interrupt(handle) }
        lifecycle.unlock()
    }

    func prepareSchema() throws {
        do {
            try execute("CREATE TABLE IF NOT EXISTS hermternal_search_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS hermternal_search_sessions (session_id TEXT PRIMARY KEY NOT NULL, digest TEXT NOT NULL, title TEXT NOT NULL, incomplete INTEGER NOT NULL, warmed INTEGER NOT NULL)")
            try execute("""
                CREATE TABLE IF NOT EXISTS hermternal_search_identities (
                    session_id TEXT NOT NULL,
                    message_id INTEGER NOT NULL,
                    body TEXT NOT NULL,
                    role TEXT NOT NULL,
                    timestamp REAL,
                    fts_rowid INTEGER NOT NULL,
                    PRIMARY KEY(session_id, message_id)
                ) WITHOUT ROWID
                """)
            let version = try scalarString("SELECT value FROM hermternal_search_metadata WHERE key = 'schema_version' LIMIT 1")
            let validFTS = (try? queryRows("SELECT title, body, session_id, message_id, role, timestamp FROM hermternal_search_messages LIMIT 0")) != nil
            let validMetadata = (try? queryRows("SELECT session_id, digest, title, incomplete, warmed FROM hermternal_search_sessions LIMIT 0")) != nil
            let validIdentities = (try? queryRows("SELECT session_id, message_id, body, role, timestamp, fts_rowid FROM hermternal_search_identities LIMIT 0")) != nil
            if version != String(SearchIndex.schemaVersion) || !validFTS || !validMetadata || !validIdentities {
                try rebuildSchema()
            }
        } catch {
            try rebuildSchema()
        }
    }

    func begin() throws { try execute("BEGIN IMMEDIATE") }
    func setSchemaVersion(_ version: Int) throws {
        try execute("UPDATE hermternal_search_metadata SET value = ? WHERE key = 'schema_version'", bindings: [.text(String(version))])
    }
    func commit() throws { try execute("COMMIT") }
    func rollback() { try? execute("ROLLBACK") }

    func beginExclusiveTransaction() throws -> SQLiteWriteTransaction {
        lifecycle.lock()
        while activeQuery != nil || exclusiveOperation { lifecycle.wait() }
        guard !closed, handle != nil else {
            lifecycle.unlock()
            throw SearchIndexError.disabled
        }
        exclusiveOperation = true
        lifecycle.unlock()
        do {
            try begin()
            return SQLiteWriteTransaction(connection: self)
        } catch {
            finishExclusiveOperation()
            throw error
        }
    }

    fileprivate func finishExclusiveOperation() {
        lifecycle.lock()
        exclusiveOperation = false
        lifecycle.broadcast()
        lifecycle.unlock()
    }

    func sessionDigest(_ id: String) throws -> String? {
        try sessionMetadata(id)?.digest
    }
    func sessionMetadata(_ id: String) throws -> SearchSessionMetadata? {
        guard let row = try queryRows(
            "SELECT digest, title, incomplete, warmed FROM hermternal_search_sessions WHERE session_id = ? LIMIT 1",
            bindings: [.text(id)]
        ).first else {
            return nil
        }
        return SearchSessionMetadata(
            digest: row.text(0) ?? "",
            title: row.text(1) ?? "",
            incomplete: row.int64(2) != 0,
            warmed: row.int64(3) != 0
        )
    }
    func sessionMatches(sessionID: String, digest: String, title: String, incomplete: Bool) throws -> Bool {
        guard let metadata = try sessionMetadata(sessionID) else { return false }
        return metadata.digest == digest
            && metadata.title == title
            && metadata.incomplete == incomplete
            && metadata.warmed
    }
    func deleteSession(_ id: String) throws {
        for row in try queryRows(
            "SELECT fts_rowid FROM hermternal_search_identities WHERE session_id = ?",
            bindings: [.text(id)]
        ) {
            try deleteIndexedRow(rowID: row.int64(0))
        }
        try execute("DELETE FROM hermternal_search_identities WHERE session_id = ?", bindings: [.text(id)])
    }
    func deleteSessionMetadata(_ id: String) throws {
        try execute("DELETE FROM hermternal_search_sessions WHERE session_id = ?", bindings: [.text(id)])
    }
    func clearContent() throws {
        try execute("DELETE FROM hermternal_search_messages")
        try execute("DELETE FROM hermternal_search_identities")
        try execute("DELETE FROM hermternal_search_sessions")
    }
    func pendingIndexingSessionCount() throws -> Int {
        Int(try scalarInt("SELECT count(*) FROM hermternal_search_sessions WHERE warmed = 0"))
    }
    func truncatedSessionCount() throws -> Int {
        Int(try scalarInt("SELECT count(*) FROM hermternal_search_sessions WHERE incomplete = 1"))
    }
    func sessionStatusCounts() throws -> (pendingIndexing: Int, truncated: Int) {
        let rows = try queryRows("""
            SELECT
                COALESCE(SUM(CASE WHEN warmed = 0 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN incomplete = 1 THEN 1 ELSE 0 END), 0)
            FROM hermternal_search_sessions
            """)
        return (Int(rows[0].int64(0)), Int(rows[0].int64(1)))
    }
    func messageCount(sessionID: String?) throws -> Int {
        Int(try scalarInt("SELECT count(*) FROM hermternal_search_messages" + (sessionID == nil ? "" : " WHERE session_id = ?"), bindings: sessionID.map { [.text($0)] } ?? []))
    }
    func sessionIDs() throws -> [String] {
        try queryRows("SELECT session_id FROM hermternal_search_sessions ORDER BY session_id").compactMap { $0.text(0) }
    }

    func upsertSessionMetadata(sessionID: String, digest: String, title: String, incomplete: Bool) throws {
        try execute("INSERT INTO hermternal_search_sessions(session_id, digest, title, incomplete, warmed) VALUES (?, ?, ?, ?, 1) ON CONFLICT(session_id) DO UPDATE SET digest = excluded.digest, title = excluded.title, incomplete = excluded.incomplete, warmed = 1", bindings: [.text(sessionID), .text(digest), .text(title), .int(incomplete ? 1 : 0)])
    }
    func updateSessionStatus(sessionID: String, title: String, incomplete: Bool) throws {
        try execute("INSERT INTO hermternal_search_sessions(session_id, digest, title, incomplete, warmed) VALUES (?, '', ?, ?, 1) ON CONFLICT(session_id) DO UPDATE SET title = excluded.title, incomplete = excluded.incomplete, warmed = 1", bindings: [.text(sessionID), .text(title), .int(incomplete ? 1 : 0)])
    }
    func markUnwarmed(sessionID: String) throws {
        try execute("INSERT INTO hermternal_search_sessions(session_id, digest, title, incomplete, warmed) VALUES (?, '', '', 0, 0) ON CONFLICT(session_id) DO NOTHING", bindings: [.text(sessionID)])
    }

    func insert(title: String, body: String, sessionID: String, messageID: Int64, role: String, timestamp: Date?) throws -> Int64 {
        try execute("INSERT INTO hermternal_search_messages(title, body, session_id, message_id, role, timestamp) VALUES (?, ?, ?, ?, ?, ?)", bindings: [.text(title), .text(body), .text(sessionID), .int64(messageID), .text(role), timestamp.map { .double($0.timeIntervalSince1970) } ?? .null])
        guard let handle else { throw SearchIndexError.disabled }
        return api.lastInsertRowID(handle)
    }
    func insertIndexed(title: String, document: SearchDocument, sessionID: String) throws {
        if let existing = try identity(
            sessionID: sessionID,
            messageID: document.messageID.rawValue
        ) {
            guard existing.isLowerRank(than: document) else { return }
            try deleteIndexedRow(rowID: existing.ftsRowID)
        }
        let rowID = try insert(title: title, body: document.body, sessionID: sessionID, messageID: document.messageID.rawValue, role: document.role.rawValue, timestamp: document.timestamp)
        try upsertIdentity(document, sessionID: sessionID, ftsRowID: rowID)
    }
    func identity(sessionID: String, messageID: Int64) throws -> SearchIdentity? {
        identityLookups += 1
        guard let row = try queryRows(
            "SELECT body, role, timestamp, fts_rowid FROM hermternal_search_identities WHERE session_id = ? AND message_id = ? LIMIT 1",
            bindings: [.text(sessionID), .int64(messageID)]
        ).first else {
            return nil
        }
        return SearchIdentity(
            body: row.text(0) ?? "",
            role: row.text(1) ?? "",
            timestamp: row.double(2),
            ftsRowID: row.int64(3)
        )
    }
    func upsertIdentity(_ document: SearchDocument, sessionID: String, ftsRowID: Int64) throws {
        try execute("""
            INSERT INTO hermternal_search_identities(session_id, message_id, body, role, timestamp, fts_rowid)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, message_id) DO UPDATE SET
                body = excluded.body,
                role = excluded.role,
                timestamp = excluded.timestamp,
                fts_rowid = excluded.fts_rowid
            """, bindings: [
                .text(sessionID),
                .int64(document.messageID.rawValue),
                .text(document.body),
                .text(document.role.rawValue),
                document.timestamp.map { .double($0.timeIntervalSince1970) } ?? .null,
                .int64(ftsRowID)
            ])
    }
    func deleteIndexedRow(rowID: Int64) throws {
        try execute("DELETE FROM hermternal_search_messages WHERE rowid = ?", bindings: [.int64(rowID)])
    }
    func updateSessionTitle(sessionID: String, title: String) throws {
        for row in try queryRows(
            "SELECT fts_rowid FROM hermternal_search_identities WHERE session_id = ?",
            bindings: [.text(sessionID)]
        ) {
            try execute(
                "UPDATE hermternal_search_messages SET title = ? WHERE rowid = ?",
                bindings: [.text(title), .int64(row.int64(0))]
            )
        }
    }

    func digest(for sessionID: String, title: String, truncated: Bool) throws -> String {
        guard let handle else { throw SearchIndexError.disabled }
        let sql = """
            SELECT message_id, body, role, timestamp
            FROM hermternal_search_identities
            WHERE session_id = ?
            ORDER BY message_id, role, timestamp
            """
        var statement: OpaquePointer?
        let result = sql.withCString { api.prepare(handle, $0, -1, &statement, nil) }
        guard result == SQLiteAPI.ok, let statement else { throw makeError(result) }
        defer { _ = api.finalize(statement) }
        try bind([.text(sessionID)], to: statement)

        var digest = SearchDigest.Multiset(
            sessionID: sessionID,
            title: title,
            truncated: truncated
        )
        while true {
            let step = api.step(statement)
            if step == SQLiteAPI.done { return digest.finalize() }
            guard step == SQLiteAPI.row else { throw makeError(step) }
            digest.append(
                messageID: api.columnInt64(statement, 0),
                body: columnText(statement, 1) ?? "",
                role: columnText(statement, 2) ?? "",
                timestamp: api.columnType(statement, 3) == SQLiteAPI.nullType
                    ? nil
                    : api.columnDouble(statement, 3)
            )
        }
    }
    func query(ftsQuery: String, limit: Int) throws -> SearchResults {
        let counts = try sessionStatusCounts()
        guard limit > 0 else {
            return SearchResults(
                hits: [],
                pendingIndexingSessions: counts.pendingIndexing,
                truncatedSessions: counts.truncated
            )
        }

        // The query reads only identity, metadata, rank, and SQLite's bounded
        // snippet. It never selects message bodies or materializes all rows.
        let sql = """
            SELECT session_id, message_id, title, role, timestamp,
                   snippet(hermternal_search_messages, -1, '⟦', '⟧', '…', 32),
                   bm25(hermternal_search_messages, ?, ?)
            FROM hermternal_search_messages
            WHERE hermternal_search_messages MATCH ?
            ORDER BY bm25(hermternal_search_messages, ?, ?)
            LIMIT ?
            """
        guard let handle else { throw SearchIndexError.disabled }
        var statement: OpaquePointer?
        let result = sql.withCString { api.prepare(handle, $0, -1, &statement, nil) }
        guard result == SQLiteAPI.ok, let statement else { throw makeError(result) }
        defer { _ = api.finalize(statement) }
        try bind(
            [.double(10), .double(1), .text(ftsQuery), .double(10), .double(1),
             .int(SearchIndex.maxDiversitySessions * SearchIndex.perSessionHitCap)],
            to: statement
        )

        var candidates: [String: [SearchCandidate]] = [:]
        var candidateBytes = 0
        var retainedCandidates = 0
        let maxWorkspace = SearchIndex.maxSearchWorkspaceBytes
        let maxSessions = SearchIndex.maxDiversitySessions
        while true {
            let step = api.step(statement)
            if step == SQLiteAPI.done { break }
            guard step == SQLiteAPI.row else { throw makeError(step) }
            let sessionID = columnText(statement, 0) ?? ""
            let candidate = SearchCandidate(
                sessionID: sessionID,
                messageID: api.columnInt64(statement, 1),
                title: columnText(statement, 2) ?? "",
                role: columnText(statement, 3) ?? "",
                timestamp: api.columnType(statement, 4) == SQLiteAPI.nullType ? nil : api.columnDouble(statement, 4),
                snippet: columnText(statement, 5) ?? "",
                rank: api.columnDouble(statement, 6),
                estimatedBytes: (sessionID.utf8.count + 64)
                    + (columnText(statement, 2)?.utf8.count ?? 0)
                    + (columnText(statement, 5)?.utf8.count ?? 0)
            )
            guard candidateBytes + candidate.estimatedBytes <= maxWorkspace else { continue }
            if candidates[sessionID] == nil {
                guard candidates.count < maxSessions else { continue }
                candidates[sessionID] = []
            }
            guard candidates[sessionID]!.count < SearchIndex.perSessionHitCap else { continue }
            candidates[sessionID]!.append(candidate)
            candidateBytes += candidate.estimatedBytes
            retainedCandidates += 1
            if retainedCandidates >= limit { break }
        }
        var hits: [SearchHit] = []
        hits.reserveCapacity(min(limit, SearchIndex.defaultLimit))
        var round = 0
        while hits.count < limit {
            let rankedSessions = candidates.compactMap { sessionID, rows -> (String, SearchCandidate)? in
                guard rows.indices.contains(round) else { return nil }
                return (sessionID, rows[round])
            }.sorted { ($0.1.rank, $0.0) < ($1.1.rank, $1.0) }
            guard !rankedSessions.isEmpty else { break }
            for (_, candidate) in rankedSessions where hits.count < limit {
                hits.append(makeHit(candidate))
            }
            round += 1
        }
        return SearchResults(
            hits: hits,
            pendingIndexingSessions: counts.pendingIndexing,
            truncatedSessions: counts.truncated
        )
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        api.columnText(statement, index).map { String(cString: $0) }
    }

    private func makeHit(_ candidate: SearchCandidate) -> SearchHit {
        SearchHit(
            location: MessageLocation(sessionID: candidate.sessionID, messageID: ServerMessageID(rawValue: candidate.messageID)),
            sessionTitle: candidate.title,
            excerpt: SearchExcerpt.attributed(snippet: candidate.snippet, fallbackTitle: candidate.title, body: ""),
            role: Role(rawValue: candidate.role) ?? .user,
            timestamp: candidate.timestamp.map(Date.init(timeIntervalSince1970:))
        )
    }


    private func rebuildSchema() throws {
        try execute("DROP TABLE IF EXISTS hermternal_search_messages")
        try execute("DROP TABLE IF EXISTS hermternal_search_identities")
        try execute("DROP TABLE IF EXISTS hermternal_search_sessions")
        try execute("DROP TABLE IF EXISTS hermternal_search_metadata")
        try execute("CREATE TABLE hermternal_search_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
        try execute("CREATE TABLE hermternal_search_sessions (session_id TEXT PRIMARY KEY NOT NULL, digest TEXT NOT NULL, title TEXT NOT NULL, incomplete INTEGER NOT NULL, warmed INTEGER NOT NULL)")
        try execute("""
            CREATE TABLE hermternal_search_identities (
                session_id TEXT NOT NULL,
                message_id INTEGER NOT NULL,
                body TEXT NOT NULL,
                role TEXT NOT NULL,
                timestamp REAL,
                fts_rowid INTEGER NOT NULL,
                PRIMARY KEY(session_id, message_id)
            ) WITHOUT ROWID
            """)
        try execute("CREATE VIRTUAL TABLE hermternal_search_messages USING fts5(title, body, session_id UNINDEXED, message_id UNINDEXED, role UNINDEXED, timestamp UNINDEXED, tokenize='unicode61 remove_diacritics 2')")
        try execute("INSERT INTO hermternal_search_metadata(key, value) VALUES ('schema_version', '\(SearchIndex.schemaVersion)')")
    }

    private enum Binding { case text(String), int(Int), int64(Int64), double(Double), null }
    private struct Value { let text: String?; let int64: Int64?; let double: Double? }
    private struct Row {
        let values: [Value]
        func text(_ n: Int) -> String? { values[n].text }
        func int64(_ n: Int) -> Int64 { values[n].int64 ?? 0 }
        func double(_ n: Int) -> Double? { values[n].double }
    }
    private struct SearchCandidate {
        let sessionID: String
        let messageID: Int64
        let title: String
        let role: String
        let timestamp: Double?
        let snippet: String
        let rank: Double
        let estimatedBytes: Int
    }

    private func scalarString(_ sql: String, bindings: [Binding] = []) throws -> String? { try queryRows(sql, bindings: bindings).first?.text(0) }
    private func scalarInt(_ sql: String, bindings: [Binding] = []) throws -> Int64 { try queryRows(sql, bindings: bindings).first?.int64(0) ?? 0 }
    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        guard let handle else { throw SearchIndexError.disabled }
        if !bindings.isEmpty {
            _ = try queryRows(sql, bindings: bindings, collectRows: false)
            recordPersistentMutation(sql)
            return
        }
        let result = sql.withCString { sqlite3_exec(handle, $0, nil, nil, nil) }
        guard result == SQLiteAPI.ok else { throw makeError(result) }
        recordPersistentMutation(sql)
    }

    private func recordPersistentMutation(_ sql: String) {
        guard sql.hasPrefix("INSERT") || sql.hasPrefix("UPDATE") || sql.hasPrefix("DELETE") else {
            return
        }
        persistentMutations += 1
    }

    private func queryRows(_ sql: String, bindings: [Binding] = [], collectRows: Bool = true) throws -> [Row] {
        guard let handle else { throw SearchIndexError.disabled }
        var statement: OpaquePointer?
        let result = sql.withCString { api.prepare(handle, $0, -1, &statement, nil) }
        guard result == SQLiteAPI.ok, let statement else { throw makeError(result) }
        defer { _ = api.finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [Row] = []
        while true {
            let step = api.step(statement)
            if step == SQLiteAPI.row { if collectRows { rows.append(readRow(statement)) } }
            else if step == SQLiteAPI.done { return rows }
            else { throw makeError(step) }
        }
    }
    private func bind(_ values: [Binding], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let value):
                let transient: sqlite3_destructor_type? = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type?.self)
                result = value.withCString { api.bindText(statement, index, $0, -1, transient) }
            case .int(let value): result = api.bindInt(statement, index, Int32(value))
            case .int64(let value): result = api.bindInt64(statement, index, value)
            case .double(let value): result = api.bindDouble(statement, index, value)
            case .null: result = api.bindNull(statement, index)
            }
            guard result == SQLiteAPI.ok else { throw makeError(result) }
        }
    }

    private func readRow(_ statement: OpaquePointer) -> Row {
        var values: [Value] = []; values.reserveCapacity(Int(api.columnCount(statement)))
        for index in 0..<Int(api.columnCount(statement)) {
            let i = Int32(index), type = api.columnType(statement, i)
            if type == SQLiteAPI.nullType { values.append(Value(text: nil, int64: nil, double: nil)) }
            else if type == SQLiteAPI.integerType { let v = api.columnInt64(statement, i); values.append(Value(text: nil, int64: v, double: Double(v))) }
            else if type == SQLiteAPI.floatType { values.append(Value(text: nil, int64: nil, double: api.columnDouble(statement, i))) }
            else { let text = api.columnText(statement, i).map { String(cString: $0) }; values.append(Value(text: text, int64: nil, double: text.flatMap(Double.init))) }
        }
        return Row(values: values)
    }

    private func makeError(_ code: Int32) -> SearchIndexError { .sqlite(code: code, message: api.errorMessage(handle)) }
}


private final class SQLiteWriteTransaction {
    private let connection: SQLiteConnection
    private var finished = false

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func commit() throws {
        guard !finished else { return }
        do {
            try connection.commit()
        } catch {
            connection.rollback()
            finished = true
            connection.finishExclusiveOperation()
            throw error
        }
        finished = true
        connection.finishExclusiveOperation()
    }

    func rollback() {
        guard !finished else { return }
        connection.rollback()
        finished = true
        connection.finishExclusiveOperation()
    }

    deinit {
        rollback()
    }
}
private final class SQLiteQueryLease: @unchecked Sendable {
    private weak var connection: SQLiteConnection?
    private let completion = NSCondition()
    private var finished = false

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func interrupt() { connection?.interrupt() }

    func finish() {
        connection?.finishQuery(self)
    }

    func waitUntilFinished() {
        completion.lock()
        while !finished { completion.wait() }
        completion.unlock()
    }

    fileprivate func markFinished() {
        completion.lock()
        finished = true
        completion.broadcast()
        completion.unlock()
    }
}

private final class SearchIndexTestHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var hook: (@Sendable () -> Void)?

    func setQueryStarted(_ hook: (@Sendable () -> Void)?) {
        lock.lock()
        self.hook = hook
        lock.unlock()
    }

    func queryStarted() {
        lock.lock()
        let hook = self.hook
        lock.unlock()
        hook?()
    }
}

private final class SQLiteAPI: @unchecked Sendable {
    static let ok: Int32 = SQLITE_OK
    static let row: Int32 = SQLITE_ROW
    static let done: Int32 = SQLITE_DONE
    static let nullType: Int32 = SQLITE_NULL
    static let integerType: Int32 = SQLITE_INTEGER
    static let floatType: Int32 = SQLITE_FLOAT
    static let readWriteCreate: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI

    func open(_ path: UnsafePointer<CChar>, _ database: UnsafeMutablePointer<OpaquePointer?>, _ flags: Int32, _ vfs: UnsafePointer<CChar>?) -> Int32 {
        sqlite3_open_v2(path, database, flags, vfs)
    }
    func close(_ database: OpaquePointer) -> Int32 { sqlite3_close_v2(database) }
    func exec(_ database: OpaquePointer?, _ sql: UnsafePointer<CChar>?, _ callback: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32)?, _ context: UnsafeMutableRawPointer?, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
        sqlite3_exec(database, sql, callback, context, error)
    }
    func prepare(_ database: OpaquePointer, _ sql: UnsafePointer<CChar>, _ length: Int32, _ statement: UnsafeMutablePointer<OpaquePointer?>, _ tail: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32 {
        sqlite3_prepare_v2(database, sql, length, statement, tail)
    }
    func step(_ statement: OpaquePointer) -> Int32 { sqlite3_step(statement) }
    func finalize(_ statement: OpaquePointer) -> Int32 { sqlite3_finalize(statement) }
    func bindText(_ statement: OpaquePointer, _ index: Int32, _ text: UnsafePointer<CChar>, _ length: Int32, _ destructor: sqlite3_destructor_type?) -> Int32 {
        sqlite3_bind_text(statement, index, text, length, destructor)
    }
    func bindInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int32) -> Int32 { sqlite3_bind_int(statement, index, value) }
    func bindInt64(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) -> Int32 { sqlite3_bind_int64(statement, index, value) }
    func lastInsertRowID(_ database: OpaquePointer) -> Int64 { sqlite3_last_insert_rowid(database) }
    func bindDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double) -> Int32 { sqlite3_bind_double(statement, index, value) }
    func bindNull(_ statement: OpaquePointer, _ index: Int32) -> Int32 { sqlite3_bind_null(statement, index) }
    func columnCount(_ statement: OpaquePointer) -> Int32 { sqlite3_column_count(statement) }
    func columnType(_ statement: OpaquePointer, _ index: Int32) -> Int32 { sqlite3_column_type(statement, index) }
    func columnText(_ statement: OpaquePointer, _ index: Int32) -> UnsafePointer<CChar>? {
        sqlite3_column_text(statement, index).map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }
    }
    func columnInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    func columnDouble(_ statement: OpaquePointer, _ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    func busyTimeout(_ database: OpaquePointer, _ milliseconds: Int32) -> Int32 { sqlite3_busy_timeout(database, milliseconds) }
    func interrupt(_ database: OpaquePointer) { sqlite3_interrupt(database) }
    func errorMessage(_ database: OpaquePointer?) -> String {
        sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown SQLite error"
    }
}

private enum SearchDigest {
    struct Incremental: Sendable {
        private var sha = SHA256.Incremental()

        init(sessionID: String, title: String, truncated: Bool) {
            append(sessionID)
            append(title)
            append(truncated ? "1" : "0")
        }

        mutating func append(_ document: SearchDocument) {
            append(String(document.messageID.rawValue))
            append(document.body)
            append(document.role.rawValue)
            append(document.timestamp.map { String($0.timeIntervalSince1970) } ?? "")
        }

        mutating func append(_ value: String) {
            var count = UInt64(value.utf8.count).bigEndian
            let bytes = withUnsafeBytes(of: &count) { Array($0) }
            for byte in bytes { sha.update(byte) }
            for byte in value.utf8 { sha.update(byte) }
        }

        func finalize() -> String {
            var copy = sha
            return copy.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Multiset: Sendable {
        private let header: String
        private var count: UInt64 = 0
        private var sum: UInt64 = 0
        private var xor: UInt64 = 0

        init(sessionID: String, title: String, truncated: Bool) {
            header = Incremental(sessionID: sessionID, title: title, truncated: truncated).finalize()
        }

        static func replacingHeader(
            in digest: String,
            sessionID: String,
            title: String,
            truncated: Bool
        ) -> String {
            let header = Incremental(sessionID: sessionID, title: title, truncated: truncated).finalize()
            guard let separator = digest.firstIndex(of: ":") else {
                return Multiset(sessionID: sessionID, title: title, truncated: truncated).finalize()
            }
            return header + String(digest[separator...])
        }

        mutating func append(_ document: SearchDocument) {
            append(
                messageID: document.messageID.rawValue,
                body: document.body,
                role: document.role.rawValue,
                timestamp: document.timestamp?.timeIntervalSince1970
            )
        }

        mutating func append(messageID: Int64, body: String, role: String, timestamp: Double?) {
            var digest = Incremental(sessionID: "", title: "", truncated: false)
            digest.append(String(messageID))
            digest.append(body)
            digest.append(role)
            digest.append(timestamp.map { String($0) } ?? "")
            let value = UInt64(digest.finalize().prefix(16), radix: 16) ?? 0
            count &+= 1
            sum &+= value
            xor ^= value
        }

        func finalize() -> String {
            "\(header):\(count):\(String(format: "%016llx", sum)):\(String(format: "%016llx", xor))"
        }
    }
}

private enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66b,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664a,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ]
    struct Incremental: Sendable {
        private var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        private var buffer: [UInt8] = []
        private var byteCount: UInt64 = 0

        mutating func update(_ byte: UInt8) {
            buffer.append(byte)
            byteCount &+= 1
            if buffer.count == 64 {
                let block = buffer
                process(block)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        mutating func finalize() -> [UInt8] {
            var tail = buffer
            tail.append(0x80)
            while tail.count % 64 != 56 { tail.append(0) }
            var bitLength = (byteCount * 8).bigEndian
            withUnsafeBytes(of: &bitLength) { tail.append(contentsOf: $0) }
            for base in stride(from: 0, to: tail.count, by: 64) {
                process(Array(tail[base..<(base + 64)]))
            }
            return h.flatMap {
                [
                    UInt8(truncatingIfNeeded: $0 >> 24),
                    UInt8(truncatingIfNeeded: $0 >> 16),
                    UInt8(truncatingIfNeeded: $0 >> 8),
                    UInt8(truncatingIfNeeded: $0)
                ]
            }
        }

        private mutating func process(_ bytes: [UInt8]) {
            var w = Array(repeating: UInt32(0), count: 64)
            for i in 0..<16 {
                let p = i * 4
                w[i] = UInt32(bytes[p]) << 24 | UInt32(bytes[p + 1]) << 16
                    | UInt32(bytes[p + 2]) << 8 | UInt32(bytes[p + 3])
            }
            for i in 16..<64 {
                let a = w[i - 15], b = w[i - 2]
                let s0 = a.rotateRight(7) ^ a.rotateRight(18) ^ (a >> 3)
                let s1 = b.rotateRight(17) ^ b.rotateRight(19) ^ (b >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], x = h[7]
            for i in 0..<64 {
                let s1 = e.rotateRight(6) ^ e.rotateRight(11) ^ e.rotateRight(25)
                let choose = (e & f) ^ (~e & g)
                let t1 = x &+ s1 &+ choose &+ k[i] &+ w[i]
                let s0 = a.rotateRight(2) ^ a.rotateRight(13) ^ a.rotateRight(22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                x = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= x
        }
    }


    static func hash(_ input: Data) -> [UInt8] {
        var bytes = [UInt8](input)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        bytes += withUnsafeBytes(of: bitLength.bigEndian) { Array($0) }
        var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        for base in stride(from: 0, to: bytes.count, by: 64) {
            var w = Array(repeating: UInt32(0), count: 64)
            for i in 0..<16 {
                let p = base + i * 4
                w[i] = UInt32(bytes[p]) << 24 | UInt32(bytes[p + 1]) << 16 | UInt32(bytes[p + 2]) << 8 | UInt32(bytes[p + 3])
            }
            for i in 16..<64 {
                let a = w[i - 15], b = w[i - 2]
                let s0 = a.rotateRight(7) ^ a.rotateRight(18) ^ (a >> 3)
                let s1 = b.rotateRight(17) ^ b.rotateRight(19) ^ (b >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a=h[0], b=h[1], c=h[2], d=h[3], e=h[4], f=h[5], g=h[6], x=h[7]
            for i in 0..<64 {
                let s1 = e.rotateRight(6) ^ e.rotateRight(11) ^ e.rotateRight(25)
                let choose = (e & f) ^ (~e & g)
                let t1 = x &+ s1 &+ choose &+ k[i] &+ w[i]
                let s0 = a.rotateRight(2) ^ a.rotateRight(13) ^ a.rotateRight(22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                x=g; g=f; f=e; e=d &+ t1; d=c; c=b; b=a; a=t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= x
        }
        return h.flatMap { value in
            [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        }
    }
}
private extension UInt64 {
    func rotateLeft(_ count: UInt64) -> UInt64 { (self << count) | (self >> (64 - count)) }
}

private extension UInt32 {
    func rotateRight(_ count: UInt32) -> UInt32 { (self >> count) | (self << (32 - count)) }
}
