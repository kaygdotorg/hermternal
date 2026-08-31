import Foundation

/// A lock-protected snapshot of paged-store index data for synchronous page
/// reads. The actor publishes after load and after a durable index write.
/// Configure paths read this snapshot and the record files. They never hop
/// to the store actor.
final class TranscriptResidentPageSource: @unchecked Sendable {
    private struct Snapshot {
        var loaded = false
        var generation: UInt64 = 0
        var epoch: UInt64 = 0
        var order: [String] = []
        var turnIndex: [TranscriptTurnIndexEntry] = []
        var modelSwitchIndex: [TranscriptModelSwitchMarker] = []
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private let directory: URL
    private let fileSystem: any TranscriptFileSystem

    init(directory: URL, fileSystem: any TranscriptFileSystem) {
        self.directory = directory
        self.fileSystem = fileSystem
    }

    func publish(
        loaded: Bool,
        generation: UInt64,
        epoch: UInt64,
        order: [String],
        turnIndex: [TranscriptTurnIndexEntry],
        modelSwitchIndex: [TranscriptModelSwitchMarker]
    ) {
        lock.lock()
        snapshot = Snapshot(
            loaded: loaded,
            generation: generation,
            epoch: epoch,
            order: order,
            turnIndex: turnIndex,
            modelSwitchIndex: modelSwitchIndex
        )
        lock.unlock()
    }

    /// Returns a page when every record file for that page is on disk.
    /// Returns nil when the index is not loaded, the route does not match,
    /// or a record file is missing.
    func turnPage(_ request: TranscriptTurnPageRequest) -> TranscriptTurnPage? {
        lock.lock()
        let snapshot = self.snapshot
        lock.unlock()
        guard snapshot.loaded else { return nil }
        if let expected = request.expectedGeneration, expected != snapshot.generation {
            return nil
        }
        if let expected = request.expectedEpoch, expected != snapshot.epoch {
            return nil
        }
        let start = min(max(0, request.startOrdinal), snapshot.turnIndex.count)
        let end = min(snapshot.turnIndex.count, start + request.maximumRows)
        guard start < end else {
            return TranscriptTurnPage(
                turns: [],
                startOrdinal: start,
                nextOrdinal: start,
                totalTurnCount: snapshot.turnIndex.count,
                hasMore: start < snapshot.turnIndex.count,
                modelSwitches: snapshot.modelSwitchIndex
            )
        }
        var projected: [TranscriptTurn] = []
        projected.reserveCapacity(end - start)
        var bytes = 0
        for index in start..<end {
            let span = snapshot.turnIndex[index]
            guard span.firstWireOrdinal <= span.lastWireOrdinal,
                  span.lastWireOrdinal < snapshot.order.count
            else { return nil }
            var records: [WireMessageRecord] = []
            records.reserveCapacity(span.lastWireOrdinal - span.firstWireOrdinal + 1)
            for wireOrdinal in span.firstWireOrdinal...span.lastWireOrdinal {
                guard let record = readRecord(messageID: snapshot.order[wireOrdinal]) else {
                    return nil
                }
                records.append(record)
            }
            let model = snapshot.modelSwitchIndex.last {
                $0.ordinal < span.firstWireOrdinal
            }?.model
            let turn = TranscriptTurnProjector.project(
                records: records,
                sessionModel: request.sessionModel,
                hasModelMarkers: !snapshot.modelSwitchIndex.isEmpty,
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
            totalTurnCount: snapshot.turnIndex.count,
            hasMore: next < snapshot.turnIndex.count,
            modelSwitches: snapshot.modelSwitchIndex
        )
    }

    private func readRecord(messageID: String) -> WireMessageRecord? {
        let url = Self.recordURL(directory: directory, messageID: messageID)
        guard let data = try? fileSystem.data(at: url), data.count >= 8 else {
            return nil
        }
        let length = data.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length <= UInt64(data.count - 8), data.count == 8 + Int(length) else {
            return nil
        }
        let payload = data.subdata(in: 8..<(8 + Int(length)))
        return try? JSONDecoder().decode(WireMessageRecord.self, from: payload)
    }

    static func recordURL(directory: URL, messageID: String) -> URL {
        let encoded = Data(messageID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return directory.appendingPathComponent("record-\(encoded).json")
    }
}
