import Foundation
import Testing
@testable import Hermternal
@testable import HermternalCore


@Test("performance contract: unmigrated 500 requestOpen paints 12 within budget")
@MainActor
func performanceUnmigratedRequestOpenFirstPaintContract() async throws {
    let samples = 5
    var walls: [Double] = []
    walls.reserveCapacity(samples)
    for _ in 0..<samples {
        let directory = try requestOpenPerformanceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryCache(directory: directory)
        let fixture = requestOpenPerformanceFixture(sessionID: "five-hundred")
        _ = await cache.store(
            fixture.messages,
            snapshot: fixture.snapshot,
            for: fixture.session.id
        )
        let model = AppModel(
            cache: cache,
            transcriptSource: RequestOpenPerformanceSource(),
            warmStore: TranscriptWarmStore()
        )
        model.phase = .ready
        model.sessions = [fixture.session]
        model.cacheEnabled = true

        await drainMainQueueOnce()
        let start = ContinuousClock.now
        let task = model.requestOpen(fixture.session)
        let painted = await requestOpenWait(
            until: "unmigrated first paint publishes 12 messages",
            holds: { model.messages.count == TranscriptPublicationPolicy.initialMessageCount }
        )
        let elapsed = start.duration(to: .now)
        model.cancelOpenPreparation()
        _ = task
        #expect(painted)
        #expect(model.messages.map(\.text) == Array(fixture.messages.suffix(12).map(\.text)))
        walls.append(durationMilliseconds(elapsed))
    }
    let p95 = performancePercentile(walls, percentile: 95)
    #expect(p95 <= requestOpenFirstPaintBudgetMilliseconds)
    print(
        "PERF|unmigrated 500 requestOpen|"
            + "p95Ms=\(formatRequestOpenMilliseconds(p95)) "
            + "samples=\(samples) "
            + "gate<=\(TranscriptPublicationPolicy.firstPaintBudgetMilliseconds) "
            + "firstCount=\(TranscriptPublicationPolicy.initialMessageCount)"
    )
}

@Test("performance contract: migrated 500 requestOpen paints 12 within budget")
@MainActor
func performanceMigratedRequestOpenFirstPaintContract() async throws {
    let samples = 5
    var walls: [Double] = []
    walls.reserveCapacity(samples)
    for _ in 0..<samples {
        let directory = try requestOpenPerformanceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryCache(directory: directory)
        let fixture = requestOpenPerformanceFixture(sessionID: "five-hundred")
        _ = await cache.store(
            fixture.messages,
            snapshot: fixture.snapshot,
            for: fixture.session.id
        )
        _ = try await cache.pagedStore(for: fixture.session.id)
        let warmStore = TranscriptWarmStore()
        #expect(warmStore.publish(
            messages: fixture.messages,
            snapshot: fixture.snapshot,
            for: fixture.session.id,
            minimumServerTotal: fixture.session.messageCount
        ))
        let model = AppModel(
            cache: cache,
            transcriptSource: RequestOpenPerformanceSource(),
            warmStore: warmStore
        )
        model.phase = .ready
        model.sessions = [fixture.session]
        model.cacheEnabled = true

        await drainMainQueueOnce()
        let start = ContinuousClock.now
        let task = model.requestOpen(fixture.session)
        let painted = await requestOpenWait(
            until: "migrated first paint publishes 12 messages",
            holds: { model.messages.count == TranscriptPublicationPolicy.initialMessageCount }
        )
        let elapsed = start.duration(to: .now)
        model.cancelOpenPreparation()
        _ = task
        #expect(painted)
        #expect(model.messages.map(\.text) == Array(fixture.messages.suffix(12).map(\.text)))
        walls.append(durationMilliseconds(elapsed))
    }
    let p95 = performancePercentile(walls, percentile: 95)
    #expect(p95 <= requestOpenFirstPaintBudgetMilliseconds)
    print(
        "PERF|migrated 500 requestOpen|"
            + "p95Ms=\(formatRequestOpenMilliseconds(p95)) "
            + "samples=\(samples) "
            + "gate<=\(TranscriptPublicationPolicy.firstPaintBudgetMilliseconds) "
            + "firstCount=\(TranscriptPublicationPolicy.initialMessageCount)"
    )
}

@Test("performance contract: warm keypress requestOpen publishes tail on the same turn")
@MainActor
func performanceWarmKeypressRequestOpenPublishesOnTheSameTurn() async throws {
    let samples = 5
    var walls: [Double] = []
    walls.reserveCapacity(samples)
    for _ in 0..<samples {
        let directory = try requestOpenPerformanceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryCache(directory: directory)
        let fixture = requestOpenPerformanceFixture(sessionID: "warm-keypress")
        _ = await cache.store(
            fixture.messages,
            snapshot: fixture.snapshot,
            for: fixture.session.id
        )
        let warmStore = TranscriptWarmStore()
        #expect(warmStore.publish(
            messages: fixture.messages,
            snapshot: fixture.snapshot,
            for: fixture.session.id,
            minimumServerTotal: fixture.session.messageCount
        ))
        let model = AppModel(
            cache: cache,
            transcriptSource: RequestOpenPerformanceSource(),
            warmStore: warmStore
        )
        model.phase = .ready
        model.sessions = [fixture.session]
        model.cacheEnabled = true

        await drainMainQueueOnce()
        let start = ContinuousClock.now
        let task = model.requestOpen(fixture.session)
        let elapsed = start.duration(to: .now)
        #expect(model.transcriptRouteIdentity == "live:\(fixture.session.id)")
        #expect(model.messages.count == TranscriptPublicationPolicy.initialMessageCount)
        #expect(model.messages.map(\.text) == Array(fixture.messages.suffix(12).map(\.text)))
        #expect(model.activeTranscriptStore == nil)
        model.cancelOpenPreparation()
        _ = task
        walls.append(durationMilliseconds(elapsed))
    }
    let p95 = performancePercentile(walls, percentile: 95)
    let gate = requestOpenKeypressPaintBudgetMilliseconds
    #expect(p95 <= gate)
    print(
        "PERF|warm keypress requestOpen|"
            + "p95Ms=\(formatRequestOpenMilliseconds(p95)) "
            + "samples=\(samples) "
            + "gate<=\(formatRequestOpenMilliseconds(gate)) "
            + "firstCount=\(TranscriptPublicationPolicy.initialMessageCount)"
    )
}

private var requestOpenKeypressPaintBudgetMilliseconds: Double {
#if DEBUG
    // Isolated release performance-contracts enforce the 16 ms keypress paint
    // budget. Debug validate.sh runs this next to hundreds of MainActor tests;
    // contention on the enforcing MainActor turn can extend the measured wall.
    100
#else
    Double(TranscriptPublicationPolicy.keypressPaintBudgetMilliseconds)
#endif
}

private struct RequestOpenPerformanceSource: TranscriptSource {
    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        AuthoritativeTranscript(rows: [], serverTotal: 0)
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        ResumedTranscript(liveSessionID: nil, rows: [])
    }

    func streamAuthoritative(
        sessionID _: String,
        onPage _: @escaping TranscriptMessagePageConsumer
    ) async throws -> AuthoritativeTranscriptMetadata {
        AuthoritativeTranscriptMetadata(messageCount: 0, serverTotal: 0)
    }
}

private func requestOpenPerformanceFixture(sessionID: String) -> (
    session: ChatSession,
    messages: [ChatMessage],
    snapshot: AuthoritativeTranscriptSnapshot
) {
    let messages = (0..<500).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "cached transcript row \(index)"
        )
    }
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: sessionID,
        serverTotal: 500,
        fetchedRows: 500,
        projectedMessages: 500,
        truncated: false,
        fetchedAt: Date(timeIntervalSince1970: 0)
    )
    let session = ChatSession(from: .object([
        "id": .string(sessionID),
        "message_count": .integer(500)
    ]))
    return (session, messages, snapshot)
}

private func requestOpenPerformanceDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalRequestOpenPerf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}


@MainActor
private func drainMainQueueOnce() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

private var requestOpenFirstPaintBudgetMilliseconds: Double {
#if DEBUG
    // Isolated release performance-contracts enforce the 100 ms budget.
    // Debug validate.sh runs this next to hundreds of MainActor tests; the
    // required run-loop hop after selection includes that queue wait.
    // 500 ms still fails the pre-fix 6.7-13.5 s migration path.
    500
#else
    Double(TranscriptPublicationPolicy.firstPaintBudgetMilliseconds)
#endif
}

private let requestOpenWaitBound = Duration.seconds(5)

@MainActor
private func requestOpenWait(
    until condition: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    holds: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + requestOpenWaitBound
    while true {
        if await holds() { return true }
        guard ContinuousClock.now < deadline else {
            Issue.record(
                "The wait ended after \(requestOpenWaitBound). The condition did not occur: \(condition).",
                sourceLocation: sourceLocation
            )
            return false
        }
        await Task.yield()
    }
}

private func durationMilliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

private func performancePercentile(_ values: [Double], percentile: Double) -> Double {
    let sorted = values.sorted()
    let rank = Int((percentile / 100.0 * Double(sorted.count)).rounded(.up))
    let index = min(sorted.count, max(1, rank)) - 1
    return sorted[index]
}

private func formatRequestOpenMilliseconds(_ value: Double) -> String {
    String(format: "%.3f", value)
}
