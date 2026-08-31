import Foundation
import Observation
import Testing
@testable import Hermternal
@testable import HermternalCore

@Test("session-list authority is not part of the Observation graph")
@MainActor
func sessionListAuthorityIsNotObserved() throws {
    let directory = try observationTrackingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(cache: HistoryCache(directory: directory))
    let probe = ObservationFireProbe()
    withObservationTracking {
        _ = model.sessionListIsComplete
    } onChange: {
        probe.fires += 1
    }
    model.testingSetSessionListComplete(true)
    #expect(model.sessionListIsComplete)
    #expect(probe.fires == 0)
}

@Test("completing the session list cannot re-enter Observation tracking")
@MainActor
func completingTheSessionListCannotReenterObservationTracking() throws {
    let directory = try observationTrackingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(cache: HistoryCache(directory: directory))
    let probe = ObservationFireProbe()
    withObservationTracking {
        _ = model.sessions
        _ = model.sessionListIsComplete
    } onChange: {
        probe.fires += 1
    }
    model.sessions = [
        ChatSession(
            id: "chat-1",
            title: "One",
            lastActive: Date(timeIntervalSince1970: 1),
            messageCount: 1
        )
    ]
    #expect(probe.fires == 1)
    model.testingSetSessionListComplete(true)
    #expect(probe.fires == 1)
}

@Test("ObservationHop runs on the next main-queue turn")
@MainActor
func observationHopRunsOnTheNextMainQueueTurn() async {
    let probe = ObservationFireProbe()
    ObservationHop.enqueue {
        probe.fires += 1
    }
    #expect(probe.fires == 0)
    await drainMainQueueOnceForObservation()
    #expect(probe.fires == 1)
}

private final class ObservationFireProbe: @unchecked Sendable {
    var fires = 0
}

@MainActor
private func drainMainQueueOnceForObservation() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

private func observationTrackingTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "HermternalObservation-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
