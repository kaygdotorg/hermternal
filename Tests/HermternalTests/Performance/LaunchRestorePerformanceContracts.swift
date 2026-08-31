import Foundation
@testable import Hermternal
@testable import HermternalCore
import Testing
import os

@Test("performance contract: cached launch publishes restored transcript without network")
@MainActor
func performanceLaunchCachedFirstPaintContract() async throws {
    let samples = 5
    var walls: [Double] = []
    walls.reserveCapacity(samples)
    var networkTouches = 0

    for _ in 0..<samples {
        let directory = try launchPaintTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = ChatSession(
            id: "restored-chat",
            title: "Restored",
            lastActive: Date(timeIntervalSince1970: 1_700_000_000),
            messageCount: 20
        )
        let messages = (0..<20).map { index in
            ChatMessage(
                id: .server(ServerMessageID(rawValue: Int64(index))),
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "cached transcript row \(index)",
                isStreaming: index == 19
            )
        }
        let snapshot = AuthoritativeTranscriptSnapshot(
            sessionID: session.id,
            serverTotal: 20,
            fetchedRows: 20,
            projectedMessages: 20,
            truncated: false,
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        let history = HistoryCache(directory: directory)
        _ = await history.store(messages, snapshot: snapshot, for: session.id)
        let list = SessionListCache(directory: directory)
        #expect(list.saveSessions([session]))
        #expect(list.saveSelectedSessionID(session.id))
        let source = LaunchNetworkProbeSource()
        let model = AppModel(
            cache: history,
            transcriptSource: source,
            warmStore: TranscriptWarmStore()
        )
        model.cacheEnabled = true
        #expect(model.phase == .restoring)
        #expect(model.selectedSessionID == session.id)

        let start = ContinuousClock.now
        model.publishRestoredTranscript()
        let elapsed = start.duration(to: .now)
        networkTouches += source.touchCount
        #expect(model.messages.map(\.text) == Array(messages.suffix(
            TranscriptPublicationPolicy.initialMessageCount
        ).map(\.text)))
        #expect(model.messages.allSatisfy { !$0.isStreaming })
        #expect(!model.isAwaitingReply)
        walls.append(durationMilliseconds(elapsed))
        model.cancelOpenPreparation()
    }

    #expect(networkTouches == 0)
    let p95 = launchPaintPercentile(walls, percentile: 95)
    #expect(p95 <= launchPaintBudgetMilliseconds)
    print(
        "PERF|launch cached first paint|"
            + "p95Ms=\(formatLaunchPaintMilliseconds(p95)) "
            + "samples=\(samples) "
            + "networkTouches=\(networkTouches) "
            + "gate<=\(TranscriptPublicationPolicy.firstPaintBudgetMilliseconds)"
    )
}

private final class LaunchNetworkProbeSource: TranscriptSource, @unchecked Sendable {
    private let touches = OSAllocatedUnfairLock(initialState: 0)

    var touchCount: Int {
        touches.withLock { $0 }
    }

    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        touches.withLock { $0 += 1 }
        return AuthoritativeTranscript(rows: [], serverTotal: 0)
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        touches.withLock { $0 += 1 }
        return ResumedTranscript(liveSessionID: nil, rows: [])
    }

    func streamAuthoritative(
        sessionID _: String,
        onPage _: @escaping TranscriptMessagePageConsumer
    ) async throws -> AuthoritativeTranscriptMetadata {
        touches.withLock { $0 += 1 }
        return AuthoritativeTranscriptMetadata(messageCount: 0, serverTotal: 0)
    }
}

private func launchPaintTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalLaunchPaint-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func durationMilliseconds(_ elapsed: Duration) -> Double {
    Double(elapsed.components.seconds) * 1_000
        + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
}

private func launchPaintPercentile(_ values: [Double], percentile: Double) -> Double {
    let sorted = values.sorted()
    let rank = Int((percentile / 100.0 * Double(sorted.count)).rounded(.up))
    return sorted[min(sorted.count, max(1, rank)) - 1]
}

private var launchPaintBudgetMilliseconds: Double {
#if DEBUG
    500
#else
    Double(TranscriptPublicationPolicy.firstPaintBudgetMilliseconds)
#endif
}

private func formatLaunchPaintMilliseconds(_ value: Double) -> String {
    String(format: "%.3f", value)
}
