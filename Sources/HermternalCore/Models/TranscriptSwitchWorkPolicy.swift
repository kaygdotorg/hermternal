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
    /// projection lookup, window resolution, row-height lookup, or prepared
    /// content lookup. It is intentionally not a synthetic wall-clock unit.
    /// The structural budget is the useful deterministic guard in CI.
    public static let maximumPureWorkUnits = 32

    public struct InitialPlan: Equatable, Sendable {
        public let window: TranscriptWindow
        public let workUnits: Int

        internal init(window: TranscriptWindow) {
            self.window = window
            // One warm projection lookup and one window-policy resolution, then
            // one height and one prepared-content lookup for each initial row.
            self.workUnits = 2 + window.range.count * 2
        }
    }

    /// Resolves the bounded recent tail and accounts for the operations a
    /// renderer must perform to activate that window from a warm projection.
    public static func initialPlan(totalMessageCount: Int) -> InitialPlan {
        InitialPlan(window: TranscriptWindowPolicy.initial(totalMessageCount: totalMessageCount))
    }
}
