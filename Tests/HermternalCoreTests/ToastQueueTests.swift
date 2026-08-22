import Foundation
@testable import HermternalCore
import Testing

private let toastT0 = SuspendingClock.now
private func toastAt(_ seconds: Double) -> ToastInstant {
    toastT0.advanced(by: .seconds(seconds))
}

private func toast(
    _ id: String,
    _ title: String = "Toast",
    severity: ToastSeverity = .success,
    detail: String? = nil,
    action: ToastAction? = nil,
    persistent: Bool? = nil
) -> ToastMessage {
    ToastMessage(
        id: ToastID(id), title: title, detail: detail, severity: severity,
        action: action, isPersistent: persistent
    )
}

@Test("newest post occupies the front")
func newestPostOccupiesFront() {
    var queue = ToastQueue()
    _ = queue.post(toast("a"), at: toastAt(0))
    _ = queue.post(toast("b"), at: toastAt(0))
    #expect(queue.entries.map(\.id) == [ToastID("b"), ToastID("a")])
}

@Test("dismissing the front promotes the next")
func dismissingFrontPromotesNext() {
    var queue = ToastQueue()
    _ = queue.post(toast("a"), at: toastAt(0))
    _ = queue.post(toast("b"), at: toastAt(0))
    _ = queue.post(toast("c"), at: toastAt(0))
    let effects = queue.dismissFront(at: toastAt(1))
    #expect(queue.entries.map(\.id) == [ToastID("b"), ToastID("a")])
    #expect(effects.removed == [ToastRemoval(id: ToastID("c"), reason: .dismissed)])
}

@Test("same id replaces in place without reordering")
func sameIDReplacesInPlace() {
    var queue = ToastQueue()
    _ = queue.post(toast("a", "old"), at: toastAt(0))
    _ = queue.post(toast("b"), at: toastAt(0))
    let effects = queue.post(toast("a", "new"), at: toastAt(1))
    #expect(queue.entries.map(\.id) == [ToastID("b"), ToastID("a")])
    #expect(queue.entries.last?.message.title == "new")
    #expect(queue.entries.last?.repeatCount == 2)
    #expect(queue.entries.last?.contentVersion == 2)
    #expect(effects == ToastQueueEffects(updated: ToastID("a")))
}

@Test("replacement resets the deadline")
func replacementResetsDeadline() {
    var queue = ToastQueue(policy: ToastPolicy(duration: .seconds(4)))
    _ = queue.post(toast("a"), at: toastAt(0))
    _ = queue.post(toast("a", "again"), at: toastAt(3))
    #expect(queue.tick(at: toastAt(4.5)).isEmpty)
    let effects = queue.tick(at: toastAt(7.1))
    #expect(effects.removed == [ToastRemoval(id: ToastID("a"), reason: .expired)])
}

@Test("escalation moves the entry to the front")
func escalationMovesEntryToFront() {
    var queue = ToastQueue()
    _ = queue.post(toast("a", severity: .info), at: toastAt(0))
    _ = queue.post(toast("b", severity: .info), at: toastAt(0))
    let effects = queue.post(toast("a", severity: .error), at: toastAt(1))
    #expect(queue.entries.map(\.id) == [ToastID("a"), ToastID("b")])
    #expect(effects.inserted == ToastID("a"))
    #expect(effects.removed == [ToastRemoval(id: ToastID("a"), reason: .replacedByEscalation)])
    #expect(queue.entries.first?.repeatCount == 2)
}

@Test("same or lower severity does not reorder")
func sameOrLowerSeverityDoesNotReorder() {
    var queue = ToastQueue()
    _ = queue.post(toast("a", severity: .info), at: toastAt(0))
    _ = queue.post(toast("b", severity: .info), at: toastAt(0))
    _ = queue.post(toast("a", severity: .success), at: toastAt(1))
    #expect(queue.entries.map(\.id) == [ToastID("b"), ToastID("a")])
}

@Test("expiry is inclusive at the deadline")
func expiryIsInclusiveAtDeadline() {
    var queue = ToastQueue(policy: ToastPolicy(duration: .seconds(4)))
    _ = queue.post(toast("a"), at: toastAt(0))
    #expect(queue.tick(at: toastAt(3.999)).isEmpty)
    #expect(queue.tick(at: toastAt(4.0)).removed == [
        ToastRemoval(id: ToastID("a"), reason: .expired)
    ])
}

@Test("every non-persistent severity uses the 30 second duration")
func everyNonPersistentSeverityUsesThirtySecondDuration() {
    for severity in [ToastSeverity.success, .info, .warning] {
        var queue = ToastQueue()
        _ = queue.post(toast("id-\(severity)", severity: severity), at: toastAt(0))
        #expect(queue.tick(at: toastAt(29.999)).isEmpty)
        #expect(queue.tick(at: toastAt(30)).removed.count == 1)
    }
}

@Test("errors never expire")
func errorsNeverExpire() {
    var queue = ToastQueue()
    _ = queue.post(toast("error", severity: .error), at: toastAt(0))
    #expect(queue.tick(at: toastAt(3_600)).isEmpty)
    #expect(queue.entries.first?.isPersistent == true)
    #expect(queue.nextDeadline() == nil)
}

@Test("custom duration controls non-persistent expiry")
func customDurationControlsNonPersistentExpiry() {
    var queue = ToastQueue(policy: ToastPolicy(duration: .seconds(12)))
    _ = queue.post(toast("warning", severity: .warning), at: toastAt(0))
    #expect(queue.tick(at: toastAt(11.9)).isEmpty)
    #expect(queue.tick(at: toastAt(12)).removed == [
        ToastRemoval(id: ToastID("warning"), reason: .expired)
    ])
}

@Test("pause banks the exact remaining time")
func pauseBanksExactRemainingTime() {
    var queue = ToastQueue(policy: ToastPolicy(duration: .seconds(4)))
    _ = queue.post(toast("a"), at: toastAt(0))
    queue.setPaused(true, for: .visibility, at: toastAt(1))
    #expect(queue.tick(at: toastAt(99)).isEmpty)
    queue.setPaused(false, for: .visibility, at: toastAt(50))
    #expect(queue.tick(at: toastAt(52.9)).isEmpty)
    #expect(queue.tick(at: toastAt(53)).removed.count == 1)
}

@Test("pause is idempotent")
func pauseIsIdempotent() {
    var queue = ToastQueue(policy: ToastPolicy(duration: .seconds(4)))
    _ = queue.post(toast("a"), at: toastAt(0))
    queue.setPaused(true, for: .visibility, at: toastAt(1))
    queue.setPaused(true, for: .visibility, at: toastAt(5))
    queue.setPaused(false, for: .visibility, at: toastAt(10))
    #expect(queue.tick(at: toastAt(12.999)).isEmpty)
    #expect(queue.tick(at: toastAt(13)).removed.count == 1)
}

@Test("next deadline is nil while paused and earliest while running")
func nextDeadlinePauseAndEarliest() {
    var queue = ToastQueue()
    _ = queue.post(toast("long", severity: .warning), at: toastAt(0))
    _ = queue.post(toast("short"), at: toastAt(0))
    #expect(queue.nextDeadline() == toastAt(30))
    queue.setPaused(true, for: .visibility, at: toastAt(1))
    #expect(queue.nextDeadline() == nil)
}

@Test("pause does not disturb persistent entries")
func pauseLeavesPersistentUntouched() {
    var queue = ToastQueue()
    _ = queue.post(toast("persistent", persistent: true), at: toastAt(0))
    _ = queue.post(toast("normal"), at: toastAt(0))
    queue.setPaused(true, for: .visibility, at: toastAt(1))
    queue.setPaused(false, for: .visibility, at: toastAt(50))
    let persistent = queue.entries.first { $0.id == ToastID("persistent") }
    #expect(persistent?.deadline == nil)
    #expect(persistent?.frozenRemaining == nil)
}

@Test("a fourth post evicts the oldest dismissible")
func fourthPostEvictsOldestDismissible() {
    var queue = ToastQueue()
    for id in ["a", "b", "c"] { _ = queue.post(toast(id), at: toastAt(0)) }
    let effects = queue.post(toast("d"), at: toastAt(1))
    #expect(queue.entries.map(\.id) == [ToastID("d"), ToastID("c"), ToastID("b")])
    #expect(effects.removed == [ToastRemoval(id: ToastID("a"), reason: .evicted)])
}

@Test("eviction skips persistent entries")
func evictionSkipsPersistentEntries() {
    var queue = ToastQueue()
    _ = queue.post(toast("a", persistent: true), at: toastAt(0))
    _ = queue.post(toast("b"), at: toastAt(0))
    _ = queue.post(toast("c"), at: toastAt(0))
    let effects = queue.post(toast("d"), at: toastAt(1))
    #expect(queue.entries.map(\.id) == [ToastID("d"), ToastID("c"), ToastID("a")])
    #expect(effects.removed == [ToastRemoval(id: ToastID("b"), reason: .evicted)])
}

@Test("an all-persistent stack still evicts the oldest")
func allPersistentStackEvictsOldest() {
    var queue = ToastQueue()
    for id in ["a", "b", "c"] { _ = queue.post(toast(id, persistent: true), at: toastAt(0)) }
    let effects = queue.post(toast("d", persistent: true), at: toastAt(1))
    #expect(queue.entries.map(\.id) == [ToastID("d"), ToastID("c"), ToastID("b")])
    #expect(effects.removed == [ToastRemoval(id: ToastID("a"), reason: .evicted)])
}


@Test("a suppressed toast keeps its remaining visible time")
func suppressedToastKeepsRemainingVisibleTime() {
    var queue = ToastQueue()
    _ = queue.post(toast("a"), at: toastAt(0))
    queue.setPaused(true, for: .visibility, at: toastAt(1))
    // One second was actually seen, so 29 remain — not the full 30.
    #expect(queue.entries.first?.frozenRemaining == .seconds(29))
    // Long past the original 30s wall-clock deadline, and still alive:
    // hidden time is not visible time.
    #expect(queue.tick(at: toastAt(100)).isEmpty)
    queue.setPaused(false, for: .visibility, at: toastAt(100))
    #expect(queue.tick(at: toastAt(128.999)).isEmpty)
    #expect(queue.tick(at: toastAt(129)).removed == [
        ToastRemoval(id: ToastID("a"), reason: .expired)
    ])
}

@Test("overlapping pause reasons resume exactly once")
func overlappingPauseReasonsResumeExactlyOnce() {
    var queue = ToastQueue(policy: ToastPolicy(duration: .seconds(4)))
    _ = queue.post(toast("a"), at: toastAt(0))
    queue.setPaused(true, for: .visibility, at: toastAt(1))
    queue.setPaused(true, for: .hover, at: toastAt(2))
    queue.setPaused(false, for: .visibility, at: toastAt(50))
    #expect(queue.isPaused)
    #expect(queue.tick(at: toastAt(52.999)).isEmpty)
    queue.setPaused(false, for: .hover, at: toastAt(52))
    #expect(queue.tick(at: toastAt(54.999)).isEmpty)
    #expect(queue.tick(at: toastAt(55)).removed.count == 1)
}

@Test("thirty seconds of visible time expires across suppressions")
func thirtySecondsOfVisibleTimeExpiresAcrossSuppressions() {
    var queue = ToastQueue()
    _ = queue.post(toast("a"), at: toastAt(0))
    queue.setPaused(true, for: .visibility, at: toastAt(10))
    queue.setPaused(false, for: .visibility, at: toastAt(20))
    queue.setPaused(true, for: .visibility, at: toastAt(25))
    queue.setPaused(false, for: .visibility, at: toastAt(100))
    #expect(queue.tick(at: toastAt(114.999)).isEmpty)
    #expect(queue.tick(at: toastAt(115)).removed.count == 1)
}

@Test("ordering is preserved across suppression")
func orderingIsPreservedAcrossSuppression() {
    var queue = ToastQueue()
    queue.setPaused(true, for: .visibility, at: toastAt(0))
    _ = queue.post(toast("a"), at: toastAt(0))
    _ = queue.post(toast("b"), at: toastAt(1))
    _ = queue.post(toast("c"), at: toastAt(2))
    #expect(queue.entries.map(\.id) == [ToastID("c"), ToastID("b"), ToastID("a")])
    queue.setPaused(false, for: .visibility, at: toastAt(100))
    #expect(queue.entries.map(\.id) == [ToastID("c"), ToastID("b"), ToastID("a")])
}

@Test("dismissing an unknown id is a no-op")
func dismissingUnknownIsNoOp() {
    var queue = ToastQueue()
    _ = queue.post(toast("a"), at: toastAt(0))
    let effects = queue.dismiss(ToastID("missing"), at: toastAt(1))
    #expect(effects.isEmpty)
    #expect(queue.entries.count == 1)
}

@Test("every removal is reported exactly once")
func everyRemovalReportedExactlyOnce() {
    var queue = ToastQueue(policy: ToastPolicy(duration: .seconds(4)))
    _ = queue.post(toast("expired"), at: toastAt(0))
    _ = queue.post(toast("persistent-a", persistent: true), at: toastAt(0))
    _ = queue.post(toast("persistent-b", persistent: true), at: toastAt(0))
    let expiry = queue.tick(at: toastAt(4))
    _ = queue.post(toast("eviction-a"), at: toastAt(5))
    let eviction = queue.post(toast("eviction-b"), at: toastAt(5))
    let escalation = queue.post(toast("persistent-a", severity: .error), at: toastAt(5))
    let removals = expiry.removed + eviction.removed + escalation.removed
    #expect(removals.count == 3)
    #expect(Set(removals.map(\.id)).count == 3)
    #expect(Set(removals.map(\.reason)) == [.expired, .evicted, .replacedByEscalation])
}
