/// Deterministic bounds for the pure work performed when a warm transcript is
/// selected. The plan contains no view, window-server, or timing state.
public enum TranscriptSwitchWorkPolicy {
    /// The frame target used by the transcript renderer and performance budget.
    public static let frameTargetMilliseconds = 16

    /// One quarter of the frame remains available for input, AppKit scheduling,
    /// compositing, and unrelated main-actor work. The contract therefore owns
    /// at most three quarters of the frame rather than flattering itself with
    /// the entire 16 ms budget.
    public static let reservedFrameHeadroomMilliseconds = 4
    public static let pureWorkBudgetMilliseconds =
        frameTargetMilliseconds - reservedFrameHeadroomMilliseconds

    /// A work unit is one bounded, synchronous operation in the switch path:
    /// projection lookup, initial-publication range resolution, row-height
    /// lookup, or prepared-content lookup. It is intentionally not a
    /// synthetic wall-clock unit. The structural budget is the useful
    /// deterministic guard in CI.
    public static let maximumPureWorkUnits = 32

    public struct InitialPlan: Equatable, Sendable {
        public let messageRange: Range<Int>
        public let workUnits: Int

        internal init(totalMessageCount: Int) {
            let count = max(0, totalMessageCount)
            let start = max(0, count - TranscriptPublicationPolicy.initialMessageCount)
            self.messageRange = start..<count
            // One warm projection lookup and one initial-publication range
            // resolution, then one height and one prepared-content lookup for
            // each synchronously published message.
            self.workUnits = 2 + messageRange.count * 2
        }
    }

    /// Resolves the bounded recent tail and accounts for the operations a
    /// renderer performs to activate that publication from a warm projection.
    public static func initialPlan(totalMessageCount: Int) -> InitialPlan {
        InitialPlan(totalMessageCount: totalMessageCount)
    }

    /// Returns whether a repeated request can reuse an in-flight opener.
    ///
    /// Reuse is limited to the interval before the opener publishes its first
    /// useful frame. A repeated request after publication must keep reopen
    /// semantics for the selected row.
    public static func shouldCoalescePendingOpen(
        sessionID: String,
        activeSessionID: String?,
        hasPublishedFirstFrame: Bool
    ) -> Bool {
        !hasPublishedFirstFrame
            && activeSessionID == sessionID
    }

    /// Repeat arrow events defer expensive opening until key-up.
    public static func shouldDeferNavigationOpen(isNavigationRepeat: Bool) -> Bool {
        isNavigationRepeat
    }
}
