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

public struct TranscriptStoreMetrics: Sendable, Equatable {
    public let pageReads: Int
    public let pageCacheHits: Int
    public let pageCacheEvictions: Int
    public let staleWrites: Int
    public let cancelledReads: Int
    public let diskReads: Int
    public let diskWrites: Int
    public let memory: TranscriptMemoryMetrics

    public init(pageReads: Int = 0, pageCacheHits: Int = 0, pageCacheEvictions: Int = 0, staleWrites: Int = 0, cancelledReads: Int = 0, diskReads: Int = 0, diskWrites: Int = 0, memory: TranscriptMemoryMetrics) {
        self.pageReads = pageReads; self.pageCacheHits = pageCacheHits; self.pageCacheEvictions = pageCacheEvictions; self.staleWrites = staleWrites; self.cancelledReads = cancelledReads; self.diskReads = diskReads; self.diskWrites = diskWrites; self.memory = memory
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
        if fileSystem.exists(manifestURL) {
            let manifestData = try fileSystem.data(at: manifestURL)
            guard let manifest = try? JSONDecoder().decode(TranscriptManifest.self, from: manifestData), manifest.version == TranscriptManifest.currentVersion else { throw TranscriptStoreError.corruptManifest }
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
            order = index.orderedMessageIDs ?? entries.values.sorted { $0.firstOrdinal < $1.firstOrdinal }.map(\.messageID)
            modelSwitchIndex = index.modelSwitches ?? []
            turnIndex = index.turns ?? []
            if index.modelSwitches == nil || index.turns == nil {
                try rebuildDescriptors()
            } else {
                buildTurnLookup()
            }
            if let count = try? currentRowCount(), descriptors.count != count { throw TranscriptStoreError.corruptIndex }
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
            let message = try readRecord(messageID: descriptor.messageID)
            let text = slice(descriptor.slice, from: message.text)
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
        case .clear:
            for id in order { try? fileSystem.remove(recordURL(messageID: id)) }
            entries.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
            descriptors.removeAll(keepingCapacity: true)
            turnIndex.removeAll(keepingCapacity: true)
            turnOrdinalByMessageID.removeAll(keepingCapacity: true)
            modelSwitchIndex.removeAll(keepingCapacity: true)
        }
        epoch &+= 1
        pageCache.removeAll(keepingCapacity: true)
        pageOrder.removeAll(keepingCapacity: true)
        for admission in pageAdmissions.values { Task { await memoryBudget.release(admission) } }
        pageAdmissions.removeAll(keepingCapacity: true)
        try persistIndex()
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
        TranscriptStoreMetrics(pageReads: pageReads, pageCacheHits: pageCacheHits, pageCacheEvictions: pageCacheEvictions, staleWrites: staleWrites, cancelledReads: cancelledReads, diskReads: diskReads, diskWrites: diskWrites, memory: await memoryBudget.metrics())
    }

    private func ensureLoaded() throws { if !loaded { try load() } }
    private func makeSummary() -> TranscriptSummary {
        TranscriptSummary(rowCount: reportedRowCount ?? descriptors.count, messageCount: order.count, countKind: summaryCountKind, generation: generation, epoch: epoch)
    }
    private func result(applied: Bool) -> TranscriptMutationResult { TranscriptMutationResult(applied: applied, generation: generation, epoch: epoch, summary: makeSummary()) }

    private func checkRoute(generation expectedGeneration: UInt64?, epoch expectedEpoch: UInt64?) throws {
        if let expectedGeneration, expectedGeneration != generation { throw TranscriptStoreError.staleGeneration(expected: expectedGeneration, actual: generation) }
        if let expectedEpoch, expectedEpoch != epoch { throw TranscriptStoreError.staleEpoch(expected: expectedEpoch, actual: epoch) }
    }

    private func recordURL(messageID: String) -> URL {
        let encoded = Data(messageID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return directory.appendingPathComponent("record-\(encoded).json")
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

    private func rebuildDescriptors() throws {
        var rebuilt: [TranscriptRowDescriptor] = []
        rebuilt.reserveCapacity(max(1, descriptors.count))
        var ordinal = 0
        var markers: [TranscriptModelSwitchMarker] = []
        var turns: [TranscriptTurnIndexEntry] = []
        var currentTurn = -1
        for (wireOrdinal, messageID) in order.enumerated() {
            try Task.checkCancellation()
            let record = try readRecord(messageID: messageID)
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
            entries[messageID] = TranscriptDiskIndex.Entry(
                messageID: messageID,
                recordOffset: 0,
                recordLength: UInt64(record.text.utf8.count),
                firstOrdinal: first,
                rowCount: chunks.count,
                revision: record.revision
            )
            for (block, chunk) in chunks.enumerated() {
                rebuilt.append(TranscriptRowDescriptor(
                    messageID: messageID,
                    blockIndex: block,
                    ordinal: ordinal,
                    slice: chunk.slice,
                    byteCount: chunk.byteCount,
                    isContinuation: block > 0
                ))
                ordinal += 1
            }

            guard !record.isModelSwitch else { continue }
            let speaker: TranscriptSpeaker
            switch record.role.lowercased() {
            case "user", "me": speaker = .me
            case "assistant", "hermes", "agent", "tool": speaker = .hermes
            default: speaker = .system
            }
            if record.isToolEvent {
                if currentTurn < 0 || turns[currentTurn].speaker != .hermes {
                    turns.append(TranscriptTurnIndexEntry(
                        id: record.turnID ?? record.messageID,
                        firstWireOrdinal: wireOrdinal,
                        lastWireOrdinal: wireOrdinal,
                        speaker: .hermes
                    ))
                    currentTurn = turns.count - 1
                } else {
                    turns[currentTurn].lastWireOrdinal = wireOrdinal
                }
            } else {
                let stableID = record.turnID ?? record.messageID
                let startsNew = currentTurn < 0
                    || turns[currentTurn].speaker != speaker
                    || turns[currentTurn].id != stableID
                    || record.turnID == nil
                if startsNew {
                    turns.append(TranscriptTurnIndexEntry(
                        id: stableID,
                        firstWireOrdinal: wireOrdinal,
                        lastWireOrdinal: wireOrdinal,
                        speaker: speaker
                    ))
                    currentTurn = turns.count - 1
                } else {
                    turns[currentTurn].lastWireOrdinal = wireOrdinal
                }
            }
        }
        modelSwitchIndex = markers
        turnIndex = turns
        descriptors = rebuilt
        buildTurnLookup()
    }
    private func buildTurnLookup() {
        turnOrdinalByMessageID.removeAll(keepingCapacity: true)
        for (turnOrdinal, span) in turnIndex.enumerated() {
            guard span.firstWireOrdinal <= span.lastWireOrdinal else { continue }
            for wireOrdinal in span.firstWireOrdinal...span.lastWireOrdinal {
                guard wireOrdinal < order.count else { continue }
                turnOrdinalByMessageID[order[wireOrdinal]] = turnOrdinal
            }
        }
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

    private func slice(_ slice: StringSlice, from text: String) -> String {
        let bytes = Array(text.utf8)
        guard slice.offset < bytes.count || slice.length == 0 else { return "" }
        let end = min(bytes.count, slice.end)
        return String(decoding: bytes[slice.offset..<end], as: UTF8.self)
    }

    private func persistIndex() throws {
        let index = TranscriptDiskIndex(entries: entries, descriptors: descriptors, modelSwitches: modelSwitchIndex, orderedMessageIDs: order, turns: turnIndex)
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
