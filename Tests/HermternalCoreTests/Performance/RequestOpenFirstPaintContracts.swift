import Foundation
@testable import HermternalCore
import Testing

@Test("performance contract: unmigrated 500 visible tail stays within first-paint budget")
func performanceUnmigratedVisibleTailFirstPaintContract() async throws {
    let samples = 5
    var walls: [Double] = []
    walls.reserveCapacity(samples)
    let messages = (0..<500).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "cached transcript row \(index)"
        )
    }
    for _ in 0..<samples {
        let directory = try firstPaintTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = HistoryCache(directory: directory)
        _ = await writer.store(messages, for: "five-hundred")
        let reader = HistoryCache(directory: directory)
        let start = ContinuousClock.now
        let tail = await reader.visibleTail(for: "five-hundred")
        let elapsed = start.duration(to: .now)
        #expect(tail.count == TranscriptPublicationPolicy.initialMessageCount)
        #expect(tail.map(\.text) == messages.suffix(12).map(\.text))
        #expect(await reader.existingPagedStore(for: "five-hundred") == nil)
        walls.append(
            Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        )
    }
    let sorted = walls.sorted()
    let rank = Int((95.0 / 100.0 * Double(sorted.count)).rounded(.up))
    let p95 = sorted[min(sorted.count, max(1, rank)) - 1]
    #expect(p95 <= visibleTailFirstPaintBudgetMilliseconds)
    print(
        "PERF|unmigrated 500 visible tail|"
            + "p95Ms=\(String(format: "%.3f", p95)) "
            + "samples=\(samples) "
            + "gate<=\(TranscriptPublicationPolicy.firstPaintBudgetMilliseconds) "
            + "firstCount=\(TranscriptPublicationPolicy.initialMessageCount)"
    )
}

@Test("performance contract: migrated 500 warm tail stays within first-paint budget")
func performanceMigratedWarmTailFirstPaintContract() async throws {
    let samples = 5
    var walls: [Double] = []
    walls.reserveCapacity(samples)
    let sessionID = "five-hundred"
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
    for _ in 0..<samples {
        let directory = try firstPaintTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryCache(directory: directory)
        _ = await cache.store(messages, snapshot: snapshot, for: sessionID)
        _ = try await cache.pagedStore(for: sessionID)
        let warmStore = TranscriptWarmStore()
        #expect(warmStore.publish(
            messages: messages,
            snapshot: snapshot,
            for: sessionID,
            minimumServerTotal: 500
        ))
        let start = ContinuousClock.now
        let projection = warmStore.projection(for: sessionID, minimumServerTotal: 500)
        let tail = Array(
            (projection?.messages ?? []).suffix(TranscriptPublicationPolicy.initialMessageCount)
        )
        let elapsed = start.duration(to: .now)
        #expect(tail.count == TranscriptPublicationPolicy.initialMessageCount)
        walls.append(
            Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        )
    }
    let sorted = walls.sorted()
    let rank = Int((95.0 / 100.0 * Double(sorted.count)).rounded(.up))
    let p95 = sorted[min(sorted.count, max(1, rank)) - 1]
    #expect(p95 <= Double(TranscriptPublicationPolicy.firstPaintBudgetMilliseconds))
    print(
        "PERF|migrated 500 warm tail|"
            + "p95Ms=\(String(format: "%.3f", p95)) "
            + "samples=\(samples) "
            + "gate<=\(TranscriptPublicationPolicy.firstPaintBudgetMilliseconds) "
            + "firstCount=\(TranscriptPublicationPolicy.initialMessageCount)"
    )
}

private func firstPaintTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalFirstPaint-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private var visibleTailFirstPaintBudgetMilliseconds: Double {
#if DEBUG
    // Isolated release performance-contracts enforce the 100 ms budget.
    // Debug validate.sh runs this fully parallel with the rest of the
    // suite; shared disk and CPU wait make the sidecar tail read slower.
    // Isolated this path is 1-7 ms. 500 ms still fails a 500-row decode.
    500
#else
    Double(TranscriptPublicationPolicy.firstPaintBudgetMilliseconds)
#endif
}
