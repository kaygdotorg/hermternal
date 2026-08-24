/// The bounds of the transcript rows currently materialized by the chat view.
///
/// Bounds are half-open and refer to positions in the complete transcript. The
/// state contains no view or platform values, so it can also be used by other
/// transcript renderers.
public struct TranscriptWindowState: Equatable, Sendable {
    public let startIndex: Int
    public let endIndex: Int

    public init(startIndex: Int, endIndex: Int) {
        self.startIndex = startIndex
        self.endIndex = endIndex
    }
}

/// A normalized transcript window and its relationship to the transcript head.
public struct TranscriptWindow: Equatable, Sendable {
    public let range: Range<Int>
    public let hasMoreOlderMessages: Bool

    public init(range: Range<Int>, hasMoreOlderMessages: Bool) {
        self.range = range
        self.hasMoreOlderMessages = hasMoreOlderMessages
    }

    public var state: TranscriptWindowState {
        TranscriptWindowState(startIndex: range.lowerBound, endIndex: range.upperBound)
    }
}

/// Pure bounds policy for keeping transcript rendering work bounded.
public enum TranscriptWindowPolicy {
    /// The bounded first paint keeps session switches within one frame.
    public static let initialWindowSize = 12
    /// The complete recent tail shown after the first frame.
    public static let defaultWindowSize = 40
    /// The one-shot extension reaches the complete recent tail.
    public static let extensionStep = defaultWindowSize - initialWindowSize
    /// Older-row demand remains bounded after the recent tail is complete.
    public static let growthStep = 40

    /// Resolves a current state, or starts at the recent end when no state is
    /// supplied. Existing windows are never shrunk by this operation.
    public static func resolve(
        totalMessageCount: Int,
        requestedWindowSize: Int,
        currentState: TranscriptWindowState? = nil
    ) -> TranscriptWindow {
        let count = max(0, totalMessageCount)
        guard count > 0 else {
            return TranscriptWindow(range: 0..<0, hasMoreOlderMessages: false)
        }

        guard let currentState else {
            let size = max(1, requestedWindowSize)
            let start = max(0, count - size)
            return TranscriptWindow(
                range: start..<count,
                hasMoreOlderMessages: start > 0
            )
        }

        let start = min(max(0, currentState.startIndex), count)
        let end = min(max(start, currentState.endIndex), count)
        return TranscriptWindow(
            range: start..<end,
            hasMoreOlderMessages: start > 0
        )
    }

    /// Starts the bounded first paint at the recent end.
    public static func initial(
        totalMessageCount: Int,
        requestedWindowSize: Int = defaultWindowSize
    ) -> TranscriptWindow {
        resolve(
            totalMessageCount: totalMessageCount,
            requestedWindowSize: min(
                max(1, requestedWindowSize),
                initialWindowSize
            ),
            currentState: nil
        )
    }

    /// Starts a new recent window, deliberately discarding the prior state's
    /// bounds. Use this when the selected session changes.
    public static func reset(
        totalMessageCount: Int,
        requestedWindowSize: Int = defaultWindowSize
    ) -> TranscriptWindow {
        resolve(
            totalMessageCount: totalMessageCount,
            requestedWindowSize: requestedWindowSize,
            currentState: nil
        )
    }

    /// Prepends at most `growthBy` older rows while retaining every currently
    /// materialized row. The lower bound clamps exactly at transcript start.
    public static func grow(
        totalMessageCount: Int,
        requestedWindowSize: Int,
        currentState: TranscriptWindowState,
        growthBy: Int = growthStep
    ) -> TranscriptWindow {
        let current = resolve(
            totalMessageCount: totalMessageCount,
            requestedWindowSize: requestedWindowSize,
            currentState: currentState
        )
        guard !current.range.isEmpty else { return current }
        let step = max(1, growthBy)
        let start = max(0, current.range.lowerBound - step)
        return resolve(
            totalMessageCount: totalMessageCount,
            requestedWindowSize: requestedWindowSize,
            currentState: TranscriptWindowState(
                startIndex: start,
                endIndex: current.range.upperBound
            )
        )
    }

    /// Expands an existing window to include a valid target row. This never
    /// removes newer or older rows already visible, preserving target and
    /// route precedence even when the target predates the recent window.
    public static func including(
        targetIndex: Int,
        totalMessageCount: Int,
        requestedWindowSize: Int,
        currentState: TranscriptWindowState? = nil
    ) -> TranscriptWindow {
        let current = resolve(
            totalMessageCount: totalMessageCount,
            requestedWindowSize: requestedWindowSize,
            currentState: currentState
        )
        guard totalMessageCount > 0,
              (0..<totalMessageCount).contains(targetIndex)
        else { return current }
        guard !current.range.contains(targetIndex) else { return current }

        let expanded = TranscriptWindowState(
            startIndex: min(current.range.lowerBound, targetIndex),
            endIndex: max(current.range.upperBound, targetIndex + 1)
        )
        return resolve(
            totalMessageCount: totalMessageCount,
            requestedWindowSize: requestedWindowSize,
            currentState: expanded
        )
    }
}
