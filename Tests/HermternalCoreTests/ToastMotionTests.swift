import Foundation
@testable import HermternalCore
import Testing

// The toast surface is a view, but its two decisions are not: whether a
// released drag dismisses, and where each card sits. Both live in Core as pure
// functions, so both are tested here without a pixel and without a window.

private let toastMotionT0 = SuspendingClock.now

private func toastSwipe(
    travel: Double,
    projected: Double = 0,
    elapsed: Duration = .zero
) -> ToastSwipe {
    ToastSwipe(travel: travel, projectedTravel: projected, elapsed: elapsed)
}

private func toastIsClose(_ value: Double, _ expected: Double) -> Bool {
    abs(value - expected) < 1e-9
}

private let toastMixedHeights: [Double] = [70, 96, 52]

// MARK: - Swipe dismissal

@Test("the swipe distance threshold is inclusive")
func toastSwipeDistanceThresholdIsInclusive() {
    #expect(toastSwipeOutcome(toastSwipe(travel: 40, elapsed: .seconds(5))) == .dismiss)
}

@Test("just under the swipe distance restores")
func toastSwipeJustUnderDistanceRestores() {
    #expect(toastSwipeOutcome(toastSwipe(travel: 39.9, elapsed: .seconds(5))) == .restore)
}

@Test("a quick flick dismisses on speed alone")
func toastSwipeQuickFlickDismisses() {
    let flick = toastSwipe(travel: 15, elapsed: .milliseconds(100))
    #expect(toastIsClose(flick.averageSpeed, 0.15))
    #expect(toastSwipeOutcome(flick) == .dismiss)
}

@Test("a slow long drag below the distance restores")
func toastSwipeSlowLongDragRestores() {
    // The threshold is a mean over the whole drag, not the speed at release:
    // a deliberate drag is slow on average however fast it is at any instant.
    let deliberate = toastSwipe(travel: 30, elapsed: .seconds(3))
    #expect(toastIsClose(deliberate.averageSpeed, 0.01))
    #expect(toastSwipeOutcome(deliberate) == .restore)
}

@Test("speed cannot dismiss below the minimum travel")
func toastSwipeJitterGuardHolds() {
    let twitch = toastSwipe(travel: 11, elapsed: .milliseconds(10))
    #expect(toastIsClose(twitch.averageSpeed, 1.1))
    #expect(toastSwipeOutcome(twitch) == .restore)
}

@Test("the swipe speed threshold is exclusive")
func toastSwipeSpeedThresholdIsExclusive() {
    let exact = toastSwipe(travel: 11, elapsed: .milliseconds(100))
    #expect(toastIsClose(exact.averageSpeed, ToastSwipeThresholds.default.averageSpeed))
    #expect(toastSwipeOutcome(exact) == .restore)
}

@Test("just past the swipe speed threshold dismisses")
func toastSwipeJustPastSpeedThresholdDismisses() {
    #expect(toastSwipeOutcome(toastSwipe(travel: 12, elapsed: .milliseconds(100))) == .dismiss)
}

@Test("projection dismisses a short fast drag")
func toastSwipeProjectionDismisses() {
    #expect(
        toastSwipeOutcome(toastSwipe(travel: 10, projected: 60, elapsed: .seconds(3))) == .dismiss
    )
}

@Test("a drag away from the exit never dismisses")
func toastSwipeWrongDirectionRestores() {
    let wrongWay = toastSwipe(travel: -80, projected: -120, elapsed: .milliseconds(200))
    #expect(toastSwipeOutcome(wrongWay) == .restore)
}

@Test("zero elapsed time does not trap")
func toastSwipeZeroElapsedDismissesByDistance() {
    #expect(toastSwipeOutcome(toastSwipe(travel: 50, elapsed: .zero)) == .dismiss)
}

@Test("zero elapsed time below the minimum travel restores")
func toastSwipeZeroElapsedBelowMinimumRestores() {
    #expect(toastSwipeOutcome(toastSwipe(travel: 5, elapsed: .zero)) == .restore)
}

@Test("resistance is monotonic and never reaches the limit")
func toastSwipeResistanceIsAsymptotic() {
    let thresholds = ToastSwipeThresholds.default
    #expect(thresholds.resisted(0) == 0)
    var previous = 0.0
    var translation = 0.5
    while translation <= 400 {
        let resisted = thresholds.resisted(translation)
        #expect(resisted > previous)
        #expect(resisted < thresholds.resistanceLimit)
        previous = resisted
        translation += 0.5
    }
}

@Test("resistance leaves the dismiss direction untouched")
func toastSwipeResistanceSparesTheExitDirection() {
    // Direct manipulation toward the exit must track the pointer exactly.
    #expect(ToastSwipeThresholds.default.resisted(-50) == -50)
}

// MARK: - Stack geometry

@Test("collapsed offsets are gap multiples")
func toastCollapsedOffsetsAreGapMultiples() {
    #expect(ToastStackGeometry.collapsedOffset(depth: 0) == 0)
    #expect(ToastStackGeometry.collapsedOffset(depth: 1) == 14)
    #expect(ToastStackGeometry.collapsedOffset(depth: 2) == 28)
}

@Test("the expanded offset sums preceding heights and gaps")
func toastExpandedOffsetSumsPrecedingHeights() {
    #expect(ToastStackGeometry.expandedOffset(depth: 0, heights: toastMixedHeights) == 0)
    #expect(ToastStackGeometry.expandedOffset(depth: 1, heights: toastMixedHeights) == 84)
    #expect(ToastStackGeometry.expandedOffset(depth: 2, heights: toastMixedHeights) == 194)
}

@Test("the expanded offset ignores the card's own height")
func toastExpandedOffsetIgnoresOwnHeight() {
    // An offset that included the card's own height would drift the whole
    // stack down by one card.
    #expect(
        ToastStackGeometry.expandedOffset(depth: 2, heights: [70, 96, 999])
            == ToastStackGeometry.expandedOffset(depth: 2, heights: toastMixedHeights)
    )
}

@Test("the depth scale steps by five percent")
func toastDepthScaleStepsByFivePercent() {
    #expect(ToastStackGeometry.depthScale(depth: 0, reduceMotion: false) == 1)
    #expect(toastIsClose(ToastStackGeometry.depthScale(depth: 1, reduceMotion: false), 0.95))
    #expect(toastIsClose(ToastStackGeometry.depthScale(depth: 2, reduceMotion: false), 0.90))
}

@Test("reduced motion substitutes opacity for scale")
func toastReducedMotionSubstitutesOpacityForScale() {
    for depth in 0...2 {
        #expect(ToastStackGeometry.depthScale(depth: depth, reduceMotion: true) == 1)
        #expect(ToastStackGeometry.depthOpacity(depth: depth, reduceMotion: false) == 1)
    }
    #expect(ToastStackGeometry.depthOpacity(depth: 0, reduceMotion: true) == 1)
    #expect(toastIsClose(ToastStackGeometry.depthOpacity(depth: 1, reduceMotion: true), 0.92))
    #expect(toastIsClose(ToastStackGeometry.depthOpacity(depth: 2, reduceMotion: true), 0.84))
}

@Test("reduced motion still produces a configuration that changes opacity")
func toastReducedMotionStillChangesOpacity() {
    // Reduced motion drops the positional part of the drag and keeps a colour
    // change, so the card must still report progress by fading.
    #expect(ToastStackGeometry.dragFeedbackOpacity(travel: 0) == 1)
    #expect(toastIsClose(ToastStackGeometry.dragFeedbackOpacity(travel: 20), 0.8))
    #expect(toastIsClose(ToastStackGeometry.dragFeedbackOpacity(travel: 40), 0.6))
    #expect(toastIsClose(ToastStackGeometry.dragFeedbackOpacity(travel: 400), 0.6))
    #expect(ToastStackGeometry.dragFeedbackOpacity(travel: -50) == 1)
}

@Test("the stacked region is the front height plus the gaps")
func toastStackedRegionIsFrontHeightPlusGaps() {
    #expect(ToastStackGeometry.stackedHeight(of: toastMixedHeights) == 98)
    #expect(ToastStackGeometry.regionHeight(of: toastMixedHeights, expanded: false) == 98)
}

@Test("the expanded region is every height plus the gaps")
func toastExpandedRegionIsEveryHeightPlusGaps() {
    #expect(ToastStackGeometry.expandedHeight(of: toastMixedHeights) == 246)
    #expect(ToastStackGeometry.regionHeight(of: toastMixedHeights, expanded: true) == 246)
}

@Test("a single toast has no gap contribution")
func toastSingleToastHasNoGap() {
    #expect(ToastStackGeometry.stackedHeight(of: [70]) == 70)
    #expect(ToastStackGeometry.expandedHeight(of: [70]) == 70)
    #expect(ToastStackGeometry.expandedOffset(depth: 0, heights: [70]) == 0)
}

@Test("an empty stack has zero region height")
func toastEmptyStackHasZeroHeight() {
    #expect(ToastStackGeometry.stackedHeight(of: []) == 0)
    #expect(ToastStackGeometry.expandedHeight(of: []) == 0)
    #expect(ToastStackGeometry.expandedOffset(depth: 2, heights: []) == 0)
}

@Test("the toast width stays narrower than the window and never goes negative")
func toastWidthClampsToTheContainer() {
    #expect(ToastStackGeometry.width(in: 1_200) == 360)
    #expect(ToastStackGeometry.width(in: 300) == 268)
    #expect(ToastStackGeometry.width(in: 0) == 0)
}

// MARK: - Height store

@Test("pruning drops the heights of entries that left")
func toastPruningDropsAbsentKeys() {
    let a = ToastID("a")
    let b = ToastID("b")
    let heights: [ToastID: Double] = [a: 70, b: 96]
    #expect(ToastStackGeometry.pruned(heights, keeping: [a, b]) == heights)
    #expect(ToastStackGeometry.pruned(heights, keeping: [a]) == [a: 70])
    #expect(ToastStackGeometry.pruned(heights, keeping: [ToastID]()).isEmpty)
}

@Test("the height store cannot grow beyond the visible stack")
func toastHeightStoreCannotGrowWithoutBound() {
    // Every toast id here is distinct, which is what `ToastID.unique()`
    // produces at run time. A store that is never pruned would end at 1000.
    var queue = ToastQueue(policy: ToastPolicy(visibleLimit: 3))
    var heights: [ToastID: Double] = [:]
    var peak = 0
    for index in 0 ..< 1_000 {
        let id = ToastID("toast-\(index)")
        _ = queue.post(
            ToastMessage(id: id, title: "Toast", severity: .success),
            at: toastMotionT0
        )
        heights[id] = ToastStackGeometry.estimatedCardHeight
        heights = ToastStackGeometry.pruned(heights, keeping: queue.entries.lazy.map(\.id))
        peak = max(peak, heights.count)
    }
    #expect(peak == 3)
    #expect(heights.count == queue.entries.count)
}
