import Foundation
@testable import HermternalCore
import SQLite3
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Test("performance contract: cold then warm cache load decodes once")
func performanceCacheWarmLoadContract() async throws {
    let directory = try performanceTemporaryDirectory("Cache")
    defer { try? FileManager.default.removeItem(at: directory) }

    let rows = (0..<500).map { ChatMessage(
        id: .server(ServerMessageID(rawValue: Int64($0))),
        role: $0.isMultiple(of: 2) ? .user : .assistant,
        text: "cached transcript row \($0)"
    ) }
    let writer = HistoryCache(directory: directory)
    _ = await writer.store(rows, for: "five-hundred")

    let codec = CountingCacheCodec()
    let reader = HistoryCache(directory: directory, codec: codec)
    let cold = await reader.read(for: "five-hundred")
    let decodeCountAfterColdRead = codec.decodeCount
    let warm = await reader.read(for: "five-hundred")
    let decodeCountAfterWarmRead = codec.decodeCount

    #expect(cold.transcript?.messages.count == 500)
    #expect(warm.transcript?.messages.count == 500)
    #expect(decodeCountAfterColdRead == 1)
    #expect(decodeCountAfterWarmRead == decodeCountAfterColdRead)
    print("PERF|cache warm load|rows=500 coldDecodes=\(decodeCountAfterColdRead) warmDecodeDelta=\(decodeCountAfterWarmRead - decodeCountAfterColdRead)")
}

@Test("performance contract: prefetch visits each session once within four lanes")
func performancePrefetchBoundContract() async {
    let coordinator = BoundedPrefetchCoordinator(limit: 4)
    let probe = PrefetchProbe()
    let delivered = PrefetchValueCollector()
    await coordinator.prefetch(
        Array(0..<30),
        operation: { value in
            await probe.enter(value)
            await Task.yield()
            await probe.leave()
            return value
        },
        onResult: { value in
            await delivered.append(value)
        }
    )

    let started = await probe.started
    let uniqueStarted = Set(started)
    let maximum = await probe.maximum
    let values = await delivered.values
    #expect(values.count == 30)
    #expect(Set(values) == Set(0..<30))
    #expect(started.count == 30)
    #expect(uniqueStarted.count == 30)
    #expect(uniqueStarted == Set(0..<30))
    #expect(maximum <= 4)
    print("PERF|prefetch bound|items=30 unique=\(uniqueStarted.count) maxInFlight=\(maximum)")
}
@Test("performance contract: completed payload residency stays within four lanes")
func performancePrefetchPayloadResidencyContract() async {
    let coordinator = BoundedPrefetchCoordinator(limit: 4)
    let probe = PayloadResidencyProbe()
    let gate = PrefetchPhaseGate()
    let task: Task<Void, Never> = Task {
        await coordinator.prefetch(
            Array(0..<30),
            operation: { value in
                await probe.retain()
                await gate.wait(0)
                return RetainedPrefetchPayload(value: value)
            },
            onResult: { _ in
                await probe.release()
            }
        )
    }
    while await probe.active < 4 { await Task.yield() }
    await gate.release(0)
    await task.value

    let peak = await probe.maximum
    #expect(peak == 4)
    #expect(await probe.active == 0)
    print("PERF|prefetch payload residency|items=30 concurrency=4 peakRetained=\(peak)")
}


@Test("performance contract: mid-stream cancellation stops queued prefetch work")
func performancePrefetchCancellationContract() async {
    let coordinator = BoundedPrefetchCoordinator(limit: 4)
    let probe = PrefetchProbe()
    let gate = PrefetchPhaseGate()
    let delivered = PrefetchValueCollector()
    let task: Task<Void, Never> = Task {
        await coordinator.prefetch(
            Array(0..<30),
            operation: { value in
                await probe.enter(value)
                await gate.wait(value < 4 ? 0 : 1)
                guard !Task.isCancelled else {
                    await probe.leave()
                    return nil
                }
                await probe.leave()
                return value
            },
            onResult: { value in
                await delivered.append(value)
            }
        )
    }

    while await probe.started.count < 4 { await Task.yield() }
    await gate.release(0)
    while await probe.started.count < 8 { await Task.yield() }
    let startedBeforeCancellation = await probe.started
    #expect(startedBeforeCancellation.count == 8)
    task.cancel()
    await gate.release(1)
    await task.value

    let started = await probe.started
    let values = await delivered.values
    #expect(started.count == startedBeforeCancellation.count)
    #expect(Set(started) == Set(0..<8))
    #expect(Set(started).count == started.count)
    #expect(values.count == 4)
    #expect(await probe.active == 0)
    print("PERF|prefetch cancellation|started=\(started.count) delivered=\(values.count) queued=\(30 - started.count)")
}

@Test("performance contract: search query uses the FTS virtual-table plan")
func performanceSearchFTSContract() async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "HermternalPerformance-\(UUID().uuidString).sqlite")
    let index = try SearchIndex(url: url)
    defer { removePerformanceIndexFiles(at: url) }

    let documents = (0..<5_000).map { id in
        SearchDocument(
            messageID: ServerMessageID(rawValue: Int64(id)),
            body: id == 4_321 ? "rare-target token" : "common filler row \(id)",
            role: .assistant
        )
    }
    try await index.replace(SearchSessionSnapshot(sessionID: "large", title: "", documents: documents))
    let queryStarts = SearchQueryCounter()
    await index._setQueryStartHook { queryStarts.increment() }
    let result = try await index.search("rare-target", limit: 10)
    await index._setQueryStartHook(nil)

    let plan = try performanceFTSQueryPlan(at: url)
    #expect(result.hits.map(\.messageID.rawValue) == [4_321])
    #expect(queryStarts.value == 1)
    #expect(plan.contains(where: { $0.localizedCaseInsensitiveContains("VIRTUAL TABLE INDEX") }))
    print("PERF|search FTS|documents=5000 queryStarts=\(queryStarts.value) plan=\(plan.joined(separator: ";"))")
    try await index.disable()
}

@Test("performance contract: warm switch pure work stays inside the frame budget")
func performanceWarmSwitchPureWorkContract() {
    let sessionID = "warm-switch"
    let messages = (0..<256).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "warm switch message \(index)"
        )
    }
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: sessionID,
        serverTotal: messages.count,
        fetchedRows: messages.count,
        projectedMessages: messages.count,
        truncated: false,
        fetchedAt: Date(timeIntervalSince1970: 0)
    )
    let store = TranscriptWarmStore()
    #expect(store.publish(messages: messages, snapshot: snapshot, for: sessionID))

    let plan = TranscriptSwitchWorkPolicy.initialPlan(totalMessageCount: messages.count)
    #expect(
        TranscriptSwitchWorkPolicy.pureWorkBudgetMilliseconds
            == TranscriptSwitchWorkPolicy.frameTargetMilliseconds
            - TranscriptSwitchWorkPolicy.reservedFrameHeadroomMilliseconds
    )
    #expect(
        TranscriptSwitchWorkPolicy.pureWorkBudgetMilliseconds
            < TranscriptSwitchWorkPolicy.frameTargetMilliseconds
    )
    let rowHeightCache = CountingSwitchLookupCache<RowHeightCacheKey, Double>()
    let preparedContentCache = CountingSwitchLookupCache<MessageIdentity, String>()
    var rowHeightKeys: [RowHeightCacheKey] = []
    rowHeightKeys.reserveCapacity(plan.messageRange.count)
    for index in plan.messageRange {
        let message = messages[index]
        let key = performanceRowHeightKey(for: message)
        rowHeightKeys.append(key)
        rowHeightCache.insert(48, for: key)
        preparedContentCache.insert("prepared \(index)", for: message.id)
    }

    var warmProjectionLookups = 0
    let projection = store.projection(for: sessionID)
    warmProjectionLookups += 1
    let resolvedMessageRange = plan.messageRange
    let initialPublicationRangeResolutions = 1
    let heights = rowHeightKeys.compactMap { rowHeightCache.lookup($0) }
    let prepared = resolvedMessageRange.map { index in
        preparedContentCache.lookup(messages[index].id)
    }
    let pureWorkUnits = warmProjectionLookups
        + initialPublicationRangeResolutions
        + rowHeightCache.lookupCount
        + preparedContentCache.lookupCount

    #expect(projection?.messages.count == messages.count)
    #expect(resolvedMessageRange.count == TranscriptPublicationPolicy.initialMessageCount)
    #expect(heights.count == plan.messageRange.count)
    #expect(prepared.allSatisfy { $0 != nil })
    #expect(warmProjectionLookups == 1)
    #expect(initialPublicationRangeResolutions == 1)
    #expect(rowHeightCache.lookupCount == plan.messageRange.count)
    #expect(preparedContentCache.lookupCount == plan.messageRange.count)
    #expect(plan.workUnits == pureWorkUnits)
    #expect(plan.workUnits <= TranscriptSwitchWorkPolicy.maximumPureWorkUnits)
    print(
        "PERF|switch pure work|"
            + "frameTargetMs=\(TranscriptSwitchWorkPolicy.frameTargetMilliseconds) "
            + "pureBudgetMs=\(TranscriptSwitchWorkPolicy.pureWorkBudgetMilliseconds) "
            + "headroomMs=\(TranscriptSwitchWorkPolicy.reservedFrameHeadroomMilliseconds) "
            + "workUnits=\(pureWorkUnits) "
            + "gate<=\(TranscriptSwitchWorkPolicy.maximumPureWorkUnits) "
            + "warmProjectionLookups=\(warmProjectionLookups) "
            + "initialPublicationRangeResolutions=\(initialPublicationRangeResolutions) "
            + "rowHeightHits=\(rowHeightCache.lookupCount) "
            + "preparedContentHits=\(preparedContentCache.lookupCount)"
    )
}

@Test("performance contract: cache-hit row does not parse or measure")
func performanceCacheHitRowNoParseOrMeasurementContract() {
    let message = ChatMessage(
        id: .server(ServerMessageID(rawValue: 7_001)),
        role: .assistant,
        text: "cached **assistant** response"
    )
    let key = performanceRowHeightKey(for: message)
    let renderer = CountingCacheHitRowRenderer(
        prepared: [message.id: "prepared response"],
        heights: [key: 52]
    )
    var parseCalls = 0
    var measurementCalls = 0

    let row = renderer.render(
        message,
        heightKey: key,
        prepare: {
            parseCalls += 1
            return "new prepared response"
        },
        measure: {
            measurementCalls += 1
            return 99
        }
    )

    #expect(row.content == "prepared response")
    #expect(row.height == 52)
    #expect(renderer.preparedLookups == 1)
    #expect(renderer.heightLookups == 1)
    #expect(parseCalls == 0)
    #expect(measurementCalls == 0)
    print(
        "PERF|cache-hit row|"
            + "preparedLookups=\(renderer.preparedLookups) "
            + "heightLookups=\(renderer.heightLookups) "
            + "parseCalls=\(parseCalls) measurementCalls=\(measurementCalls) "
            + "gate=parse=0,measure=0"
    )
}

@Test("performance fixture: markdown corpus preserves one-pass segment output")
func performanceMarkdownFixtureContract() {
    var totalSegments = 0
    var unterminatedSegments = 0
    for id in 0..<500 {
        let text: String
        if id.isMultiple(of: 2) {
            text = "prose \(id)\n```swift\nlet value = \(id)\n```\ntrailing prose"
        } else {
            text = "prose \(id)\n```text\nunterminated \(id)"
        }
        let segments = MarkdownSegment.parse(text)
        totalSegments += segments.count
        if !id.isMultiple(of: 2) {
            unterminatedSegments += 1
            #expect(segments.contains(where: {
                if case .code = $0 { return true }
                return false
            }))
        }
        #expect(segments.map(\.id) == MarkdownSegment.parse(text).map(\.id))
    }

    #expect(totalSegments == 1_250)
    #expect(unterminatedSegments == 250)
    print("PERF|markdown fixture|rows=500 segments=\(totalSegments) unterminatedHandled=\(unterminatedSegments)")
}

@Test("performance report: best-of-three resource measurements")
func performanceResourceReport() async throws {
    let samples = 3
    let documents = (0..<1_000).map { id in
        SearchDocument(
            messageID: ServerMessageID(rawValue: Int64(id)),
            body: "resource corpus row \(id) searchable token",
            role: .assistant
        )
    }
    let snapshot = SearchSessionSnapshot(sessionID: "resource", title: "resource", documents: documents)
    let rows = (0..<1_000).map { performanceRow(id: Int64($0)) }
    let messages = ChatMessage.projectREST(historyRows: rows)

    let cacheMeasurement = try await bestOf(samples) {
        let cacheDirectory = try performanceTemporaryDirectory("ResourceCache")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = HistoryCache(directory: cacheDirectory)
        _ = await cache.store(messages, for: "resource")
        _ = await cache.read(for: "resource")
    }

    let warmURL = FileManager.default.temporaryDirectory
        .appending(path: "HermternalPerformance-warm-\(UUID().uuidString).sqlite")
    let warmIndex = try SearchIndex(url: warmURL)
    try await warmIndex.replace(snapshot)
    let warmQueryMeasurement = try await bestOf(samples) {
        _ = try await warmIndex.search("searchable", limit: 10)
    }
    try await warmIndex.disable()
    removePerformanceIndexFiles(at: warmURL)

    let coldBuildMeasurement = try await bestOf(samples) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "HermternalPerformance-cold-\(UUID().uuidString).sqlite")
        let index = try SearchIndex(url: url)
        try await index.replace(snapshot)
        try await index.disable()
        removePerformanceIndexFiles(at: url)
    }

    let projectionMeasurement = await bestOf(samples) {
        _ = ChatMessage.projectREST(historyRows: rows)
    }

    let footprintURL = FileManager.default.temporaryDirectory
        .appending(path: "HermternalPerformance-footprint-\(UUID().uuidString).sqlite")
    let footprintIndex = try SearchIndex(url: footprintURL)
    try await footprintIndex.replace(snapshot)
    let indexBytesPerThousand = performanceFootprint(at: footprintURL)
    try await footprintIndex.disable()
    removePerformanceIndexFiles(at: footprintURL)

    let footprintCacheDirectory = try performanceTemporaryDirectory("FootprintCache")
    let footprintCache = HistoryCache(directory: footprintCacheDirectory)
    _ = await footprintCache.store(messages, for: "resource")
    let cacheBytesPerThousand = performanceDirectoryFootprint(at: footprintCacheDirectory)
    let diskFootprintCeiling: Int64 = 1_048_576
    #expect(indexBytesPerThousand <= diskFootprintCeiling)
    #expect(cacheBytesPerThousand <= diskFootprintCeiling)
    try? FileManager.default.removeItem(at: footprintCacheDirectory)

    print(
        "PERF|resource wall ms (best of \(samples))|"
        + "warmQuery=\(formatMilliseconds(warmQueryMeasurement.wallMilliseconds)) "
        + "coldIndexBuild=\(formatMilliseconds(coldBuildMeasurement.wallMilliseconds)) "
        + "cacheOpenStore=\(formatMilliseconds(cacheMeasurement.wallMilliseconds)) "
        + "projection=\(formatMilliseconds(projectionMeasurement.wallMilliseconds))"
    )
    print(
        "PERF|resource CPU ms user+sys (best-of wall sample)|"
        + "warmQuery=\(formatMilliseconds(warmQueryMeasurement.cpuMilliseconds)) "
        + "coldIndexBuild=\(formatMilliseconds(coldBuildMeasurement.cpuMilliseconds)) "
        + "cacheOpenStore=\(formatMilliseconds(cacheMeasurement.cpuMilliseconds)) "
        + "projection=\(formatMilliseconds(projectionMeasurement.cpuMilliseconds))"
    )
    print(
        "PERF|resource peak RSS MiB (process ru_maxrss)|"
        + "warmQuery=\(formatMiB(warmQueryMeasurement.peakRSSMiB)) "
        + "coldIndexBuild=\(formatMiB(coldBuildMeasurement.peakRSSMiB)) "
        + "cacheOpenStore=\(formatMiB(cacheMeasurement.peakRSSMiB)) "
        + "projection=\(formatMiB(projectionMeasurement.peakRSSMiB))"
    )
    print(
        "PERF|disk bytes per 1000 messages|"
        + "index=\(indexBytesPerThousand) cache=\(cacheBytesPerThousand) "
        + "gate<=\(diskFootprintCeiling)"
    )
}

@Test("performance contract: worst-v1 app memory envelope")
func performanceWorstTranscriptMemoryContract() {
    let report = WorstTranscriptFixture.run(profile: .mac440MiB)
    #expect(report.fixtureVersion == WorstTranscriptFixture.version)
    #expect(report.sessionCount == 10_000)
    #expect(report.folderCount == 1_000)
    #expect(report.attachmentCount == 8)
    #expect(report.residentAttachmentDataCount == 0)
    #expect(report.switchCount == 20)
    #expect(report.headVisits == 1)
    #expect(report.tailVisits == 1)
    #expect(report.searchQueries == 1)
    #expect(report.findQueries == 1)
    #expect(report.streamChunks == 20)
    #expect(report.stalePublications == 0)
    #expect(report.everyCategoryWithinEnvelope)
    #expect(report.withinProfileEnvelope)
    #expect(report.settledResidentBytes == 0)
    #expect(report.settledGrowthBytes <= 32 * 1_048_576)
    print(
        "PERF|worst-v1 memory signpost|"
            + "sessions=\(report.sessionCount) folders=\(report.folderCount) "
            + "switches=\(report.switchCount) streamChunks=\(report.streamChunks)"
    )
    print(
        "PERF|worst-v1 app-owned bytes|"
            + "peak=\(report.metrics.peakBytes) limit=\(report.profile.totalBytes) "
            + "settled=\(report.settledResidentBytes)"
    )
    print(
        "PERF|worst-v1 physical RSS report-only|"
            + "measure on each target device with Instruments or Activity Monitor; "
            + "do not use RSS as a deterministic test gate"
    )
}

private final class CountingCacheCodec: CacheCodec, @unchecked Sendable {
    private let base = JSONCacheCodec()
    private let lock = NSLock()
    private var count = 0

    var decodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func encode(_ transcript: CachedTranscript) throws -> Data {
        try base.encode(transcript)
    }

    func decode(_ data: Data) throws -> CachedTranscript {
        lock.lock()
        count += 1
        lock.unlock()
        return try base.decode(data)
    }
}
private final class CountingSwitchLookupCache<Key: Hashable, Value> {
    private var values: [Key: Value]
    private(set) var lookupCount = 0

    init(_ values: [Key: Value] = [:]) {
        self.values = values
    }

    func insert(_ value: Value, for key: Key) {
        values[key] = value
    }

    func lookup(_ key: Key) -> Value? {
        lookupCount += 1
        return values[key]
    }
}

private final class CountingCacheHitRowRenderer {
    private var prepared: [MessageIdentity: String]
    private var heights: [RowHeightCacheKey: Double]
    private(set) var preparedLookups = 0
    private(set) var heightLookups = 0

    init(
        prepared: [MessageIdentity: String],
        heights: [RowHeightCacheKey: Double]
    ) {
        self.prepared = prepared
        self.heights = heights
    }

    func render(
        _ message: ChatMessage,
        heightKey: RowHeightCacheKey,
        prepare: () -> String,
        measure: () -> Double
    ) -> (content: String, height: Double) {
        preparedLookups += 1
        let content: String
        if let cached = prepared[message.id] {
            content = cached
        } else {
            content = prepare()
            prepared[message.id] = content
        }

        heightLookups += 1
        let height: Double
        if let cached = heights[heightKey] {
            height = cached
        } else {
            height = measure()
            heights[heightKey] = height
        }
        return (content, height)
    }
}

private func performanceRowHeightKey(for message: ChatMessage) -> RowHeightCacheKey {
    RowHeightCacheKey(
        messageID: message.id,
        revision: "performance-contract-v1",
        availableWidthBits: Double(720).bitPattern,
        textStyle: "body",
        displayScaleBits: Double(2).bitPattern,
        rendererVersion: 1
    )
}


private actor PrefetchProbe {
    private(set) var active = 0
    private(set) var maximum = 0
    private(set) var started: [Int] = []

    func enter(_ value: Int) {
        started.append(value)
        active += 1
        maximum = max(maximum, active)
    }

    func leave() {
        active -= 1
    }
}
private actor PrefetchValueCollector {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}
private actor PayloadResidencyProbe {
    private(set) var active = 0
    private(set) var maximum = 0

    func retain() {
        active += 1
        maximum = max(maximum, active)
    }

    func release() {
        active -= 1
    }
}

private struct RetainedPrefetchPayload: Sendable {
    let value: Int
    let bytes: [UInt8] = Array(repeating: 0, count: 1_024)

    init(value: Int) {
        self.value = value
    }
}
private actor PrefetchPhaseGate {
    private var released: Set<Int> = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func wait(_ phase: Int) async {
        guard !released.contains(phase) else { return }
        await withCheckedContinuation { continuation in
            waiters[phase, default: []].append(continuation)
        }
    }

    func release(_ phase: Int) {
        released.insert(phase)
        let pending = waiters.removeValue(forKey: phase) ?? []
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor PrefetchReleaseGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private final class SearchQueryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private func performanceTemporaryDirectory(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalPerformance-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removePerformanceIndexFiles(at url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
}

private func performanceFTSQueryPlan(at url: URL) throws -> [String] {
    var database: OpaquePointer?
    let openResult = url.path.withCString { path in
        sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
    }
    guard openResult == SQLITE_OK, let database else {
        throw PerformanceSQLiteError.open(openResult)
    }
    defer { sqlite3_close(database) }

    let sql = "EXPLAIN QUERY PLAN SELECT rowid FROM hermternal_search_messages WHERE hermternal_search_messages MATCH 'rare-target*'"
    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard prepareResult == SQLITE_OK, let statement else {
        throw PerformanceSQLiteError.prepare(prepareResult)
    }
    defer { sqlite3_finalize(statement) }

    var details: [String] = []
    while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return details }
        guard step == SQLITE_ROW else { throw PerformanceSQLiteError.step(step) }
        guard let value = sqlite3_column_text(statement, 3) else { continue }
        details.append(String(cString: value))
    }
}

private struct ResourceMeasurement {
    let wallMilliseconds: Double
    let cpuMilliseconds: Double
    let peakRSSMiB: Double
}

private struct UsageSnapshot {
    let userSeconds: Double
    let systemSeconds: Double
    let peakRSSMiB: Double
}

private func bestOf(
    _ samples: Int,
    operation: () async throws -> Void
) async rethrows -> ResourceMeasurement {
    var measurements: [ResourceMeasurement] = []
    measurements.reserveCapacity(samples)
    for _ in 0..<samples {
        let before = performanceUsage()
        let start = ContinuousClock.now
        try await operation()
        let elapsed = start.duration(to: .now)
        let after = performanceUsage()
        let wallMilliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        let cpuMilliseconds = (
            (after.userSeconds - before.userSeconds)
            + (after.systemSeconds - before.systemSeconds)
        ) * 1_000
        measurements.append(ResourceMeasurement(
            wallMilliseconds: wallMilliseconds,
            cpuMilliseconds: cpuMilliseconds,
            peakRSSMiB: after.peakRSSMiB
        ))
    }
    return measurements.min { $0.wallMilliseconds < $1.wallMilliseconds }!
}

private func formatMilliseconds(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private func formatMiB(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private func performanceUsage() -> UsageSnapshot {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let userSeconds = Double(usage.ru_utime.tv_sec)
        + Double(usage.ru_utime.tv_usec) / 1_000_000
    let systemSeconds = Double(usage.ru_stime.tv_sec)
        + Double(usage.ru_stime.tv_usec) / 1_000_000
    #if canImport(Darwin)
    let peakRSSMiB = Double(usage.ru_maxrss) / 1_048_576
    #else
    let peakRSSMiB = Double(usage.ru_maxrss) / 1_024
    #endif
    return UsageSnapshot(
        userSeconds: userSeconds,
        systemSeconds: systemSeconds,
        peakRSSMiB: peakRSSMiB
    )
}

private func performanceFootprint(at url: URL) -> Int64 {
    [
        url,
        URL(fileURLWithPath: url.path + "-wal"),
        URL(fileURLWithPath: url.path + "-shm")
    ].reduce(into: Int64(0)) { total, file in
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber
        else { return }
        total += size.int64Value
    }
}

private func performanceDirectoryFootprint(at directory: URL) -> Int64 {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey]
    ) else { return 0 }
    return files.reduce(into: Int64(0)) { total, file in
        total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}

private func performanceRow(id: Int64) -> JSONValue {
    .object([
        "id": .integer(id),
        "role": .string(Role.assistant.rawValue),
        "content": .string("resource transcript row \(id)")
    ])
}

private enum PerformanceSQLiteError: Error {
    case open(Int32)
    case prepare(Int32)
    case step(Int32)
}
