import Foundation
import Testing
@testable import HermternalCore

@Test("block preparation never exceeds four lanes for a burst")
func blockPreparationUsesAtMostFourLanes() async {
    let coordinator = BlockPreparationCoordinator(laneCount: 30)
    let probe = PreparationProbe(releaseAt: 4)
    let blocks = makeBlocks(count: 30)

    let task = Task {
        await coordinator.prepare(
            blocks,
            preparation: { block in
                await probe.enterAndWait()
                return block.blockIndex
            },
            onResult: { _ in }
        )
    }

    await probe.waitUntilStarted(4)
    #expect(await probe.maximumActive <= 4)
    await probe.release()
    await task.value
    #expect(await probe.calls == 30)
}

@Test("cancelling a request prevents queued blocks from being prepared")
func blockPreparationCancellationStopsQueuedWork() async {
    let coordinator = BlockPreparationCoordinator()
    let probe = PreparationProbe(releaseAt: 4)
    let delivered = ResultProbe<Int>()
    let blocks = makeBlocks(count: 30)

    let task = Task {
        await coordinator.prepare(
            blocks,
            preparation: { block in
                await probe.enterAndWait()
                try Task.checkCancellation()
                await probe.markShaped()
                return block.blockIndex
            },
            onResult: { value in await delivered.append(value) }
        )
    }
    await probe.waitUntilStarted(4)
    coordinator.cancel()
    await probe.release()
    await task.value

    #expect(await probe.calls == 4)
    #expect(await probe.shaped == 0)
    #expect(await delivered.values.isEmpty)
}

@Test("a superseded request delivers no stale results")
func supersededBlockPreparationDeliversNothing() async {
    let coordinator = BlockPreparationCoordinator()
    let firstProbe = PreparationProbe(releaseAt: 4)
    let firstResults = ResultProbe<Int>()
    let secondResults = ResultProbe<Int>()

    let first = Task {
        await coordinator.prepare(
            makeBlocks(count: 10),
            preparation: { block in
                await firstProbe.enterAndWait()
                return block.blockIndex
            },
            onResult: { value in await firstResults.append(value) }
        )
    }
    await firstProbe.waitUntilStarted(4)

    await coordinator.prepare(
        makeBlocks(count: 2, offset: 100),
        preparation: { block in block.blockIndex },
        onResult: { value in await secondResults.append(value) }
    )
    await firstProbe.release()
    await first.value
    #expect(await firstResults.values.isEmpty)
    let secondValues = await secondResults.values
    #expect(Set(secondValues) == Set([100, 101]))
    #expect(secondValues.count == 2)
}

@Test("completed block results are delivered incrementally")
func blockPreparationDeliversIncrementally() async {
    let coordinator = BlockPreparationCoordinator(laneCount: 2)
    let slowGate = ReleaseGate()
    let delivered = ResultProbe<Int>()

    let task = Task {
        await coordinator.prepare(
            makeBlocks(count: 3),
            preparation: { block in
                if block.blockIndex == 0 { await slowGate.wait() }
                return block.blockIndex
            },
            onResult: { value in await delivered.append(value) }
        )
    }

    await delivered.waitUntilCount(1)
    #expect(await delivered.values == [1])
    await slowGate.release()
    await task.value
    #expect(await delivered.values.count == 3)
}

@Test("retained completed payloads stay bounded by the lane count")
func blockPreparationRetainedResultsAreLaneBounded() async {
    let coordinator = BlockPreparationCoordinator()
    let retention = RetentionProbe(releaseAt: 4)
    let delivered = ResultProbe<Int>()
    let task = Task {
        await coordinator.prepare(
            makeBlocks(count: 30),
            preparation: { block in
                await retention.retain()
                return block.blockIndex
            },
            onResult: { value in
                await retention.waitForRelease()
                await retention.release()
                await delivered.append(value)
            }
        )
    }

    await retention.waitUntilRetained(4)
    #expect(await retention.peak <= 4)
    await retention.releaseAll()
    await task.value
    #expect(await retention.current == 0)
    #expect(await delivered.values.count == 30)
}

private func makeBlocks(count: Int, offset: Int = 0) -> [TranscriptBlock] {
    (0..<count).map { index in
        TranscriptBlock(
            messageID: "message",
            blockIndex: offset + index,
            kind: .paragraph,
            sourceRange: 0..<0,
            contentHash: UInt64(offset + index),
            language: nil
        )
    }
}

private actor PreparationProbe {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var calls = 0
    private(set) var shaped = 0
    private(set) var active = 0
    private(set) var maximumActive = 0

    init(releaseAt _: Int) {}

    func enterAndWait() async {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        resumeStartWaiters()
        if !released {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        active -= 1
    }

    func markShaped() {
        shaped += 1
    }

    func waitUntilStarted(_ count: Int) async {
        guard calls < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
            resumeStartWaiters()
        }
    }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func resumeStartWaiters() {
        let ready = startWaiters.filter { calls >= $0.0 }
        startWaiters.removeAll { calls >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private actor ReleaseGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor ResultProbe<Value: Sendable> {
    private(set) var values: [Value] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func append(_ value: Value) {
        values.append(value)
        let ready = waiters.filter { values.count >= $0.0 }
        waiters.removeAll { values.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func waitUntilCount(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private actor RetentionProbe {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var retainedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var current = 0
    private(set) var peak = 0

    init(releaseAt _: Int) {}

    func retain() {
        current += 1
        peak = max(peak, current)
        let ready = retainedWaiters.filter { current >= $0.0 }
        retainedWaiters.removeAll { current >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func waitUntilRetained(_ count: Int) async {
        guard current < count else { return }
        await withCheckedContinuation { retainedWaiters.append((count, $0)) }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() { current -= 1 }

    func releaseAll() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}
