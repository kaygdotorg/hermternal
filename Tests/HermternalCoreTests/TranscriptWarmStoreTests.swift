import Foundation
import HermternalCore
import Testing

@Test("complete warm projection is available synchronously")
func completeWarmProjectionIsImmediate() throws {
    let store = TranscriptWarmStore()
    let messages = [ChatMessage(role: .assistant, text: "cached")]
    let snapshot = warmSnapshot(sessionID: "one", fetchedRows: 3, serverTotal: 3, projectedMessages: 1)

    #expect(store.publish(messages: messages, snapshot: snapshot, for: "one"))
    let projection = try #require(store.projection(for: "one"))
    #expect(projection.messages.count == messages.count)
    #expect(projection.messages[0].text == messages[0].text)
    #expect(projection.snapshot.fetchedRows == 3)
}

@Test("incomplete, mismatched, and under-total snapshots are rejected")
func invalidWarmProjectionsAreRejected() {
    let store = TranscriptWarmStore()
    let messages = [ChatMessage(role: .user, text: "not ready")]

    #expect(!store.publish(
        messages: messages,
        snapshot: warmSnapshot(sessionID: "one", fetchedRows: 2, serverTotal: 2, truncated: true),
        for: "one"
    ))
    #expect(!store.publish(
        messages: messages,
        snapshot: warmSnapshot(sessionID: "other", fetchedRows: 2, serverTotal: 2),
        for: "one"
    ))
    #expect(!store.publish(
        messages: messages,
        snapshot: warmSnapshot(sessionID: "one", fetchedRows: 1, serverTotal: 2),
        for: "one"
    ))
    #expect(!store.publish(
        messages: messages,
        snapshot: warmSnapshot(sessionID: "one", fetchedRows: 2, serverTotal: 2),
        for: "one",
        minimumServerTotal: 3
    ))
    #expect(!store.publish(
        messages: messages,
        snapshot: warmSnapshot(sessionID: "one", fetchedRows: 2, serverTotal: 2, projectedMessages: 0),
        for: "one"
    ))
}

@Test("minimum total growth invalidates a previously complete projection")
func minimumTotalGrowthInvalidatesWarmProjection() {
    let store = TranscriptWarmStore()
    let snapshot = warmSnapshot(sessionID: "one", fetchedRows: 4, serverTotal: 4, projectedMessages: 0)
    #expect(store.publish(messages: [], snapshot: snapshot, for: "one"))
    #expect(store.projection(for: "one", minimumServerTotal: 5) == nil)
    #expect(store.projection(for: "one", minimumServerTotal: 4) != nil)
}

@Test("retain, remove, and clear maintain aggregate accounting")
func warmStoreLifecycleOperations() {
    let store = TranscriptWarmStore()
    for id in ["one", "two", "three"] {
        #expect(store.publish(
            messages: [ChatMessage(role: .assistant, text: id)],
            snapshot: warmSnapshot(sessionID: id, fetchedRows: 1, serverTotal: 1),
            for: id
        ))
    }
    #expect(store.metrics.retainedBytes > 0)

    store.remove(sessionIDs: ["one"])
    #expect(store.projection(for: "one") == nil)
    store.retain(sessionIDs: ["two"])
    #expect(store.metrics.projectionCount == 1)
    #expect(store.projection(for: "two") != nil)

    store.clear()
    #expect(store.metrics == TranscriptWarmStore.Metrics(projectionCount: 0, retainedBytes: 0))
}

@Test("least recently used eviction is deterministic and releases payload")
func deterministicLRUEviction() {
    let store = TranscriptWarmStore(budgetBytes: 1_300)
    for (id, fill) in [("one", "x"), ("two", "y")] {
        #expect(store.publish(
            messages: [ChatMessage(role: .assistant, text: String(repeating: fill, count: 44))],
            snapshot: warmSnapshot(sessionID: id, fetchedRows: 1, serverTotal: 1),
            for: id
        ))
    }
    let before = store.metrics.retainedBytes
    #expect(store.projection(for: "one") != nil)
    #expect(store.publish(
        messages: [ChatMessage(role: .assistant, text: String(repeating: "z", count: 44))],
        snapshot: warmSnapshot(sessionID: "three", fetchedRows: 1, serverTotal: 1),
        for: "three"
    ))
    #expect(store.metrics.retainedBytes <= store.budgetBytes)
    #expect(store.projection(for: "one") != nil)
    #expect(store.projection(for: "two") == nil)
    #expect(store.projection(for: "three") != nil)
    store.remove(sessionIDs: ["one", "three"])
    #expect(store.metrics.retainedBytes < before)
    #expect(store.metrics.retainedBytes == 0)
}

@Test("oversized projections are rejected without disturbing existing state")
func oversizedProjectionRejected() {
    let store = TranscriptWarmStore(budgetBytes: 800)
    #expect(store.publish(
        messages: [ChatMessage(role: .assistant, text: "kept")],
        snapshot: warmSnapshot(sessionID: "one", fetchedRows: 1, serverTotal: 1),
        for: "one"
    ))
    let before = store.metrics
    #expect(!store.publish(
        messages: [ChatMessage(role: .assistant, text: String(repeating: "x", count: 1_000))],
        snapshot: warmSnapshot(sessionID: "two", fetchedRows: 1, serverTotal: 1),
        for: "two"
    ))
    #expect(store.metrics == before)
    #expect(store.projection(for: "one") != nil)
}


@Test("warm-store residency reaches a stable byte ceiling across distinct conversations")
func warmStoreDistinctConversationResidencyIsBounded() {
    let budget = 4_096
    let store = TranscriptWarmStore(budgetBytes: budget)
    for index in 0..<500 {
        let id = "conversation-\(index)"
        #expect(store.publish(
            messages: [ChatMessage(role: .assistant, text: String(repeating: "z", count: 512))],
            snapshot: warmSnapshot(sessionID: id, fetchedRows: 1, serverTotal: 1),
            for: id
        ))
        #expect(store.metrics.retainedBytes <= budget)
    }

    let bounded = store.metrics
    #expect(bounded.projectionCount < 500)
    #expect(bounded.retainedBytes <= budget)
    store.clear()
    #expect(store.metrics.retainedBytes == 0)
}

@Test("repeated publish replaces in place without increasing count")
func repeatedPublishReplacesProjection() throws {
    let store = TranscriptWarmStore()
    let first = warmSnapshot(sessionID: "one", fetchedRows: 1, serverTotal: 1, projectedMessages: 1)
    let second = warmSnapshot(sessionID: "one", fetchedRows: 2, serverTotal: 2, projectedMessages: 1)
    #expect(store.publish(messages: [ChatMessage(role: .user, text: "old")], snapshot: first, for: "one"))
    #expect(store.publish(messages: [ChatMessage(role: .assistant, text: "new")], snapshot: second, for: "one"))
    #expect(store.metrics.projectionCount == 1)
    let projection = try #require(store.projection(for: "one"))
    #expect(projection.snapshot.fetchedRows == 2)
    #expect(projection.messages[0].text == "new")
}

@Test("synchronous lookup stays below one millisecond per projection")
func synchronousLookupPerformanceContract() throws {
    let store = TranscriptWarmStore(budgetBytes: 128 * 1024 * 1024)
    for index in 0..<1_000 {
        let id = "session-\(index)"
        #expect(store.publish(
            messages: [ChatMessage(role: .assistant, text: id)],
            snapshot: warmSnapshot(sessionID: id, fetchedRows: 1, serverTotal: 1),
            for: id
        ))
    }

    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for index in 0..<1_000 {
            _ = store.projection(for: "session-\(index)")
        }
    }
    print("PERF|warm lookup|projections=1000 average<1ms elapsed=\(elapsed)")
    // One second for 1,000 synchronous reads is an intentionally strict,
    // stable sub-millisecond average contract without a machine-specific floor.
    #expect(elapsed < .seconds(1))
}

private func warmSnapshot(
    sessionID: String,
    fetchedRows: Int,
    serverTotal: Int?,
    truncated: Bool = false,
    projectedMessages: Int? = nil
) -> AuthoritativeTranscriptSnapshot {
    AuthoritativeTranscriptSnapshot(
        sessionID: sessionID,
        serverTotal: serverTotal,
        fetchedRows: fetchedRows,
        projectedMessages: projectedMessages ?? fetchedRows,
        truncated: truncated,
        fetchedAt: Date(timeIntervalSince1970: 1_750_000_000)
    )
}
