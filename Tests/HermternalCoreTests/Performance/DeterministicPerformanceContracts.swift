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
    let values = await coordinator.prefetch(Array(0..<30)) { value in
        await probe.enter(value)
        await Task.yield()
        await probe.leave()
        return value
    }

    let started = await probe.started
    let uniqueStarted = Set(started)
    let maximum = await probe.maximum
    #expect(values == Array(0..<30))
    #expect(started.count == 30)
    #expect(uniqueStarted.count == 30)
    #expect(uniqueStarted == Set(0..<30))
    #expect(maximum <= 4)
    print("PERF|prefetch bound|items=30 unique=\(uniqueStarted.count) maxInFlight=\(maximum)")
}

@Test("performance contract: cancellation prevents queued prefetch work")
func performancePrefetchCancellationContract() async {
    let coordinator = BoundedPrefetchCoordinator(limit: 4)
    let probe = PrefetchProbe()
    let gate = PrefetchReleaseGate()
    let task: Task<[Int], Never> = Task {
        await coordinator.prefetch(Array(0..<30)) { value in
            await probe.enter(value)
            guard !Task.isCancelled else {
                await probe.leave()
                return nil
            }
            await gate.wait()
            guard !Task.isCancelled else {
                await probe.leave()
                return nil
            }
            await probe.leave()
            return value
        }
    }

    while await probe.started.count < 4 { await Task.yield() }
    task.cancel()
    await gate.releaseAll()
    let values = await task.value
    let started = await probe.started
    #expect(values.isEmpty)
    #expect(Set(started) == Set(0..<4))
    print("PERF|prefetch cancellation|started=\(started.count) returned=\(values.count) queued=\(30 - started.count)")
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
        #expect(segments.map(\.id) == Array(0..<segments.count))
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
