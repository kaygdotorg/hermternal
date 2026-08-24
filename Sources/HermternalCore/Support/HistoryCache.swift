import Foundation

public struct CacheStatistics: Sendable {
    public let entryCount: Int
    public let bytes: Int64

    public init(entryCount: Int, bytes: Int64) {
        self.entryCount = entryCount
        self.bytes = bytes
    }
}

public struct CacheStoreResult: Sendable {
    public let addedEntry: Bool
    public let byteDelta: Int64

    public init(addedEntry: Bool, byteDelta: Int64) {
        self.addedEntry = addedEntry
        self.byteDelta = byteDelta
    }
}

public enum HistoryCacheFileKind: Equatable, Sendable {
    case current(String)
    case legacy(String)
    case legacyCollision
    case orphan
}
public struct SessionLocalCleanupResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case removed
        case failed(String)
        case notRequired

        public var succeeded: Bool {
            switch self {
            case .removed, .notRequired: return true
            case .failed: return false
            }
        }
    }

    public let sessionID: String
    public let cache: Outcome
    public let index: Outcome

    public init(sessionID: String, cache: Outcome, index: Outcome) {
        self.sessionID = sessionID
        self.cache = cache
        self.index = index
    }

    public var succeeded: Bool { cache.succeeded && index.succeeded }
}


/// Core transcript persistence seam. Plain HistoryCache is the no-search
/// implementation; SearchIndexReconciliation decorates the same boundary.
public protocol TranscriptPersisting: Sendable {
    func read(for id: String) async -> (transcript: CachedTranscript?, epoch: UInt64)
    /// Reads a transcript for warm projection without retaining a disk decode in memory.
    /// Existing memory entries may be returned directly.
    func readForWarming(for id: String) async -> (transcript: CachedTranscript?, epoch: UInt64)
    /// Stores a warm transcript on disk without retaining its decoded payload.
    /// The search decorator also indexes this payload through the same seam.
    func storeForWarming(
        _ messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot?,
        title: String,
        for id: String,
        expectedEpoch: UInt64?
    ) async throws -> CacheStoreResult
    func currentEpoch() async -> UInt64
    func store(
        _ messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot?,
        title: String,
        for id: String,
        expectedEpoch: UInt64?
    ) async throws -> CacheStoreResult
    func remove(sessionID: String) async throws -> SessionLocalCleanupResult
    func clear() async throws -> Bool
    /// Destructively reconciles disk and index state against `validIDs`.
    ///
    /// Callers MUST pass an authoritative, complete session list. A partial
    /// list can delete valid cache entries and search rows that are absent
    /// only because the list was paginated or failed to load completely.
    func reconcile(validIDs: [String]) async throws -> CacheStatistics
}

public protocol CacheFileSystem: Sendable {
    func createDirectory(at url: URL) throws
    func data(at url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func fileSize(at url: URL) -> Int64?
}

public struct LocalCacheFileSystem: CacheFileSystem {
    public init() {}

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func data(at url: URL) throws -> Data { try Data(contentsOf: url) }

    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
    }

    public func fileSize(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}

public protocol CacheCodec: Sendable {
    func encode(_ transcript: CachedTranscript) throws -> Data
    func decode(_ data: Data) throws -> CachedTranscript
    /// Validates a serialized cache entry without materializing its transcript.
    /// Custom codecs retain the old decode-based validation by default.
    func validate(_ data: Data) throws -> Bool
}

public extension CacheCodec {
    func validate(_ data: Data) throws -> Bool {
        _ = try decode(data)
        return true
    }
}

public struct JSONCacheCodec: CacheCodec {
    public init() {}

    public func encode(_ transcript: CachedTranscript) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(transcript)
    }

    public func decode(_ data: Data) throws -> CachedTranscript {
        try JSONDecoder().decode(CachedTranscript.self, from: data)
    }

    public func validate(_ data: Data) throws -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}

public struct CachedTranscript: Codable, Sendable {
    public let version: Int
    public let messages: [ChatMessage]
    public let snapshot: AuthoritativeTranscriptSnapshot?

    public init(
        version: Int,
        messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot?
    ) {
        self.version = version
        self.messages = messages
        self.snapshot = snapshot
    }

    /// The decoded residency charged to the bounded in-memory cache.
    ///
    /// Message text and snapshot/session strings are the dominant allocations,
    /// so their UTF-8 storage is charged in full. Value and collection storage
    /// is charged using its ABI stride plus fixed allocation slack. Dictionary
    /// buckets and the LRU's reference strings are charged by HistoryCache's
    /// per-entry overhead; allocator bookkeeping remains uncharged because it
    /// is bounded by the fixed number of resident entries.
    public var retainedBytes: Int {
        var total = MemoryLayout<CachedTranscript>.stride + 32
        total = Self.add(total, Self.multiply(MemoryLayout<ChatMessage>.stride, by: messages.count))
        total = Self.add(total, 32)
        for message in messages {
            total = Self.add(total, message.text.utf8.count)
        }
        if let snapshot {
            total = Self.add(total, MemoryLayout<AuthoritativeTranscriptSnapshot>.stride + 32)
            total = Self.add(total, snapshot.sessionID.utf8.count)
        }
        return total
    }

    private static func add(_ lhs: Int, _ rhs: Int) -> Int {
        lhs > Int.max - rhs ? Int.max : lhs + rhs
    }

    private static func multiply(_ lhs: Int, by rhs: Int) -> Int {
        rhs != 0 && lhs > Int.max / rhs ? Int.max : lhs * rhs
    }
}

public actor HistoryCache: TranscriptPersisting {
    /// Version 3 invalidates files containing the retired content-hash IDs.
    public static let version = 3

    private let directory: URL?
    private let fileSystem: any CacheFileSystem
    private let codec: any CacheCodec
    // Ordinary opens retain a small byte-bounded LRU so repeated navigation
    // stays fast without allowing a corpus-sized decoded cache. REST warming
    // uses storeForWarming and bypasses this dictionary entirely.
    public static let defaultMemoryBudgetBytes = 128 * 1024 * 1024
    private let memoryBudgetBytes: Int
    private var memory: [String: CachedTranscript] = [:]
    private var memoryOrder: [String] = []
    private var memoryBytes: Int64 = 0
    // Disk reads run outside the actor while this table coalesces callers.
    // A flight commits decoded residency exactly once when a waiter resumes.
    private var inFlightReads: [String: ReadFlight] = [:]
    // A write is valid only if no clear happened after the read it derives
    // from. The epoch is actor-local so checking it and touching disk are
    // one atomic operation relative to clear().
    private var epoch: UInt64 = 0

    private struct CacheReadResult: Sendable {
        let transcript: CachedTranscript?
        let epoch: UInt64
    }

    private struct DiskReadResult: Sendable {
        enum Source: Sendable, Equatable {
            case current
            case legacy
        }

        let transcript: CachedTranscript?
        let source: Source?
        let invalidURLs: [URL]
        let cancelled: Bool
    }

    private enum DiskCandidate: Sendable {
        case found(CachedTranscript)
        case missing
        case unavailable
        case invalid
        case cancelled
    }

    private final class ReadFlight: @unchecked Sendable {
        let epoch: UInt64
        let task: Task<DiskReadResult, Never>
        var waiterCount = 0
        var accounted = false
        var result: CacheReadResult?

        init(epoch: UInt64, task: Task<DiskReadResult, Never>) {
            self.epoch = epoch
            self.task = task
        }
    }

    private final class ReadWaiter: @unchecked Sendable {
        var released = false
    }

    private func entryBytes(_ transcript: CachedTranscript, id: String) -> Int64 {
        let fixed = MemoryLayout<String>.stride * 2 + 64
        let total = transcript.retainedBytes > Int.max - fixed
            ? Int.max
            : transcript.retainedBytes + fixed
        let withID = total > Int.max - id.utf8.count
            ? Int.max
            : total + id.utf8.count
        return Int64(clamping: withID)
    }

    @discardableResult
    private func remember(_ transcript: CachedTranscript, for id: String) -> Bool {
        forget(id)
        let cost = entryBytes(transcript, id: id)
        guard cost <= Int64(memoryBudgetBytes) else { return false }
        memory[id] = transcript
        memoryOrder.append(id)
        memoryBytes += cost
        while memoryBytes > Int64(memoryBudgetBytes),
              let evicted = memoryOrder.first,
              evicted != id {
            memoryOrder.removeFirst()
            if let removed = memory.removeValue(forKey: evicted) {
                memoryBytes -= entryBytes(removed, id: evicted)
            }
        }
        return true
    }

    private func forget(_ id: String) {
        if let removed = memory.removeValue(forKey: id) {
            memoryBytes -= entryBytes(removed, id: id)
        }
        memoryOrder.removeAll { $0 == id }
    }

    /// Exposes the bounded decoded residency for focused cache diagnostics.
    public func memoryStatistics() -> CacheStatistics {
        CacheStatistics(entryCount: memory.count, bytes: memoryBytes)
    }


    /// Exposes the bounded decoded residency for focused cache diagnostics.
    public func memoryEntryCount() -> Int { memory.count }

    /// Returns the app-owned history location under the platform's caches
    /// directory. On macOS this preserves the existing bundle-specific path.
    public static func historyDirectory(cachesDirectory: URL) -> URL {
        cachesDirectory
            .appending(path: "\(AppIdentity.bundleID)/history", directoryHint: .isDirectory)
    }

    /// Resolves the platform's caches directory without falling back to a
    /// home-directory path.
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        guard let cachesDirectory = fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first
        else {
            return nil
        }
        return historyDirectory(cachesDirectory: cachesDirectory)
    }

    public init(
        directory: URL? = nil,
        fileSystem: any CacheFileSystem = LocalCacheFileSystem(),
        codec: any CacheCodec = JSONCacheCodec(),
        memoryBudgetBytes: Int = HistoryCache.defaultMemoryBudgetBytes
    ) {
        precondition(memoryBudgetBytes > 0, "History cache memory budget must be positive")
        self.memoryBudgetBytes = memoryBudgetBytes
        self.directory = (directory ?? Self.defaultDirectory())?.resolvingSymlinksInPath()
        self.fileSystem = fileSystem
        self.codec = codec
        if let directory = self.directory {
            try? fileSystem.createDirectory(at: directory)
        }
    }

    private struct ReconciliationIndex {
        let currentIDsByPath: [String: String]
        let legacyIDsByPath: [String: [String]]

        init(directory: URL, validIDs: [String]) {
            var currentIDsByPath: [String: String] = [:]
            var legacyIDsByPath: [String: [String]] = [:]
            for id in validIDs {
                let currentPath = HistoryCache.pathIdentity(
                    HistoryCache.cacheURL(
                        in: directory,
                        filename: HistoryCache.encodedFilename(for: id)
                    )
                )
                if currentIDsByPath[currentPath] == nil {
                    // Preserve validIDs.first semantics for duplicate current paths.
                    currentIDsByPath[currentPath] = id
                }

                let legacyPath = HistoryCache.pathIdentity(
                    HistoryCache.cacheURL(
                        in: directory,
                        filename: HistoryCache.legacyFilename(for: id)
                    )
                )
                legacyIDsByPath[legacyPath, default: []].append(id)
            }
            self.currentIDsByPath = currentIDsByPath
            self.legacyIDsByPath = legacyIDsByPath
        }

        func classify(filePath: String) -> HistoryCacheFileKind {
            if let currentID = currentIDsByPath[filePath] {
                return .current(currentID)
            }
            guard let legacyIDs = legacyIDsByPath[filePath] else {
                return .orphan
            }
            if legacyIDs.count == 1 {
                return .legacy(legacyIDs[0])
            }
            return .legacyCollision
        }
    }

    public static func classifyCacheFile(
        at file: URL,
        in directory: URL,
        validIDs: [String]
    ) -> HistoryCacheFileKind {
        let directory = directory.resolvingSymlinksInPath()
        let index = ReconciliationIndex(directory: directory, validIDs: validIDs)
        return index.classify(filePath: pathIdentity(file))
    }

    public static func validatesCacheData(
        _ data: Data,
        codec: any CacheCodec
    ) -> Bool {
        (try? codec.validate(data)) == true
    }

    private static func pathIdentity(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func cacheURL(in directory: URL, filename: String) -> URL {
        URL(fileURLWithPath: directory.path + "/" + filename + ".json")
    }

    private static func legacyFilename(for id: String) -> String {
        id.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
    }

    private static func encodedFilename(for id: String) -> String {
        id.utf8.reduce(into: "") { result, byte in
            if (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122) {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
    }

    private func url(for id: String) -> URL? {
        guard let directory else { return nil }
        return Self.cacheURL(in: directory, filename: Self.encodedFilename(for: id))
    }

    /// The legacy filename, retained only to migrate caches written before
    /// punctuation was made injective.
    private func legacyURL(for id: String) -> URL? {
        guard let directory else { return nil }
        return Self.cacheURL(in: directory, filename: Self.legacyFilename(for: id))
    }

    /// Keep ordinary IDs readable while escaping every other UTF-8 byte.
    /// Escaping bytes, rather than scalars, makes the mapping injective for
    /// both punctuation and non-ASCII IDs.
    private func encodedFilename(for id: String) -> String {
        Self.encodedFilename(for: id)
    }

    private enum StoredTranscriptError: Error {
        case unavailable
        case invalid
    }

    private func storedTranscript(at url: URL) throws -> CachedTranscript {
        let data: Data
        do {
            data = try fileSystem.data(at: url)
        } catch {
            throw StoredTranscriptError.unavailable
        }
        do {
            let stored = try codec.decode(data)
            guard stored.version == Self.version else {
                throw StoredTranscriptError.invalid
            }
            return stored
        } catch let error as StoredTranscriptError {
            throw error
        } catch {
            throw StoredTranscriptError.invalid
        }
    }


    @discardableResult
    private func adoptLegacyData(_ data: Data, from legacy: URL, to target: URL) -> Bool {
        guard (try? fileSystem.write(data, to: target)) != nil else { return false }
        try? fileSystem.removeItem(at: legacy)
        return true
    }

    @discardableResult
    private func adoptLegacyTranscript(
        _ stored: CachedTranscript,
        for id: String,
        from legacy: URL,
        to target: URL
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let migrated = try? codec.encode(stored),
              !Task.isCancelled
        else {
            if !Task.isCancelled { remember(stored, for: id) }
            return false
        }
        guard !Task.isCancelled,
              (try? fileSystem.write(migrated, to: target)) != nil,
              !Task.isCancelled
        else {
            if !Task.isCancelled { remember(stored, for: id) }
            return false
        }
        guard !Task.isCancelled else { return false }
        try? fileSystem.removeItem(at: legacy)
        guard !Task.isCancelled else { return false }
        remember(stored, for: id)
        return true
    }
    private static func readCandidate(
        at url: URL,
        fileSystem: any CacheFileSystem,
        codec: any CacheCodec
    ) -> DiskCandidate {
        guard !Task.isCancelled else { return .cancelled }
        guard fileSystem.fileExists(at: url) else { return .missing }
        guard !Task.isCancelled else { return .cancelled }

        let data: Data
        do {
            data = try fileSystem.data(at: url)
        } catch {
            return .unavailable
        }
        guard !Task.isCancelled else { return .cancelled }

        do {
            let stored = try codec.decode(data)
            guard !Task.isCancelled else { return .cancelled }
            guard stored.version == Self.version else { return .invalid }
            return .found(stored)
        } catch {
            return .invalid
        }
    }

    private static func readDisk(
        target: URL,
        legacy: URL?,
        fileSystem: any CacheFileSystem,
        codec: any CacheCodec
    ) -> DiskReadResult {
        guard !Task.isCancelled else {
            return DiskReadResult(
                transcript: nil,
                source: nil,
                invalidURLs: [],
                cancelled: true
            )
        }

        var invalidURLs: [URL] = []
        switch readCandidate(at: target, fileSystem: fileSystem, codec: codec) {
        case .found(let stored):
            return DiskReadResult(
                transcript: stored,
                source: .current,
                invalidURLs: [],
                cancelled: false
            )
        case .invalid:
            invalidURLs.append(target)
        case .cancelled:
            return DiskReadResult(
                transcript: nil,
                source: nil,
                invalidURLs: [],
                cancelled: true
            )
        case .missing, .unavailable:
            break
        }

        guard let legacy,
              Self.pathIdentity(legacy) != Self.pathIdentity(target)
        else {
            return DiskReadResult(
                transcript: nil,
                source: nil,
                invalidURLs: invalidURLs,
                cancelled: false
            )
        }
        switch readCandidate(at: legacy, fileSystem: fileSystem, codec: codec) {
        case .found(let stored):
            return DiskReadResult(
                transcript: stored,
                source: .legacy,
                invalidURLs: invalidURLs,
                cancelled: false
            )
        case .invalid:
            invalidURLs.append(legacy)
        case .cancelled:
            return DiskReadResult(
                transcript: nil,
                source: nil,
                invalidURLs: [],
                cancelled: true
            )
        case .missing, .unavailable:
            break
        }
        return DiskReadResult(
            transcript: nil,
            source: nil,
            invalidURLs: invalidURLs,
            cancelled: false
        )
    }

    private func releaseReadWaiter(
        for id: String,
        flight: ReadFlight,
        waiter: ReadWaiter
    ) {
        guard !waiter.released else { return }
        waiter.released = true
        flight.waiterCount -= 1
        guard flight.waiterCount == 0,
              inFlightReads[id] === flight
        else {
            return
        }
        inFlightReads.removeValue(forKey: id)
        flight.task.cancel()
    }

    private func readIsolatedAsync(
        for id: String,
        request: ContentionTrace.Request?
    ) async -> CacheReadResult {
        var contentionRequest = request
        guard !Task.isCancelled else {
            ContentionTrace.finishInteractive(&contentionRequest)
            return CacheReadResult(transcript: nil, epoch: epoch)
        }
        if let startedAt = contentionRequest?.beganAt {
            ContentionTrace.recordLockWait(
                &contentionRequest,
                startedAt: startedAt
            )
        }
        ContentionTrace.finishInteractive(&contentionRequest)
        let observedEpoch = epoch
        if let hit = memory[id] {
            remember(hit, for: id)
            return CacheReadResult(transcript: hit, epoch: observedEpoch)
        }
        guard let target = url(for: id), !Task.isCancelled else {
            return CacheReadResult(transcript: nil, epoch: observedEpoch)
        }

        let flight: ReadFlight
        if let existing = inFlightReads[id] {
            flight = existing
        } else {
            let legacy = legacyURL(for: id)
            let task = Task.detached(priority: nil) { [fileSystem, codec] in
                Self.readDisk(
                    target: target,
                    legacy: legacy,
                    fileSystem: fileSystem,
                    codec: codec
                )
            }
            flight = ReadFlight(epoch: observedEpoch, task: task)
            inFlightReads[id] = flight
        }
        let waiter = ReadWaiter()
        flight.waiterCount += 1
        let disk = await withTaskCancellationHandler(operation: {
            await flight.task.value
        }, onCancel: {
            Task {
                await self.releaseReadWaiter(
                    for: id,
                    flight: flight,
                    waiter: waiter
                )
            }
        })
        guard !Task.isCancelled else {
            releaseReadWaiter(for: id, flight: flight, waiter: waiter)
            return CacheReadResult(transcript: nil, epoch: observedEpoch)
        }
        guard !disk.cancelled, flight.epoch == epoch else {
            if !flight.accounted {
                flight.accounted = true
                flight.result = CacheReadResult(transcript: nil, epoch: epoch)
            }
            let result = flight.result ?? CacheReadResult(transcript: nil, epoch: epoch)
            releaseReadWaiter(for: id, flight: flight, waiter: waiter)
            return result
        }
        if !flight.accounted {
            for invalidURL in disk.invalidURLs where !Task.isCancelled {
                try? fileSystem.removeItem(at: invalidURL)
            }
            guard !Task.isCancelled else {
                releaseReadWaiter(for: id, flight: flight, waiter: waiter)
                return CacheReadResult(transcript: nil, epoch: observedEpoch)
            }
            if let stored = disk.transcript {
                if disk.source == .legacy,
                   let legacy = legacyURL(for: id) {
                    _ = adoptLegacyTranscript(
                        stored,
                        for: id,
                        from: legacy,
                        to: target
                    )
                } else {
                    remember(stored, for: id)
                }
            }
            guard !Task.isCancelled else {
                releaseReadWaiter(for: id, flight: flight, waiter: waiter)
                return CacheReadResult(transcript: nil, epoch: observedEpoch)
            }
            let transcript = disk.transcript
            flight.result = CacheReadResult(
                transcript: transcript,
                epoch: observedEpoch
            )
            flight.accounted = true
        }
        let result = flight.result ?? CacheReadResult(
            transcript: disk.transcript,
            epoch: observedEpoch
        )
        releaseReadWaiter(for: id, flight: flight, waiter: waiter)
        return result
    }


    public func messages(for id: String) -> [ChatMessage]? {
        transcript(for: id)?.messages
    }

    public func snapshot(for id: String) -> AuthoritativeTranscriptSnapshot? {
        transcript(for: id)?.snapshot
    }

    public nonisolated func read(
        for id: String
    ) async -> (transcript: CachedTranscript?, epoch: UInt64) {
        let request = ContentionTrace.beginInteractive(resource: "history-read")
        let result = await readIsolatedAsync(for: id, request: request)
        return (result.transcript, result.epoch)
    }

    private func readIsolated(
        for id: String,
        request: ContentionTrace.Request?
    ) -> (transcript: CachedTranscript?, epoch: UInt64) {
        var contentionRequest = request
        if let startedAt = contentionRequest?.beganAt {
            ContentionTrace.recordLockWait(
                &contentionRequest,
                startedAt: startedAt
            )
        }
        ContentionTrace.finishInteractive(&contentionRequest)
        let observedEpoch = epoch
        if let hit = memory[id] {
            remember(hit, for: id)
            return (hit, observedEpoch)
        }
        guard let target = url(for: id) else {
            return (nil, observedEpoch)
        }
        if fileSystem.fileExists(at: target) {
            do {
                let stored = try storedTranscript(at: target)
                remember(stored, for: id)
                return (stored, observedEpoch)
            } catch StoredTranscriptError.invalid {
                // A present file is removed only after a genuine decode or
                // version failure; a lookup miss must never destroy a cache.
                try? fileSystem.removeItem(at: target)
            } catch StoredTranscriptError.unavailable {
                // Leave unreadable files in place for a later retry.
            }
            catch {
                // Preserve the file if the filesystem reports an unknown read failure.
            }
        }

        guard let legacy = legacyURL(for: id), Self.pathIdentity(legacy) != Self.pathIdentity(target) else {
            return (nil, observedEpoch)
        }
        guard fileSystem.fileExists(at: legacy) else {
            return (nil, observedEpoch)
        }
        do {
            let stored = try storedTranscript(at: legacy)
            _ = adoptLegacyTranscript(stored, for: id, from: legacy, to: target)
            return (stored, observedEpoch)
        } catch StoredTranscriptError.invalid {
            try? fileSystem.removeItem(at: legacy)
            return (nil, observedEpoch)
        } catch StoredTranscriptError.unavailable {
            return (nil, observedEpoch)
        }
        catch {
            return (nil, observedEpoch)
        }
    }
    /// Reads a complete transcript for warming without retaining a cold disk
    /// decode in `memory`. A resident entry is still returned directly.
    public func readForWarming(for id: String) -> (transcript: CachedTranscript?, epoch: UInt64) {
        let observedEpoch = epoch
        if let hit = memory[id] {
            remember(hit, for: id)
            return (hit, observedEpoch)
        }
        guard let target = url(for: id) else {
            return (nil, observedEpoch)
        }

        if fileSystem.fileExists(at: target) {
            do {
                let stored = try storedTranscript(at: target)
                return (stored, observedEpoch)
            } catch StoredTranscriptError.invalid {
                try? fileSystem.removeItem(at: target)
            } catch StoredTranscriptError.unavailable {
                // Leave unreadable files in place for a later retry.
            } catch {
                // Preserve the file if the filesystem reports an unknown read failure.
            }
        }

        guard let legacy = legacyURL(for: id),
              Self.pathIdentity(legacy) != Self.pathIdentity(target),
              fileSystem.fileExists(at: legacy)
        else {
            return (nil, observedEpoch)
        }

        do {
            let stored = try storedTranscript(at: legacy)
            // Preserve legacy migration behavior on disk, but deliberately do
            // not populate memory: this call is used for bounded warm residency.
            if let migrated = try? codec.encode(stored) {
                _ = adoptLegacyData(migrated, from: legacy, to: target)
            }
            return (stored, observedEpoch)
        } catch StoredTranscriptError.invalid {
            try? fileSystem.removeItem(at: legacy)
            return (nil, observedEpoch)
        } catch StoredTranscriptError.unavailable {
            return (nil, observedEpoch)
        } catch {
            return (nil, observedEpoch)
        }
    }

    public func currentEpoch() -> UInt64 { epoch }
    /// TranscriptPersisting overload; plain cache ignores the title because
    /// it stores message history only.
    public func store(
        _ messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot?,
        title _: String,
        for id: String,
        expectedEpoch: UInt64?
    ) -> CacheStoreResult {
        store(messages, snapshot: snapshot, for: id, expectedEpoch: expectedEpoch)
    }

    public func storeForWarming(
        _ messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot?,
        title _: String,
        for id: String,
        expectedEpoch: UInt64? = nil
    ) -> CacheStoreResult {
        let payload = CachedTranscript(version: Self.version, messages: messages, snapshot: snapshot)
        return storePayload(payload, for: id, expectedEpoch: expectedEpoch, retainMemory: false)
    }

    private func storePayload(
        _ payload: CachedTranscript,
        for id: String,
        expectedEpoch: UInt64?,
        retainMemory: Bool
    ) -> CacheStoreResult {
        let authorizedEpoch = expectedEpoch ?? epoch
        guard authorizedEpoch == epoch, !Task.isCancelled else {
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        guard let data = try? codec.encode(payload),
              authorizedEpoch == epoch,
              !Task.isCancelled,
              let target = url(for: id)
        else {
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        let oldData = try? fileSystem.data(at: target)
        let existed = fileSystem.fileExists(at: target)
        if oldData == data {
            if retainMemory {
                remember(payload, for: id)
            } else {
                forget(id)
            }
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        let oldSize = oldData.map { Int64($0.count) } ?? fileSystem.fileSize(at: target) ?? 0
        guard authorizedEpoch == epoch,
              (try? fileSystem.write(data, to: target)) != nil
        else {
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        if retainMemory {
            remember(payload, for: id)
        } else {
            forget(id)
        }
        return CacheStoreResult(
            addedEntry: !existed,
            byteDelta: Int64(data.count) - oldSize
        )
    }

    @discardableResult
    public func remove(sessionID: String) -> SessionLocalCleanupResult {
        forget(sessionID)
        let targets = [url(for: sessionID), legacyURL(for: sessionID)]
            .compactMap { $0 }
            .reduce(into: [String: URL]()) { result, target in
                result[target.path] = target
            }
            .values
        var success = true
        for target in targets where fileSystem.fileExists(at: target) {
            do {
                try fileSystem.removeItem(at: target)
            } catch {
                success = false
            }
        }
        return SessionLocalCleanupResult(
            sessionID: sessionID,
            cache: success ? .removed : .failed("The local transcript cache could not be removed."),
            index: .notRequired
        )
    }

    public func transcript(for id: String) -> CachedTranscript? {
        readIsolated(for: id, request: nil).transcript
    }

    @discardableResult
    public func store(
        _ messages: [ChatMessage],
        snapshot: AuthoritativeTranscriptSnapshot? = nil,
        for id: String,
        expectedEpoch: UInt64? = nil
    ) -> CacheStoreResult {
        let authorizedEpoch = expectedEpoch ?? epoch
        guard authorizedEpoch == epoch, !Task.isCancelled else {
            return CacheStoreResult(addedEntry: false, byteDelta: 0)
        }
        if memory[id] == nil {
            _ = readIsolated(for: id, request: nil)
        }
        let payload = CachedTranscript(version: Self.version, messages: messages, snapshot: snapshot)
        return storePayload(payload, for: id, expectedEpoch: expectedEpoch, retainMemory: true)
    }

    public func isCached(_ id: String) -> Bool { transcript(for: id) != nil }

    public func reconcile(validIDs: [String]) -> CacheStatistics {
        // Reconcile establishes disk truth, so no stale in-memory transcript survives it.
        memory.removeAll()
        memoryOrder.removeAll()
        memoryBytes = 0
        guard let directory,
              let files = try? fileSystem.contentsOfDirectory(at: directory)
        else {
            return CacheStatistics(entryCount: 0, bytes: 0)
        }
        let reconciliationIndex = ReconciliationIndex(
            directory: directory,
            validIDs: validIDs
        )
        var bytes: Int64 = 0
        var count = 0
        for file in files where file.pathExtension == "json" {
            let kind = reconciliationIndex.classify(filePath: Self.pathIdentity(file))
            let id: String
            let isLegacy: Bool
            switch kind {
            case .current(let currentID):
                id = currentID
                isLegacy = false
            case .legacy(let legacyID):
                id = legacyID
                isLegacy = true
                if let target = url(for: id),
                   Self.pathIdentity(target) == Self.pathIdentity(file) {
                    continue
                }
            case .legacyCollision:
                // A legacy collision cannot be assigned safely. Keep it for
                // a direct read rather than deleting a user's only copy.
                continue
            case .orphan:
                try? fileSystem.removeItem(at: file)
                continue
            }

            guard let data = try? fileSystem.data(at: file),
                  Self.validatesCacheData(data, codec: codec)
            else {
                try? fileSystem.removeItem(at: file)
                continue
            }
            let size = fileSystem.fileSize(at: file) ?? Int64(data.count)
            guard size > 0 else {
                try? fileSystem.removeItem(at: file)
                continue
            }
            if isLegacy, let target = url(for: id) {
                _ = adoptLegacyData(data, from: file, to: target)
                bytes += fileSystem.fileSize(at: target) ?? size
            } else {
                bytes += size
            }
            count += 1
        }
        return CacheStatistics(entryCount: count, bytes: bytes)
    }

    @discardableResult
    public func clear() -> Bool {
        epoch &+= 1
        guard !Task.isCancelled, let directory else { return false }
        do {
            if fileSystem.fileExists(at: directory) { try fileSystem.removeItem(at: directory) }
            memory.removeAll()
            memoryOrder.removeAll()
            memoryBytes = 0
            try fileSystem.createDirectory(at: directory)
            return true
        } catch {
            return false
        }
    }


}
