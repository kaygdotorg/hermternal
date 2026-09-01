import AppKit
import Foundation
@testable import Hermternal
@testable import HermternalCore
import Testing

@Test("performance contract: warm switch publish-to-draw p95 stays in budget")
@MainActor
func performanceWarmSwitchPublishToDrawContract() {
    _ = NSApplication.shared
    TranscriptPaintCache.resetForTesting()
    let coordinator = BlockTranscriptView.Coordinator()
    let container = coordinator.makeContainer()
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 420))
    root.addSubview(container)
    NSLayoutConstraint.activate([
        container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        container.topAnchor.constraint(equalTo: root.topAnchor),
        container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])
    root.layoutSubtreeIfNeeded()

    let identities = (0..<24).map { "live:switch-\($0)" }
    let fixtures = identities.map { identity in
        (identity, publishToDrawFixture(identity: identity))
    }

    func paint(_ identity: String, _ messages: [ChatMessage], revision: UInt64) {
        coordinator.update(
            container: container,
            input: TranscriptRendererInput(
                store: nil,
                route: nil,
                summary: nil,
                revision: revision,
                isReadOnly: false,
                isStreaming: false,
                findQuery: "",
                pendingMessageID: nil,
                findMessageID: nil,
                showsMetadata: false,
                publishedTail: messages,
                paintIdentity: identity,
                onCopyCode: { _ in },
                onPaint: { _ in }
            )
        )
        root.layoutSubtreeIfNeeded()
        _ = container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
    }

    // Cold fill: populate the process cache and the row pool.
    for (index, fixture) in fixtures.enumerated() {
        paint(fixture.0, fixture.1, revision: UInt64(index))
    }

    var walls: [Double] = []
    walls.reserveCapacity(fixtures.count)
    for (index, fixture) in fixtures.enumerated() {
        let start = ContinuousClock.now
        paint(fixture.0, fixture.1, revision: UInt64(100 + index))
        let elapsed = start.duration(to: .now)
        walls.append(
            Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        )
    }

    coordinator.dismantle(container: container)
    let p95 = publishToDrawPercentile(walls, percentile: 95)
    #expect(p95 <= publishToDrawGateMilliseconds)
    print(
        "PERF|warm switch publishToDraw|"
            + "p95Ms=\(String(format: "%.3f", p95)) "
            + "samples=\(walls.count) "
            + "gate<=\(Int(publishToDrawGateMilliseconds)) "
            + "attrHit=\(TranscriptPaintCache.attributedHits) "
            + "attrMiss=\(TranscriptPaintCache.attributedMisses) "
            + "layoutHit=\(TranscriptPaintCache.layoutHits) "
            + "layoutMiss=\(TranscriptPaintCache.layoutMisses)"
    )
}

@Test("paint cache evicts at the turn bound")
@MainActor
func paintCacheEvictsAtTurnBound() {
    TranscriptPaintCache.resetForTesting()
    for index in 0..<(TranscriptPaintCache.maxEntries + 8) {
        let turn = TranscriptTurn(
            id: "evict-\(index)",
            speaker: .hermes,
            answer: "row \(index)"
        )
        TranscriptPaintCache.store(
            document: MarkdownDocument.parse(turn.answer).document,
            for: turn
        )
    }
    #expect(TranscriptPaintCache.entryCount == TranscriptPaintCache.maxEntries)
}

@Test("paint cache attributed lookup hits a stored turn")
@MainActor
func paintCacheAttributedLookupHitsStoredTurn() {
    TranscriptPaintCache.resetForTesting()
    let turn = TranscriptTurn(
        id: "attr-hit",
        speaker: .hermes,
        answer: "**bold** and a `code` span"
    )
    let document = MarkdownDocument.parse(turn.answer).document
    let styled = TranscriptRendererTestSeam.attributedAnswer(document)
    TranscriptPaintCache.store(document: document, for: turn)
    TranscriptPaintCache.store(
        attributed: styled,
        for: turn,
        findQuery: "",
        isUniform: false
    )
    let hit = TranscriptPaintCache.attributedString(
        for: turn,
        findQuery: "",
        isUniform: false
    )
    #expect(hit?.string == styled.string)
    #expect(TranscriptPaintCache.attributedHits == 1)
    #expect(TranscriptPaintCache.attributedMisses == 0)
}

private func publishToDrawFixture(identity: String) -> [ChatMessage] {
    (0..<TranscriptPublicationPolicy.initialMessageCount).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(identity.hashValue &+ index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: index.isMultiple(of: 2)
                ? "user \(identity) \(index)"
                : """
                ## Answer \(index)
                A short markdown tail for \(identity).
                - item one
                - item two
                `code`
                """
        )
    }
}

private var publishToDrawGateMilliseconds: Double {
#if DEBUG
    100
#else
    Double(TranscriptPublicationPolicy.publishToDrawBudgetMilliseconds)
#endif
}

private func publishToDrawPercentile(_ values: [Double], percentile: Double) -> Double {
    let sorted = values.sorted()
    let rank = Int((percentile / 100.0 * Double(sorted.count)).rounded(.up))
    let index = min(sorted.count, max(1, rank)) - 1
    return sorted[index]
}
