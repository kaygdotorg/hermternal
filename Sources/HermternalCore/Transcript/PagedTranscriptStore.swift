import Foundation

public struct TranscriptRoute: Codable, Hashable, Sendable {
    public let sessionID: String
    public let generation: UInt64
    public let epoch: UInt64

    public init(sessionID: String, generation: UInt64 = 0, epoch: UInt64 = 0) {
        precondition(!sessionID.isEmpty)
        self.sessionID = sessionID
        self.generation = generation
        self.epoch = epoch
    }
}

public enum TranscriptCountKind: String, Codable, Sendable {
    case exact
    case provisional
}

public struct TranscriptSummary: Codable, Hashable, Sendable {
    public let rowCount: Int
    public let messageCount: Int
    public let countKind: TranscriptCountKind
    public let generation: UInt64
    public let epoch: UInt64

    public init(rowCount: Int, messageCount: Int, countKind: TranscriptCountKind = .exact, generation: UInt64 = 0, epoch: UInt64 = 0) {
        self.rowCount = rowCount
        self.messageCount = messageCount
        self.countKind = countKind
        self.generation = generation
        self.epoch = epoch
    }

    public var isExact: Bool { countKind == .exact }
    public var exactRowCount: Int? { isExact ? rowCount : nil }
    public var totalRows: Int { rowCount }
    public var isProvisional: Bool { countKind == .provisional }
    public var totalCount: Int { rowCount }
}

public enum TranscriptPageOrigin: Codable, Hashable, Sendable {
    case ordinal(Int)
    case tail
}

public struct TranscriptPageRequest: Codable, Hashable, Sendable {
    public static let hardMaximumRows = 256
    public static let hardMaximumBytes = 1 * 1024 * 1024
    public let origin: TranscriptPageOrigin
    public let maximumBytes: Int
    public let maximumRows: Int
    public let expectedGeneration: UInt64?
    public let expectedEpoch: UInt64?

    public init(
        startOrdinal: Int = 0,
        maximumBytes: Int,
        maximumRows: Int,
        expectedGeneration: UInt64? = nil,
        expectedEpoch: UInt64? = nil
    ) {
        precondition(startOrdinal >= 0 && maximumBytes > 0 && maximumRows > 0)
        self.origin = .ordinal(startOrdinal)
        self.maximumBytes = min(maximumBytes, Self.hardMaximumBytes)
        self.maximumRows = min(maximumRows, Self.hardMaximumRows)
        self.expectedGeneration = expectedGeneration
        self.expectedEpoch = expectedEpoch
    }

    public init(tail maximumBytes: Int, maximumRows: Int, expectedGeneration: UInt64? = nil, expectedEpoch: UInt64? = nil) {
        precondition(maximumBytes > 0 && maximumRows > 0)
        self.origin = .tail
        self.maximumBytes = min(maximumBytes, Self.hardMaximumBytes)
        self.maximumRows = min(maximumRows, Self.hardMaximumRows)
        self.expectedGeneration = expectedGeneration
        self.expectedEpoch = expectedEpoch
    }

    public var startOrdinal: Int? {
        if case .ordinal(let value) = origin { return value }
        return nil
    }
    public var isTail: Bool {
        if case .tail = origin { return true }
        return false
    }
    public var maxBytes: Int { maximumBytes }
    public var maxRows: Int { maximumRows }

    public init(start: Int, maxBytes: Int, maxRows: Int, expectedGeneration: UInt64? = nil, expectedEpoch: UInt64? = nil) {
        self.init(startOrdinal: start, maximumBytes: maxBytes, maximumRows: maxRows, expectedGeneration: expectedGeneration, expectedEpoch: expectedEpoch)
    }

    public static func head(maximumBytes: Int, maximumRows: Int) -> Self {
        Self(maximumBytes: maximumBytes, maximumRows: maximumRows)
    }
    public static func tail(maximumBytes: Int, maximumRows: Int) -> Self {
        Self(tail: maximumBytes, maximumRows: maximumRows)
    }
}

public struct TranscriptPagePayload: Codable, Hashable, Sendable {
    public let rows: [TranscriptRow]
    public let byteCount: Int

    public init(rows: [TranscriptRow], byteCount: Int) {
        self.rows = rows
        self.byteCount = byteCount
    }
    public var descriptors: [TranscriptRowDescriptor] { rows.map(\.descriptor) }
}

public struct TranscriptPage: Codable, Hashable, Sendable {
    public typealias Payload = TranscriptPagePayload
    public let payload: TranscriptPagePayload
    public let startOrdinal: Int
    public let nextOrdinal: Int
    public let hasMore: Bool
    public let summary: TranscriptSummary

    public init(payload: TranscriptPagePayload, startOrdinal: Int, nextOrdinal: Int, hasMore: Bool, summary: TranscriptSummary) {
        self.payload = payload
        self.startOrdinal = startOrdinal
        self.nextOrdinal = nextOrdinal
        self.hasMore = hasMore
        self.summary = summary
    }

    public var rows: [TranscriptRow] { payload.rows }
    public var descriptors: [TranscriptRowDescriptor] { payload.descriptors }
}

public enum TranscriptMutation: Sendable {
    case append(WireMessageRecord)
    case replace(WireMessageRecord)
    case replaceText(messageID: String, text: String, revision: UInt64)
    case remove(messageID: String)
    case removeMany(messageIDs: [String])
    case clear
}

public struct TranscriptMutationResult: Sendable, Equatable {
    public let applied: Bool
    public let generation: UInt64
    public let epoch: UInt64
    public let summary: TranscriptSummary

    public init(applied: Bool, generation: UInt64, epoch: UInt64, summary: TranscriptSummary) {
        self.applied = applied
        self.generation = generation
        self.epoch = epoch
        self.summary = summary
    }
}

public struct TranscriptBatchMutationResult: Sendable {
    public let appliedRecords: [WireMessageRecord]
    public let generation: UInt64
    public let epoch: UInt64
    public let summary: TranscriptSummary

    public init(
        appliedRecords: [WireMessageRecord],
        generation: UInt64,
        epoch: UInt64,
        summary: TranscriptSummary
    ) {
        self.appliedRecords = appliedRecords
        self.generation = generation
        self.epoch = epoch
        self.summary = summary
    }
}

public struct TranscriptStoreMetrics: Sendable, Equatable {
    public let pageReads: Int
    public let pageCacheHits: Int
    public let pageCacheEvictions: Int
    public let staleWrites: Int
    public let cancelledReads: Int
    public let diskReads: Int
    public let diskWrites: Int
    public let byteMaterializations: Int
    public let memory: TranscriptMemoryMetrics

    public init(pageReads: Int = 0, pageCacheHits: Int = 0, pageCacheEvictions: Int = 0, staleWrites: Int = 0, cancelledReads: Int = 0, diskReads: Int = 0, diskWrites: Int = 0, byteMaterializations: Int = 0, memory: TranscriptMemoryMetrics) {
        self.pageReads = pageReads; self.pageCacheHits = pageCacheHits; self.pageCacheEvictions = pageCacheEvictions; self.staleWrites = staleWrites; self.cancelledReads = cancelledReads; self.diskReads = diskReads; self.diskWrites = diskWrites; self.byteMaterializations = byteMaterializations; self.memory = memory
    }
}

public enum TranscriptStoreError: Error, Equatable, Sendable {
    case staleGeneration(expected: UInt64, actual: UInt64)
    case staleEpoch(expected: UInt64, actual: UInt64)
    case corruptManifest
    case corruptIndex
    case missingRecord(String)
    case invalidMutation
}

/// A bounded actor that persists message records and row metadata incrementally.
public actor PagedTranscriptStore: TranscriptTurnPageLocating {
    public typealias Metrics = TranscriptStoreMetrics
    public static let defaultRowByteLimit = 256
    public static let defaultPageRows = 64

    private let directory: URL
    private let fileSystem: any TranscriptFileSystem
    public let route: TranscriptRoute
    public let memoryBudget: TranscriptMemoryBudget
    private var generation: UInt64
    private var epoch: UInt64
    private var loaded = false
    private var summaryCountKind: TranscriptCountKind = .exact
    private var reportedRowCount: Int?
    private var entries: [String: TranscriptDiskIndex.Entry] = [:]
    private var descriptors: [TranscriptRowDescriptor] = []
    private var order: [String] = []
    /// Compact turn spans in full wire order.
    private var turnIndex: [TranscriptTurnIndexEntry] = []
    private var turnOrdinalByMessageID: [String: Int] = [:]
    /// Marker metadata is indexed in full wire order, independently of pages.
    private var modelSwitchIndex: [TranscriptModelSwitchMarker] = []
    
    private var pageCache: [String: TranscriptPage] = [:]
    private var pageOrder: [String] = []
    private var pageAdmissions: [String: TranscriptMemoryAdmission] = [:]
    private var pageReads = 0
    private var pageCacheHits = 0
    private var pageCacheEvictions = 0
    private var staleWrites = 0
    private var cancelledReads = 0
    private var diskReads = 0
    private var diskWrites = 0
    private var replayRecordID: String?
    private var replayRecord: WireMessageRecord?
    private var replayRecordBytes: [UInt8] = []
    private var byteMaterializations = 0

    public init(
        route: TranscriptRoute,
        directory: URL,
        fileSystem: any TranscriptFileSystem = LocalTranscriptFileSystem(),
        memoryBudget: TranscriptMemoryBudget = TranscriptMemoryBudget()
    ) {
        self.route = route
        self.directory = directory
        self.fileSystem = fileSystem
        self.memoryBudget = memoryBudget
        self.generation = route.generation
        self.epoch = route.epoch
    }

    public init(
        sessionID: String,
        directory: URL,
        fileSystem: any TranscriptFileSystem = LocalTranscriptFileSystem(),
        memoryBudget: TranscriptMemoryBudget = TranscriptMemoryBudget()
    ) {
        self.init(route: TranscriptRoute(sessionID: sessionID), directory: directory, fileSystem: fileSystem, memoryBudget: memoryBudget)
    }

    public func load() throws {
        guard !loaded else { return }
        try fileSystem.createDirectory(directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let indexURL = directory.appendingPathComponent("index.json")
        var migratesVersion1 = false
        if fileSystem.exists(manifestURL) {
            let manifestData = try fileSystem.data(at: manifestURL)
            guard let manifest = try? JSONDecoder().decode(TranscriptManifest.self, from: manifestData),
                  manifest.version == 1 || manifest.version == TranscriptManifest.currentVersion
            else { throw TranscriptStoreError.corruptManifest }
            migratesVersion1 = manifest.version == 1
            generation = manifest.generation
            epoch = manifest.epoch
            summaryCountKind = manifest.exactCount ? .exact : .provisional
            reportedRowCount = manifest.exactCount ? nil : manifest.rowCount
        }
        if fileSystem.exists(indexURL) {
            let indexData = try fileSystem.data(at: indexURL)
            guard let index = try? JSONDecoder().decode(TranscriptDiskIndex.self, from: indexData) else { throw TranscriptStoreError.corruptIndex }
            entries = index.entries
            descriptors = index.descriptors
            let persistedOrder = index.orderedMessageIDs
                ?? entries.values.sorted { $0.firstOrdinal < $1.firstOrdinal }.map(\.messageID)
            order = TranscriptWireOrder.normalized(persistedOrder) ?? persistedOrder
            let repairedWireOrder = order != persistedOrder
            modelSwitchIndex = index.modelSwitches ?? []
            turnIndex = index.turns ?? []
            let requiresMetadataRebuild = index.modelSwitches == nil || index.turns == nil
            var rebuiltDescriptors = false
            if migratesVersion1 {
                if repairedWireOrder || requiresMetadataRebuild {
                    try rebuildDescriptors()
                    rebuiltDescriptors = true
                } else {
                    try rebuildTurnIndex()
                }
            } else if requiresMetadataRebuild || repairedWireOrder {
                try rebuildDescriptors()
                rebuiltDescriptors = true
            } else {
                buildTurnLookup()
            }
            if !rebuiltDescriptors,
               let count = try? currentRowCount(),
               descriptors.count != count {
                throw TranscriptStoreError.corruptIndex
            }
            if migratesVersion1 || repairedWireOrder { try persistIndex() }
        } else if migratesVersion1 {
            try persistIndex()
        }
        loaded = true
    }

    public func summary() throws -> TranscriptSummary {
        try ensureLoaded()
        return makeSummary()
    }

    public func currentRoute() throws -> TranscriptRoute {
        try ensureLoaded()
        return TranscriptRoute(sessionID: route.sessionID, generation: generation, epoch: epoch)
    }
    public func setGlobalRowCount(_ count: Int, exact: Bool) throws -> TranscriptSummary {
        try ensureLoaded()
        guard count >= 0 else { throw TranscriptStoreError.invalidMutation }
        summaryCountKind = exact ? .exact : .provisional
        reportedRowCount = exact ? nil : count
        try persistIndex()
        return makeSummary()
    }
    public func beginGeneration() throws -> TranscriptRoute {
        try ensureLoaded()
        generation &+= 1
        epoch &+= 1
        for admission in pageAdmissions.values { Task { await memoryBudget.release(admission) } }
        pageAdmissions.removeAll(keepingCapacity: true)
        pageCache.removeAll(keepingCapacity: true)
        replayRecordID = nil
        replayRecord = nil
        replayRecordBytes.removeAll(keepingCapacity: true)
        pageOrder.removeAll(keepingCapacity: true)
        try persistIndex()
        return TranscriptRoute(sessionID: route.sessionID, generation: generation, epoch: epoch)
    }

    public func globalRowCount() throws -> TranscriptSummary {
        try summary()
    }

    public func locate(messageID: String) throws -> RowLocation? {
        try ensureLoaded()
        guard let entry = entries[messageID], entry.rowCount > 0 else { return nil }
        return RowLocation(ordinal: entry.firstOrdinal, rowCount: entry.rowCount)
    }
    public func locateTurn(messageID: String) throws -> TurnLocation? {
        try ensureLoaded()
        guard let ordinal = turnOrdinalByMessageID[messageID] else { return nil }
        return TurnLocation(ordinal: ordinal)
    }

    public func page(_ request: TranscriptPageRequest) async throws -> TranscriptPage {
        try ensureLoaded()
        try checkRoute(generation: request.expectedGeneration, epoch: request.expectedEpoch)
        guard !Task.isCancelled else { cancelledReads += 1; throw CancellationError() }
        let start: Int
        switch request.origin {
        case .ordinal(let ordinal): start = min(max(0, ordinal), descriptors.count)
        case .tail: start = max(0, descriptors.count - request.maximumRows)
        }
        let key = "\(start):\(request.maximumBytes):\(request.maximumRows):\(generation):\(epoch)"
        if let cached = pageCache[key] {
            pageCacheHits += 1
            touchCache(key)
            return cached
        }
        pageReads += 1
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(min(request.maximumRows, Self.defaultPageRows))
        var bytes = 0
        var ordinal = start
        while ordinal < descriptors.count && rows.count < request.maximumRows {
            try Task.checkCancellation()
            let descriptor = descriptors[ordinal]
            let message: WireMessageRecord
            if replayRecordID == descriptor.messageID, let replayRecord {
                message = replayRecord
            } else {
                message = try readRecord(messageID: descriptor.messageID)
                replayRecordID = descriptor.messageID
                replayRecord = message
                replayRecordBytes = Array(message.text.utf8)
                byteMaterializations += 1
            }
            let text = slice(descriptor.slice, from: replayRecordBytes)
            let cost = text.utf8.count + 64
            guard cost <= request.maximumBytes else {
                if rows.isEmpty { ordinal += 1 }
                break
            }
            guard bytes <= request.maximumBytes - cost else { break }
            rows.append(TranscriptRow(descriptor: descriptor, message: message, text: text))
            bytes += cost
            ordinal += 1
        }
        let page = TranscriptPage(payload: TranscriptPagePayload(rows: rows, byteCount: bytes), startOrdinal: start, nextOrdinal: ordinal, hasMore: ordinal < descriptors.count, summary: makeSummary())
        await cache(page, key: key, epoch: epoch)
        return page
    }

    public func readPage(_ request: TranscriptPageRequest) async throws -> TranscriptPage {
        try await page(request)
    }

    public func modelSwitches() throws -> [TranscriptModelSwitchMarker] {
        try ensureLoaded()
        return modelSwitchIndex
    }

    public func turnPage(_ request: TranscriptTurnPageRequest) async throws -> TranscriptTurnPage {
        try ensureLoaded()
        try checkRoute(generation: request.expectedGeneration, epoch: request.expectedEpoch)
        guard !Task.isCancelled else { throw CancellationError() }
        let start = min(max(0, request.startOrdinal), turnIndex.count)
        let end = min(turnIndex.count, start + request.maximumRows)
        var projected: [TranscriptTurn] = []
        projected.reserveCapacity(end - start)
        var bytes = 0
        for index in start..<end {
            try Task.checkCancellation()
            let span = turnIndex[index]
            let records = try (span.firstWireOrdinal...span.lastWireOrdinal).map {
                try readRecord(messageID: order[$0])
            }
            let model = modelSwitchIndex.last {
                $0.ordinal < span.firstWireOrdinal
            }?.model
            let turn = TranscriptTurnProjector.project(
                records: records,
                sessionModel: request.sessionModel,
                hasModelMarkers: !modelSwitchIndex.isEmpty,
                initialModel: model
            ).first
            guard let turn else { continue }
            let answerBytes = turn.answer.utf8.count
            let reasoningBytes = turn.reasoning?.text.utf8.count ?? 0
            let toolBytes = turn.tools.reduce(into: 0) { total, tool in
                total += tool.input?.utf8.count ?? 0
                total += tool.output?.utf8.count ?? 0
                total += 64
            }
            let cost = answerBytes + reasoningBytes + toolBytes
            if !projected.isEmpty && bytes + cost > request.maximumBytes { break }
            projected.append(turn)
            bytes += cost
        }
        let next = start + projected.count
        return TranscriptTurnPage(
            turns: projected,
            startOrdinal: start,
            nextOrdinal: next,
            totalTurnCount: turnIndex.count,
            hasMore: next < turnIndex.count,
            modelSwitches: modelSwitchIndex
        )
    }

    public func append(_ record: WireMessageRecord, expectedGeneration: UInt64? = nil, expectedEpoch: UInt64? = nil) async throws -> TranscriptMutationResult {
        try await apply(.append(record), expectedGeneration: expectedGeneration, expectedEpoch: expectedEpoch)
    }

    /// Persists one independently ordered authoritative source as a batch.
    ///
    /// Numeric durable event IDs are stably merged with the persisted source
    /// order. Records with nonnumeric IDs retain the exact source order.
    public func append(
        _ records: [WireMessageRecord],
        expectedGeneration: UInt64? = nil,
        expectedEpoch: UInt64? = nil
    ) async throws -> TranscriptBatchMutationResult {
        try ensureLoaded()
        do { try checkRoute(generation: expectedGeneration, epoch: expectedEpoch) }
        catch let error as TranscriptStoreError {
            staleWrites += 1
            throw error
        }
        guard !Task.isCancelled else { throw CancellationError() }
        guard !records.isEmpty else {
            return TranscriptBatchMutationResult(
                appliedRecords: [],
                generation: generation,
                epoch: epoch,
                summary: makeSummary()
            )
        }

        var stagedEntries = entries
        var appliedRecords: [WireMessageRecord] = []
        appliedRecords.reserveCapacity(records.count)
        var recordsForRebuild: [String: WireMessageRecord] = [:]
        recordsForRebuild.reserveCapacity(records.count)
        let existingOrderIDs = Set(order)
        var sourceOrderIDs: [String] = []
        sourceOrderIDs.reserveCapacity(records.count)
        var sourceOrderIDSet = Set<String>()
        sourceOrderIDSet.reserveCapacity(records.count)
        var recordRollbacks: [String: FileRollback] = [:]
        recordRollbacks.reserveCapacity(records.count)
        var rollbackOrder: [String] = []
        rollbackOrder.reserveCapacity(records.count)
        var indexPersistenceRollbacks: [FileRollback] = []
        var beganIndexPersistence = false

        do {
            for record in records {
                try Task.checkCancellation()
                if let old = stagedEntries[record.messageID] {
                    guard record.revision >= old.revision else { continue }
                    if record.revision == old.revision {
                        let stored: WireMessageRecord
                        if let knownRecord = recordsForRebuild[record.messageID] {
                            stored = knownRecord
                        } else {
                            stored = try readRecord(messageID: record.messageID)
                        }
                        if record == stored {
                            recordsForRebuild[record.messageID] = stored
                            if !existingOrderIDs.contains(record.messageID),
                               sourceOrderIDSet.insert(record.messageID).inserted {
                                sourceOrderIDs.append(record.messageID)
                            }
                            continue
                        }
                    }
                    try stageRecordRollback(
                        messageID: record.messageID,
                        rollbacks: &recordRollbacks,
                        rollbackOrder: &rollbackOrder
                    )
                    try persistRecord(record)
                    try Task.checkCancellation()
                    stagedEntries[record.messageID] = TranscriptDiskIndex.Entry(
                        messageID: record.messageID,
                        recordOffset: old.recordOffset,
                        recordLength: old.recordLength,
                        firstOrdinal: old.firstOrdinal,
                        rowCount: old.rowCount,
                        revision: record.revision
                    )
                } else {
                    try stageRecordRollback(
                        messageID: record.messageID,
                        rollbacks: &recordRollbacks,
                        rollbackOrder: &rollbackOrder
                    )
                    try persistRecord(record)
                    try Task.checkCancellation()
                    stagedEntries[record.messageID] = TranscriptDiskIndex.Entry(
                        messageID: record.messageID,
                        recordOffset: 0,
                        recordLength: 0,
                        firstOrdinal: 0,
                        rowCount: 0,
                        revision: record.revision
                    )
                }
                appliedRecords.append(record)
                recordsForRebuild[record.messageID] = record
                if !existingOrderIDs.contains(record.messageID),
                   sourceOrderIDSet.insert(record.messageID).inserted {
                    sourceOrderIDs.append(record.messageID)
                }
            }

            let repairsIndex = requiresIndexRepair(
                recordsByMessageID: recordsForRebuild,
                orderIDs: existingOrderIDs
            )
            guard !appliedRecords.isEmpty || repairsIndex else {
                return TranscriptBatchMutationResult(
                    appliedRecords: [],
                    generation: generation,
                    epoch: epoch,
                    summary: makeSummary()
                )
            }

            var stagedBaseOrder: [String] = []
            stagedBaseOrder.reserveCapacity(order.count)
            var stagedOrderIDs = Set<String>()
            stagedOrderIDs.reserveCapacity(stagedEntries.count)
            for messageID in order {
                guard stagedEntries[messageID] != nil,
                      stagedOrderIDs.insert(messageID).inserted
                else { continue }
                stagedBaseOrder.append(messageID)
            }

            var pendingOrderIDs: [String] = []
            pendingOrderIDs.reserveCapacity(max(0, stagedEntries.count - stagedBaseOrder.count))
            for messageID in sourceOrderIDs {
                guard stagedEntries[messageID] != nil,
                      stagedOrderIDs.insert(messageID).inserted
                else { continue }
                pendingOrderIDs.append(messageID)
            }
            let remainingOrderIDs = stagedEntries.values
                .filter { !stagedOrderIDs.contains($0.messageID) }
                .sorted {
                    $0.firstOrdinal == $1.firstOrdinal
                        ? $0.messageID < $1.messageID
                        : $0.firstOrdinal < $1.firstOrdinal
                }
                .map(\.messageID)
            pendingOrderIDs.append(contentsOf: remainingOrderIDs)

            let stagedOrder: [String]
            if let merged = TranscriptWireOrder.merged(existing: stagedBaseOrder, incoming: pendingOrderIDs) {
                stagedOrder = merged
            } else {
                stagedOrder = stagedBaseOrder + pendingOrderIDs
            }
            let rebuilt = try buildRebuiltIndex(
                order: stagedOrder,
                entries: stagedEntries,
                recordsByMessageID: recordsForRebuild
            )
            try Task.checkCancellation()
            let committedEpoch = epoch &+ 1
            let indexRollback = try captureFileRollback(
                at: directory.appendingPathComponent("index.json")
            )
            let manifestRollback = try captureFileRollback(
                at: directory.appendingPathComponent("manifest.json")
            )
            indexPersistenceRollbacks = [indexRollback, manifestRollback]
            beganIndexPersistence = true
            try persistIndex(
                entries: rebuilt.entries,
                descriptors: rebuilt.descriptors,
                modelSwitches: rebuilt.modelSwitches,
                order: stagedOrder,
                turns: rebuilt.turns,
                generation: generation,
                epoch: committedEpoch
            )

            entries = rebuilt.entries
            order = stagedOrder
            descriptors = rebuilt.descriptors
            turnIndex = rebuilt.turns
            turnOrdinalByMessageID = rebuilt.turnLookup
            modelSwitchIndex = rebuilt.modelSwitches
            epoch = committedEpoch
            invalidatePageCache()
            return TranscriptBatchMutationResult(
                appliedRecords: appliedRecords,
                generation: generation,
                epoch: epoch,
                summary: makeSummary()
            )
        } catch let batchError {
            var cleanupError: Error?
            do {
                try rollbackRecords(rollbackOrder, rollbacks: recordRollbacks)
            } catch {
                cleanupError = error
            }
            if beganIndexPersistence {
                do {
                    try rollbackFiles(indexPersistenceRollbacks)
                } catch {
                    if cleanupError == nil { cleanupError = error }
                }
            }
            if let cleanupError { throw cleanupError }
            throw batchError
        }
    }

    public func replace(_ record: WireMessageRecord, expectedGeneration: UInt64? = nil, expectedEpoch: UInt64? = nil) async throws -> TranscriptMutationResult {
        try await apply(.replace(record), expectedGeneration: expectedGeneration, expectedEpoch: expectedEpoch)
    }

    public func apply(_ mutation: TranscriptMutation, expectedGeneration: UInt64? = nil, expectedEpoch: UInt64? = nil) async throws -> TranscriptMutationResult {
        try ensureLoaded()
        do { try checkRoute(generation: expectedGeneration, epoch: expectedEpoch) }
        catch let error as TranscriptStoreError {
            staleWrites += 1
            throw error
        }
        guard !Task.isCancelled else { throw CancellationError() }
        switch mutation {
        case .append(let record):
            if let old = entries[record.messageID] {
                guard record.revision >= old.revision else { return result(applied: false) }
                if record.revision == old.revision {
                    let stored = try readRecord(messageID: record.messageID)
                    if stored == record {
                        return result(applied: false)
                    }
                }
                try persistRecord(record)
                entries[record.messageID] = try makeEntry(record: record, firstOrdinal: old.firstOrdinal)
                try rebuildDescriptors()
            } else {
                try persistRecord(record)
                order.append(record.messageID)
                try rebuildDescriptors()
            }
        case .replace(let record):
            guard entries[record.messageID] != nil else { throw TranscriptStoreError.invalidMutation }
            try persistRecord(record)
            let oldOrdinal = entries[record.messageID]!.firstOrdinal
            entries[record.messageID] = try makeEntry(record: record, firstOrdinal: oldOrdinal)
            try rebuildDescriptors()
        case .replaceText(let messageID, let text, let revision):
            guard let old = entries[messageID] else { throw TranscriptStoreError.invalidMutation }
            let previous = try readRecord(messageID: messageID)
            guard revision >= old.revision else { return result(applied: false) }
            _ = try await apply(
                .replace(WireMessageRecord(
                    messageID: messageID,
                    role: previous.role,
                    text: text,
                    reasoning: previous.reasoning,
                    timestamp: previous.timestamp,
                    revision: revision,
                    displayKind: previous.displayKind,
                    displayMetadata: previous.displayMetadata,
                    toolCallID: previous.toolCallID,
                    toolName: previous.toolName,
                    toolInput: previous.toolInput,
                    toolOutput: previous.toolOutput,
                    toolStatus: previous.toolStatus,
                    turnID: previous.turnID
                )),
                expectedGeneration: generation,
                expectedEpoch: epoch
            )
        case .remove(let messageID):
            guard entries.removeValue(forKey: messageID) != nil else { return result(applied: false) }
            order.removeAll { $0 == messageID }
            try? fileSystem.remove(recordURL(messageID: messageID))
            try rebuildDescriptors()
        case .removeMany(let messageIDs):
            var removed = false
            for messageID in messageIDs {
                if entries.removeValue(forKey: messageID) != nil {
                    try? fileSystem.remove(recordURL(messageID: messageID))
                    removed = true
                }
            }
            guard removed else { return result(applied: false) }
            order.removeAll { entries[$0] == nil }
            try rebuildDescriptors()
        case .clear:
            for id in order { try? fileSystem.remove(recordURL(messageID: id)) }
            entries.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
            descriptors.removeAll(keepingCapacity: true)
            turnIndex.removeAll(keepingCapacity: true)
            turnOrdinalByMessageID.removeAll(keepingCapacity: true)
            modelSwitchIndex.removeAll(keepingCapacity: true)
        }
        try finishMutation()
        return result(applied: true)
    }

    public func find(_ query: FindQuery, startOrdinal: Int = 0) throws -> TranscriptFindCursor {
        try ensureLoaded()
        return TranscriptFindCursor(store: self, query: query, startOrdinal: startOrdinal)
    }

    internal func findPage(query: FindQuery, startOrdinal: Int, maximumResults: Int) throws -> (matches: [TranscriptFindMatch], nextOrdinal: Int) {
        try ensureLoaded()
        guard !Task.isCancelled else { throw CancellationError() }
        var matches: [TranscriptFindMatch] = []
        var ordinal = min(max(0, startOrdinal), descriptors.count)
        while ordinal < descriptors.count && matches.count < maximumResults {
            try Task.checkCancellation()
            let descriptor = descriptors[ordinal]
            let message = try readRecord(messageID: descriptor.messageID)
            let text = slice(descriptor.slice, from: message.text)
            if message.isSearchable,
               (query.role == nil || query.role == message.role),
               let range = text.range(of: query.text, options: query.caseSensitive ? [] : [.caseInsensitive]) {
                let offset = text[..<range.lowerBound].utf8.count
                let length = text[range].utf8.count
                matches.append(TranscriptFindMatch(descriptor: descriptor, ranges: [StringSlice(offset: offset, length: length)]))
            }
            ordinal += 1
        }
        return (matches, ordinal)
    }

    public func metrics() async -> TranscriptStoreMetrics {
        TranscriptStoreMetrics(pageReads: pageReads, pageCacheHits: pageCacheHits, pageCacheEvictions: pageCacheEvictions, staleWrites: staleWrites, cancelledReads: cancelledReads, diskReads: diskReads, diskWrites: diskWrites, byteMaterializations: byteMaterializations, memory: await memoryBudget.metrics())
    }

    private func ensureLoaded() throws { if !loaded { try load() } }
    private func makeSummary() -> TranscriptSummary {
        TranscriptSummary(rowCount: reportedRowCount ?? descriptors.count, messageCount: order.count, countKind: summaryCountKind, generation: generation, epoch: epoch)
    }
    private func result(applied: Bool) -> TranscriptMutationResult { TranscriptMutationResult(applied: applied, generation: generation, epoch: epoch, summary: makeSummary()) }

    private func finishMutation() throws {
        epoch &+= 1
        invalidatePageCache()
        try persistIndex()
    }

    private func invalidatePageCache() {
        pageCache.removeAll(keepingCapacity: true)
        replayRecordID = nil
        replayRecord = nil
        replayRecordBytes.removeAll(keepingCapacity: true)
        pageOrder.removeAll(keepingCapacity: true)
        for admission in pageAdmissions.values { Task { await memoryBudget.release(admission) } }
        pageAdmissions.removeAll(keepingCapacity: true)
    }

    private func checkRoute(generation expectedGeneration: UInt64?, epoch expectedEpoch: UInt64?) throws {
        if let expectedGeneration, expectedGeneration != generation { throw TranscriptStoreError.staleGeneration(expected: expectedGeneration, actual: generation) }
        if let expectedEpoch, expectedEpoch != epoch { throw TranscriptStoreError.staleEpoch(expected: expectedEpoch, actual: epoch) }
    }

    private func recordURL(messageID: String) -> URL {
        let encoded = Data(messageID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return directory.appendingPathComponent("record-\(encoded).json")
    }

    private struct FileRollback {
        let url: URL
        let originalBytes: Data?
    }

    private func captureFileRollback(at url: URL) throws -> FileRollback {
        guard fileSystem.exists(url) else {
            return FileRollback(url: url, originalBytes: nil)
        }
        let originalBytes = try fileSystem.data(at: url)
        return FileRollback(url: url, originalBytes: originalBytes)
    }

    private func stageRecordRollback(
        messageID: String,
        rollbacks: inout [String: FileRollback],
        rollbackOrder: inout [String]
    ) throws {
        guard rollbacks[messageID] == nil else { return }
        let rollback: FileRollback
        if entries[messageID] == nil {
            rollback = FileRollback(
                url: recordURL(messageID: messageID),
                originalBytes: nil
            )
        } else {
            rollback = try captureFileRollback(
                at: recordURL(messageID: messageID)
            )
        }
        rollbacks[messageID] = rollback
        rollbackOrder.append(messageID)
    }

    private func rollbackRecords(
        _ rollbackOrder: [String],
        rollbacks: [String: FileRollback]
    ) throws {
        try rollbackFiles(rollbackOrder.compactMap { rollbacks[$0] })
    }

    private func rollbackFiles(_ rollbacks: [FileRollback]) throws {
        var firstError: Error?
        for rollback in rollbacks {
            do {
                try restoreFile(rollback)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private func restoreFile(_ rollback: FileRollback) throws {
        let temp = rollback.url.appendingPathExtension("tmp")
        if let originalBytes = rollback.originalBytes {
            do {
                try fileSystem.write(originalBytes, to: temp)
                try fileSystem.move(temp, to: rollback.url)
                diskWrites += 1
            } catch {
                try? fileSystem.remove(temp)
                throw error
            }
        } else {
            if fileSystem.exists(rollback.url) {
                try fileSystem.remove(rollback.url)
            }
            if fileSystem.exists(temp) {
                try fileSystem.remove(temp)
            }
        }
    }

    private func persistRecord(_ record: WireMessageRecord) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(record)
        var framed = Data()
        var length = UInt64(encoded.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(encoded)
        let destination = recordURL(messageID: record.messageID)
        let temp = destination.appendingPathExtension("tmp")
        try fileSystem.write(framed, to: temp)
        try fileSystem.move(temp, to: destination)
        diskWrites += 1
    }

    private func readRecord(messageID: String) throws -> WireMessageRecord {
        let data: Data
        do { data = try fileSystem.data(at: recordURL(messageID: messageID)); diskReads += 1 }
        catch { throw TranscriptStoreError.missingRecord(messageID) }
        guard data.count >= 8 else { throw TranscriptStoreError.missingRecord(messageID) }
        let length = data.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length <= UInt64(data.count - 8), data.count == 8 + Int(length) else { throw TranscriptStoreError.missingRecord(messageID) }
        let payload = data.subdata(in: 8..<(8 + Int(length)))
        guard let record = try? JSONDecoder().decode(WireMessageRecord.self, from: payload) else { throw TranscriptStoreError.missingRecord(messageID) }
        return record
    }

    private func makeEntry(record: WireMessageRecord, firstOrdinal: Int) throws -> TranscriptDiskIndex.Entry {
        let chunks = record.isRenderable ? chunkText(record.text) : []
        return TranscriptDiskIndex.Entry(messageID: record.messageID, recordOffset: 0, recordLength: UInt64(record.text.utf8.count), firstOrdinal: firstOrdinal, rowCount: chunks.count, revision: record.revision)
    }

    private struct RebuiltIndex {
        let entries: [String: TranscriptDiskIndex.Entry]
        let descriptors: [TranscriptRowDescriptor]
        let modelSwitches: [TranscriptModelSwitchMarker]
        let turns: [TranscriptTurnIndexEntry]
        let turnLookup: [String: Int]
    }

    private func rebuildDescriptors(
        recordsByMessageID: [String: WireMessageRecord] = [:]
    ) throws {
        let rebuilt = try buildRebuiltIndex(
            order: order,
            entries: entries,
            recordsByMessageID: recordsByMessageID
        )
        entries = rebuilt.entries
        descriptors = rebuilt.descriptors
        modelSwitchIndex = rebuilt.modelSwitches
        turnIndex = rebuilt.turns
        turnOrdinalByMessageID = rebuilt.turnLookup
    }

    private func buildRebuiltIndex(
        order: [String],
        entries: [String: TranscriptDiskIndex.Entry],
        recordsByMessageID: [String: WireMessageRecord]
    ) throws -> RebuiltIndex {
        var rebuiltEntries = entries
        var rebuiltDescriptors: [TranscriptRowDescriptor] = []
        rebuiltDescriptors.reserveCapacity(max(1, descriptors.count))
        var ordinal = 0
        var markers: [TranscriptModelSwitchMarker] = []
        var turnIndexBuilder = TranscriptTurnIndexBuilder()
        for (wireOrdinal, messageID) in order.enumerated() {
            try Task.checkCancellation()
            let record: WireMessageRecord
            if let supplied = recordsByMessageID[messageID] {
                record = supplied
            } else {
                record = try readRecord(messageID: messageID)
            }
            if record.isModelSwitch {
                markers.append(TranscriptModelSwitchMarker(
                    id: record.messageID,
                    model: record.modelSwitchName,
                    ordinal: wireOrdinal,
                    renderedOrdinal: ordinal
                ))
            }
            let chunks = record.isRenderable ? chunkText(record.text) : []
            let first = ordinal
            rebuiltEntries[messageID] = TranscriptDiskIndex.Entry(
                messageID: messageID,
                recordOffset: 0,
                recordLength: UInt64(record.text.utf8.count),
                firstOrdinal: first,
                rowCount: chunks.count,
                revision: record.revision
            )
            for (block, chunk) in chunks.enumerated() {
                rebuiltDescriptors.append(TranscriptRowDescriptor(
                    messageID: messageID,
                    blockIndex: block,
                    ordinal: ordinal,
                    slice: chunk.slice,
                    byteCount: chunk.byteCount,
                    isContinuation: block > 0
                ))
                ordinal += 1
            }
            turnIndexBuilder.append(record, at: wireOrdinal)
        }
        let rebuiltTurns = turnIndexBuilder.turns
        return RebuiltIndex(
            entries: rebuiltEntries,
            descriptors: rebuiltDescriptors,
            modelSwitches: markers,
            turns: rebuiltTurns,
            turnLookup: turnLookup(for: rebuiltTurns, order: order)
        )
    }

    private func requiresIndexRepair(
        recordsByMessageID: [String: WireMessageRecord],
        orderIDs: Set<String>
    ) -> Bool {
        guard entries.count == order.count,
              orderIDs.count == order.count
        else { return true }

        for (messageID, record) in recordsByMessageID {
            guard orderIDs.contains(messageID),
                  let entry = entries[messageID],
                  entry.firstOrdinal >= 0,
                  entry.rowCount >= 0
            else { return true }

            let expectedChunks = record.isRenderable ? chunkText(record.text) : []
            guard entry.revision == record.revision,
                  entry.recordLength == UInt64(record.text.utf8.count),
                  entry.rowCount == expectedChunks.count,
                  entry.firstOrdinal + entry.rowCount <= descriptors.count
            else { return true }

            let marker = modelSwitchIndex.first { $0.id == messageID }
            if record.isModelSwitch {
                guard let wireOrdinal = order.firstIndex(of: messageID),
                      marker == TranscriptModelSwitchMarker(
                          id: messageID,
                          model: record.modelSwitchName,
                          ordinal: wireOrdinal,
                          renderedOrdinal: entry.firstOrdinal
                      )
                else { return true }
            } else if marker != nil {
                return true
            }
            if record.isRenderable, turnOrdinalByMessageID[messageID] == nil {
                return true
            }

            for (block, expected) in expectedChunks.enumerated() {
                let descriptor = descriptors[entry.firstOrdinal + block]
                guard descriptor.messageID == messageID,
                      descriptor.blockIndex == block,
                      descriptor.ordinal == entry.firstOrdinal + block,
                      descriptor.slice == expected.slice,
                      descriptor.byteCount == expected.byteCount,
                      descriptor.isContinuation == (block > 0)
                else { return true }
            }
        }
        return false
    }

    private func rebuildTurnIndex() throws {
        var builder = TranscriptTurnIndexBuilder()
        for (wireOrdinal, messageID) in order.enumerated() {
            try Task.checkCancellation()
            builder.append(try readRecord(messageID: messageID), at: wireOrdinal)
        }
        turnIndex = builder.turns
        buildTurnLookup()
    }

    private func buildTurnLookup() {
        turnOrdinalByMessageID = turnLookup(for: turnIndex, order: order)
    }

    private func turnLookup(
        for turns: [TranscriptTurnIndexEntry],
        order: [String]
    ) -> [String: Int] {
        var lookup: [String: Int] = [:]
        for (turnOrdinal, span) in turns.enumerated() {
            guard span.firstWireOrdinal <= span.lastWireOrdinal else { continue }
            for wireOrdinal in span.firstWireOrdinal...span.lastWireOrdinal {
                guard wireOrdinal < order.count else { continue }
                lookup[order[wireOrdinal]] = turnOrdinal
            }
        }
        return lookup
    }


    private func chunkText(_ text: String) -> [(slice: StringSlice, byteCount: Int)] {
        let bytes = Array(text.utf8)
        if bytes.isEmpty { return [(StringSlice(offset: 0, length: 0), 0)] }
        var result: [(slice: StringSlice, byteCount: Int)] = []
        var offset = 0
        while offset < bytes.count {
            var end = min(bytes.count, offset + Self.defaultRowByteLimit)
            while end > offset && end < bytes.count && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
            if end == offset { end = min(bytes.count, offset + Self.defaultRowByteLimit) }
            result.append((StringSlice(offset: offset, length: end - offset), end - offset)); offset = end
        }
        return result
    }

    private func slice(_ slice: StringSlice, from bytes: [UInt8]) -> String {
        guard slice.offset < bytes.count || slice.length == 0 else { return "" }
        let end = min(bytes.count, slice.end)
        return String(decoding: bytes[slice.offset..<end], as: UTF8.self)
    }

    private func slice(_ range: StringSlice, from text: String) -> String {
        slice(range, from: Array(text.utf8))
    }

    private func persistIndex() throws {
        try persistIndex(
            entries: entries,
            descriptors: descriptors,
            modelSwitches: modelSwitchIndex,
            order: order,
            turns: turnIndex,
            generation: generation,
            epoch: epoch
        )
    }

    private func persistIndex(
        entries: [String: TranscriptDiskIndex.Entry],
        descriptors: [TranscriptRowDescriptor],
        modelSwitches: [TranscriptModelSwitchMarker],
        order: [String],
        turns: [TranscriptTurnIndexEntry],
        generation: UInt64,
        epoch: UInt64
    ) throws {
        let index = TranscriptDiskIndex(entries: entries, descriptors: descriptors, modelSwitches: modelSwitches, orderedMessageIDs: order, turns: turns)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let indexData = try encoder.encode(index)
        let manifest = TranscriptManifest(generation: generation, epoch: epoch, rowCount: reportedRowCount ?? descriptors.count, messageCount: order.count, exactCount: summaryCountKind == .exact)
        let manifestData = try encoder.encode(manifest)
        let indexTemp = directory.appendingPathComponent("index.json.tmp")
        let manifestTemp = directory.appendingPathComponent("manifest.json.tmp")
        try fileSystem.write(indexData, to: indexTemp)
        try fileSystem.write(manifestData, to: manifestTemp)
        let indexURL = directory.appendingPathComponent("index.json")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try fileSystem.move(indexTemp, to: indexURL)
        try fileSystem.move(manifestTemp, to: manifestURL)
        diskWrites += 2
    }

    private func currentRowCount() throws -> Int {
        var count = 0
        for id in order {
            let record = try readRecord(messageID: id)
            if record.isRenderable { count += chunkText(record.text).count }
        }
        return count
    }
    private func cache(_ page: TranscriptPage, key: String, epoch expectedEpoch: UInt64) async {
        let estimate = max(1, page.payload.byteCount + page.rows.count * 128)
        guard let admission = await memoryBudget.admit(category: .pagePayload, bytes: estimate) else { return }
        guard expectedEpoch == epoch else {
            await memoryBudget.release(admission)
            return
        }
        pageCache[key] = page
        pageAdmissions[key] = admission
        pageOrder.removeAll { $0 == key }
        pageOrder.append(key)
        while pageOrder.count > 8 {
            let old = pageOrder.removeFirst()
            pageCache.removeValue(forKey: old)
            if let oldAdmission = pageAdmissions.removeValue(forKey: old) {
                await memoryBudget.release(oldAdmission)
                await memoryBudget.recordEviction(oldAdmission.chargedBytes)
            }
            pageCacheEvictions += 1
        }
    }

    private func touchCache(_ key: String) {
        pageOrder.removeAll { $0 == key }
        pageOrder.append(key)
    }
}
