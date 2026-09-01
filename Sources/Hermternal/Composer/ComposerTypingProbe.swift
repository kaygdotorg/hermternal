import Foundation

/// Counts and times one typing pass through the composer.
///
/// Tests enable the probe for one composer, type characters, and read the
/// snapshot. Production keeps the probe off, so a keystroke pays one boolean
/// check. Parallel tests create other composers in the same process; those
/// composers do not write into this snapshot, because every note names the
/// composer it came from.
@MainActor
enum ComposerTypingProbe {
    struct Snapshot: Equatable, Sendable {
        var keystrokes = 0
        var sizeThatFitsCount = 0
        var sizeThatFitsNanos: UInt64 = 0
        var synchronizeColumnCount = 0
        var synchronizeColumnAssertCount = 0
        var synchronizeColumnNanos: UInt64 = 0
        var intrinsicInvalidationCount = 0
        var heightChangeCount = 0
        var heightChangeNanos: UInt64 = 0
        var composerViewUpdateCount = 0
        var composerViewUpdateNanos: UInt64 = 0
        var routeUpdateCount = 0
        var prefetchCount = 0
        var requestInventoryCount = 0
        var caretScrollCount = 0
    }

    private static var data = Snapshot()
    private static var owner: ObjectIdentifier?
    static var isEnabled = false

    static var snapshot: Snapshot { data }

    static func begin(owner: AnyObject) {
        data = Snapshot()
        self.owner = ObjectIdentifier(owner)
        isEnabled = true
    }

    @discardableResult
    static func finish() -> Snapshot {
        isEnabled = false
        owner = nil
        return data
    }

    static func isRecording(_ candidate: AnyObject) -> Bool {
        guard isEnabled else { return false }
        return owner == ObjectIdentifier(candidate)
    }

    static func isRecording(_ candidate: ObjectIdentifier?) -> Bool {
        guard isEnabled else { return false }
        return candidate != nil && candidate == owner
    }

    static func noteKeystroke(from candidate: AnyObject) {
        guard isRecording(candidate) else { return }
        data.keystrokes += 1
    }

    static func noteSizeThatFits(from candidate: ObjectIdentifier?, nanoseconds: UInt64) {
        guard isRecording(candidate) else { return }
        data.sizeThatFitsCount += 1
        data.sizeThatFitsNanos += nanoseconds
    }

    static func noteSynchronizeColumn(
        from candidate: ObjectIdentifier?,
        asserted: Bool,
        nanoseconds: UInt64
    ) {
        guard isRecording(candidate) else { return }
        data.synchronizeColumnCount += 1
        if asserted { data.synchronizeColumnAssertCount += 1 }
        data.synchronizeColumnNanos += nanoseconds
    }

    static func noteIntrinsicInvalidation(from candidate: ObjectIdentifier?) {
        guard isRecording(candidate) else { return }
        data.intrinsicInvalidationCount += 1
    }

    static func noteHeightChange(from candidate: ObjectIdentifier?, nanoseconds: UInt64) {
        guard isRecording(candidate) else { return }
        data.heightChangeCount += 1
        data.heightChangeNanos += nanoseconds
    }

    static func noteComposerViewUpdate(from candidate: AnyObject, nanoseconds: UInt64 = 0) {
        guard isRecording(candidate) else { return }
        data.composerViewUpdateCount += 1
        data.composerViewUpdateNanos += nanoseconds
    }

    static func noteRouteUpdate(from candidate: AnyObject) {
        guard isRecording(candidate) else { return }
        data.routeUpdateCount += 1
    }

    static func notePrefetch(from candidate: AnyObject) {
        guard isRecording(candidate) else { return }
        data.prefetchCount += 1
    }

    static func noteRequestInventory(from candidate: AnyObject) {
        guard isRecording(candidate) else { return }
        data.requestInventoryCount += 1
    }

    static func noteCaretScroll(from candidate: ObjectIdentifier?) {
        guard isRecording(candidate) else { return }
        data.caretScrollCount += 1
    }

    /// Writes one aggregate line. The line holds counts and times only.
    static func log(_ label: String) {
        let snap = data
        print(
            "COMPOSER_TYPING_PROBE label=\(label)"
                + " keystrokes=\(snap.keystrokes)"
                + " sizeThatFits=\(snap.sizeThatFitsCount)"
                + " sizeThatFitsNs=\(snap.sizeThatFitsNanos)"
                + " synchronizeColumn=\(snap.synchronizeColumnCount)"
                + " synchronizeAssert=\(snap.synchronizeColumnAssertCount)"
                + " synchronizeNs=\(snap.synchronizeColumnNanos)"
                + " intrinsicInvalidate=\(snap.intrinsicInvalidationCount)"
                + " heightChange=\(snap.heightChangeCount)"
                + " heightChangeNs=\(snap.heightChangeNanos)"
                + " composerViewUpdate=\(snap.composerViewUpdateCount)"
                + " composerViewUpdateNs=\(snap.composerViewUpdateNanos)"
                + " routeUpdate=\(snap.routeUpdateCount)"
                + " prefetch=\(snap.prefetchCount)"
                + " requestInventory=\(snap.requestInventoryCount)"
                + " caretScroll=\(snap.caretScrollCount)"
        )
    }
}
