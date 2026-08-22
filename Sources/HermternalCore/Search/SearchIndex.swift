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

    public init(messageID: ServerMessageID, body: String, role: Role, timestamp: Date? = nil) {
        self.messageID = messageID
        self.body = body
        self.role = role
        self.timestamp = timestamp
    }
}

public struct SearchHit: Sendable {
    public let sessionID: String
    public let messageID: ServerMessageID
    public let sessionTitle: String
    public let excerpt: String
    public let role: Role
    public let timestamp: Date?
    public let score: Double

    public init(sessionID: String, messageID: ServerMessageID, sessionTitle: String, excerpt: String, role: Role, timestamp: Date?, score: Double) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.sessionTitle = sessionTitle
        self.excerpt = excerpt
        self.role = role
        self.timestamp = timestamp
        self.score = score
    }
}

public struct SearchResults: Sendable {
    public let hits: [SearchHit]
    public let incompleteSessions: Int

    public init(hits: [SearchHit], incompleteSessions: Int) {
        self.hits = hits
        self.incompleteSessions = incompleteSessions
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

    public var errorDescription: String? {
        switch self {
        case .disabled: "The search index is disabled."
        case .sqlite(let code, let message): "SQLite error \(code): \(message)"
        case .invalidDatabaseURL: "The search index URL is not a file URL."
        case .unavailableSQLite: "The system SQLite library is unavailable."
        }
    }
}

public actor SearchIndex: SearchQuerying {
    public static let schemaVersion = 1
    public static let defaultLimit = 100

    public nonisolated let url: URL
    private var database: SQLiteConnection?
    private var disabled = false
    private var generation: UInt64 = 0
    private var runningQuery: RunningQuery?


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

    // Actor methods may re-enter while search awaits its detached task. Every
    // mutating path therefore bumps generation and synchronously joins the
    // exact query lease before taking the connection's exclusive lifecycle lock.
    public func replace(_ snapshot: SearchSessionSnapshot) async throws {
        generation &+= 1
        stopRunningQuery()
        guard !disabled, let database else { throw SearchIndexError.disabled }
        let documents = snapshot.documents.sorted(by: Self.canonicalOrder)
        let digest = SearchDigest.session(snapshot: snapshot, documents: documents)
        try database.withExclusive {
            if try database.sessionDigest(snapshot.sessionID) == digest { return }
            try database.begin()
            do {
                try database.deleteSession(snapshot.sessionID)
                for document in documents {
                    // The snapshot title is authoritative for every row. This also
                    // makes a title-only session update invalidate old FTS rows.
                    try database.insert(
                        title: snapshot.title,
                        body: document.body,
                        sessionID: snapshot.sessionID,
                        messageID: document.messageID.rawValue,
                        role: document.role.rawValue,
                        timestamp: document.timestamp
                    )
                }
                try database.upsertSessionMetadata(sessionID: snapshot.sessionID, digest: digest, incomplete: snapshot.truncated)
                try database.commit()
            } catch {
                database.rollback()
                throw error
            }
        }
    }

    public func remove(sessionID: String) async throws {
        generation &+= 1
        stopRunningQuery()
        guard !disabled, let database else { throw SearchIndexError.disabled }
        try database.withExclusive {
            try database.begin()
            do {
                try database.deleteSession(sessionID)
                try database.deleteSessionMetadata(sessionID)
                try database.commit()
            } catch { database.rollback(); throw error }
        }
    }

    public func clear() async throws {
        generation &+= 1
        stopRunningQuery()
        guard !disabled, let database else { throw SearchIndexError.disabled }
        try database.withExclusive {
            try database.begin()
            do { try database.clearContent(); try database.commit() }
            catch { database.rollback(); throw error }
        }
    }

    public func disable() async throws {
        generation &+= 1
        stopRunningQuery()
        guard !disabled else { return }
        disabled = true
        database?.close()
        database = nil
        try removeFileIfPresent(url)
        try removeFileIfPresent(URL(fileURLWithPath: url.path + "-wal"))
        try removeFileIfPresent(URL(fileURLWithPath: url.path + "-shm"))
    }
    public func isDisabled() -> Bool { disabled }

    public func search(_ query: String, limit requestedLimit: Int = SearchIndex.defaultLimit) async throws -> SearchResults {
        guard !disabled, let database else { throw SearchIndexError.disabled }
        generation &+= 1
        let requestGeneration = generation
        stopRunningQuery()
        let compiled = Self.compile(query: query)
        guard !compiled.isEmpty else { return SearchResults(hits: [], incompleteSessions: 0) }
        let limit = max(0, min(requestedLimit, SearchIndex.defaultLimit))
        let lease = try database.beginQuery()
        let task = Task.detached(priority: .userInitiated) { () throws -> SearchResults in
            defer { lease.finish() }
            try Task.checkCancellation()
            database.queryStarted()
            try Task.checkCancellation()
            do {
                return try database.query(ftsQuery: compiled, limit: limit)
            } catch SearchIndexError.sqlite(code: 9, message: _) {
                throw CancellationError()
            }
        }
        let runningQuery = RunningQuery(lease: lease, task: task)
        self.runningQuery = runningQuery
        do {
            let results = try await task.value
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
    public func storedDigest(for sessionID: String) throws -> String? {
        guard !disabled, let database else { throw SearchIndexError.disabled }
        return try database.withExclusive { try database.sessionDigest(sessionID) }
    }

    public func incompleteSessionCount() throws -> Int {
        guard !disabled, let database else { throw SearchIndexError.disabled }
        return try database.withExclusive { Int(try database.incompleteSessionCount()) }
    }

    public func indexedMessageCount(sessionID: String? = nil) throws -> Int {
        guard !disabled, let database else { throw SearchIndexError.disabled }
        return try database.withExclusive { Int(try database.messageCount(sessionID: sessionID)) }
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

    internal func _setSchemaVersionForTesting(_ version: Int) throws {
        guard !disabled, let database else { throw SearchIndexError.disabled }
        try database.withExclusive { try database.setSchemaVersion(version) }
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
        if lhs.role.rawValue != rhs.role.rawValue { return lhs.role.rawValue < rhs.role.rawValue }
        return (lhs.timestamp?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude) < (rhs.timestamp?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude)
    }

    private struct RunningQuery {
        let lease: SQLiteQueryLease
        let task: Task<SearchResults, Error>
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
            if let db { api.close(db) }
            throw SearchIndexError.sqlite(code: result, message: api.errorMessage(db))
        }
        handle = db
        api.busyTimeout(db, 5_000)
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
            try execute("CREATE TABLE IF NOT EXISTS hermternal_search_sessions (session_id TEXT PRIMARY KEY NOT NULL, digest TEXT NOT NULL, incomplete INTEGER NOT NULL)")
            let version = try scalarString("SELECT value FROM hermternal_search_metadata WHERE key = 'schema_version' LIMIT 1")
            let validFTS = (try? queryRows("SELECT title, body, session_id, message_id, role, timestamp FROM hermternal_search_messages LIMIT 0")) != nil
            if version != String(SearchIndex.schemaVersion) || !validFTS { try rebuildSchema() }
        } catch { try rebuildSchema() }
    }

    func begin() throws { try execute("BEGIN IMMEDIATE") }
    func setSchemaVersion(_ version: Int) throws {
        try execute("UPDATE hermternal_search_metadata SET value = ? WHERE key = 'schema_version'", bindings: [.text(String(version))])
    }
    func commit() throws { try execute("COMMIT") }
    func rollback() { try? execute("ROLLBACK") }
    func sessionDigest(_ id: String) throws -> String? { try scalarString("SELECT digest FROM hermternal_search_sessions WHERE session_id = ? LIMIT 1", bindings: [.text(id)]) }
    func deleteSession(_ id: String) throws { try execute("DELETE FROM hermternal_search_messages WHERE session_id = ?", bindings: [.text(id)]) }
    func deleteSessionMetadata(_ id: String) throws { try execute("DELETE FROM hermternal_search_sessions WHERE session_id = ?", bindings: [.text(id)]) }
    func clearContent() throws { try execute("DELETE FROM hermternal_search_messages"); try execute("DELETE FROM hermternal_search_sessions") }
    func incompleteSessionCount() throws -> Int { Int(try scalarInt("SELECT count(*) FROM hermternal_search_sessions WHERE incomplete = 1")) }
    func messageCount(sessionID: String?) throws -> Int {
        Int(try scalarInt("SELECT count(*) FROM hermternal_search_messages" + (sessionID == nil ? "" : " WHERE session_id = ?"), bindings: sessionID.map { [.text($0)] } ?? []))
    }

    func upsertSessionMetadata(sessionID: String, digest: String, incomplete: Bool) throws {
        try execute("INSERT INTO hermternal_search_sessions(session_id, digest, incomplete) VALUES (?, ?, ?) ON CONFLICT(session_id) DO UPDATE SET digest = excluded.digest, incomplete = excluded.incomplete", bindings: [.text(sessionID), .text(digest), .int(incomplete ? 1 : 0)])
    }

    func insert(title: String, body: String, sessionID: String, messageID: Int64, role: String, timestamp: Date?) throws {
        try execute("INSERT INTO hermternal_search_messages(title, body, session_id, message_id, role, timestamp) VALUES (?, ?, ?, ?, ?, ?)", bindings: [.text(title), .text(body), .text(sessionID), .int64(messageID), .text(role), timestamp.map { .double($0.timeIntervalSince1970) } ?? .null])
    }

    func query(ftsQuery: String, limit: Int) throws -> SearchResults {
        guard limit > 0 else { return SearchResults(hits: [], incompleteSessions: try incompleteSessionCount()) }
        let rows = try queryRows("SELECT session_id, message_id, title, body, role, timestamp, snippet(hermternal_search_messages, -1, '⟦', '⟧', '…', 32), bm25(hermternal_search_messages, ?, ?) FROM hermternal_search_messages WHERE hermternal_search_messages MATCH ? ORDER BY bm25(hermternal_search_messages, ?, ?) LIMIT ?", bindings: [.double(10), .double(1), .text(ftsQuery), .double(10), .double(1), .int(limit)])
        let hits = rows.map { row -> SearchHit in
            var excerpt = row.text(6) ?? ""
            if !excerpt.contains("⟦") {
                let title = row.text(2) ?? ""
                excerpt = title.isEmpty ? (row.text(3) ?? "") : "⟦\(title)⟧ \(row.text(3) ?? "")"
            }
            return SearchHit(sessionID: row.text(0) ?? "", messageID: ServerMessageID(rawValue: row.int64(1)), sessionTitle: row.text(2) ?? "", excerpt: excerpt, role: Role(rawValue: row.text(4) ?? "")!, timestamp: row.double(5).map(Date.init(timeIntervalSince1970:)), score: row.double(7) ?? 0)
        }
        return SearchResults(hits: hits, incompleteSessions: try incompleteSessionCount())
    }

    private func rebuildSchema() throws {
        try execute("DROP TABLE IF EXISTS hermternal_search_messages")
        try execute("DROP TABLE IF EXISTS hermternal_search_sessions")
        try execute("DROP TABLE IF EXISTS hermternal_search_metadata")
        try execute("CREATE TABLE hermternal_search_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
        try execute("CREATE TABLE hermternal_search_sessions (session_id TEXT PRIMARY KEY NOT NULL, digest TEXT NOT NULL, incomplete INTEGER NOT NULL)")
        try execute("CREATE VIRTUAL TABLE hermternal_search_messages USING fts5(title, body, session_id UNINDEXED, message_id UNINDEXED, role UNINDEXED, timestamp UNINDEXED, tokenize='unicode61 remove_diacritics 2')")
        try execute("INSERT INTO hermternal_search_metadata(key, value) VALUES ('schema_version', '1')")
    }

    private enum Binding { case text(String), int(Int), int64(Int64), double(Double), null }
    private struct Value { let text: String?; let int64: Int64?; let double: Double? }
    private struct Row {
        let values: [Value]
        func text(_ n: Int) -> String? { values[n].text }
        func int64(_ n: Int) -> Int64 { values[n].int64 ?? 0 }
        func double(_ n: Int) -> Double? { values[n].double }
    }

    private func scalarString(_ sql: String, bindings: [Binding] = []) throws -> String? { try queryRows(sql, bindings: bindings).first?.text(0) }
    private func scalarInt(_ sql: String, bindings: [Binding] = []) throws -> Int64 { try queryRows(sql, bindings: bindings).first?.int64(0) ?? 0 }
    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        guard let handle else { throw SearchIndexError.disabled }
        if !bindings.isEmpty { _ = try queryRows(sql, bindings: bindings, collectRows: false); return }
        let result = sql.withCString { sqlite3_exec(handle, $0, nil, nil, nil) }
        guard result == SQLiteAPI.ok else { throw makeError(result) }
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
    func bindDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double) -> Int32 { sqlite3_bind_double(statement, index, value) }
    func bindNull(_ statement: OpaquePointer, _ index: Int32) -> Int32 { sqlite3_bind_null(statement, index) }
    func columnCount(_ statement: OpaquePointer) -> Int32 { sqlite3_column_count(statement) }
    func columnType(_ statement: OpaquePointer, _ index: Int32) -> Int32 { sqlite3_column_type(statement, index) }
    func columnText(_ statement: OpaquePointer, _ index: Int32) -> UnsafePointer<CChar>? {
        sqlite3_column_text(statement, index).map { unsafeBitCast($0, to: UnsafePointer<CChar>.self) }
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
    static func session(snapshot: SearchSessionSnapshot, documents: [SearchDocument]) -> String {
        var data = Data(); append(snapshot.sessionID, &data); append(snapshot.title, &data); append(snapshot.truncated ? "1" : "0", &data)
        for document in documents { append(String(document.messageID.rawValue), &data); append(document.body, &data); append(document.role.rawValue, &data); append(document.timestamp.map { String($0.timeIntervalSince1970) } ?? "", &data) }
        return SHA256.hash(data).map { String(format: "%02x", $0) }.joined()
    }
    private static func append(_ value: String, _ data: inout Data) { let bytes = Data(value.utf8); var count = UInt64(bytes.count).bigEndian; withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }; data.append(bytes) }
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

private extension UInt32 {
    func rotateRight(_ count: UInt32) -> UInt32 { (self >> count) | (self << (32 - count)) }
}
