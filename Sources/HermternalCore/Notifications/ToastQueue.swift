import Foundation

public typealias ToastInstant = SuspendingClock.Instant

public struct ToastID: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public enum ToastSeverity: Int, Comparable, Sendable, CaseIterable {
    case success = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ToastAction: Hashable, Sendable {
    public let label: String

    public init(label: String) { self.label = label }
}

public struct ToastMessage: Hashable, Sendable {
    public let id: ToastID
    public var title: String
    public var detail: String?
    public var severity: ToastSeverity
    public var action: ToastAction?
    public var isPersistent: Bool?

    public init(
        id: ToastID,
        title: String,
        detail: String? = nil,
        severity: ToastSeverity,
        action: ToastAction? = nil,
        isPersistent: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.severity = severity
        self.action = action
        self.isPersistent = isPersistent
    }
}

public enum ToastPauseReason: Hashable, Sendable {
    case hover
    case dragging
    case appInactive
    case windowHidden
    case visibility
}

public struct ToastPolicy: Hashable, Sendable {
    public var visibleLimit: Int
    public var duration: Duration
    public var actionsArePersistent: Bool

    public init(
        visibleLimit: Int = 3,
        duration: Duration = .seconds(30),
        actionsArePersistent: Bool = true
    ) {
        self.visibleLimit = visibleLimit
        self.duration = duration
        self.actionsArePersistent = actionsArePersistent
    }

    public static let `default` = ToastPolicy()
}

public struct ToastEntry: Hashable, Sendable, Identifiable {
    public var id: ToastID { message.id }
    public fileprivate(set) var message: ToastMessage
    public fileprivate(set) var insertedAt: ToastInstant
    public fileprivate(set) var deadline: ToastInstant?
    public fileprivate(set) var frozenRemaining: Duration?
    public fileprivate(set) var repeatCount: Int
    public fileprivate(set) var contentVersion: Int

    public var isPersistent: Bool {
        deadline == nil && frozenRemaining == nil
    }

    fileprivate init(
        message: ToastMessage,
        insertedAt: ToastInstant,
        deadline: ToastInstant?,
        frozenRemaining: Duration?,
        repeatCount: Int,
        contentVersion: Int
    ) {
        self.message = message
        self.insertedAt = insertedAt
        self.deadline = deadline
        self.frozenRemaining = frozenRemaining
        self.repeatCount = repeatCount
        self.contentVersion = contentVersion
    }
}

public enum ToastRemovalReason: Hashable, Sendable {
    case expired
    case dismissed
    case evicted
    case replacedByEscalation
}

public struct ToastRemoval: Hashable, Sendable {
    public let id: ToastID
    public let reason: ToastRemovalReason

    public init(id: ToastID, reason: ToastRemovalReason) {
        self.id = id
        self.reason = reason
    }
}

public struct ToastQueueEffects: Hashable, Sendable {
    public var inserted: ToastID?
    public var updated: ToastID?
    public var removed: [ToastRemoval]

    public init(inserted: ToastID? = nil, updated: ToastID? = nil, removed: [ToastRemoval] = []) {
        self.inserted = inserted
        self.updated = updated
        self.removed = removed
    }

    public var isEmpty: Bool {
        inserted == nil && updated == nil && removed.isEmpty
    }
}

public struct ToastQueue: Sendable, Equatable {
    public private(set) var entries: [ToastEntry] = []
    public private(set) var pauseReasons: Set<ToastPauseReason> = []
    public var isPaused: Bool { !pauseReasons.isEmpty }
    public let policy: ToastPolicy

    public init(policy: ToastPolicy = .default) {
        self.policy = policy
    }

    @discardableResult
    public mutating func post(_ message: ToastMessage, at now: ToastInstant) -> ToastQueueEffects {
        if let index = entries.firstIndex(where: { $0.id == message.id }) {
            let oldSeverity = entries[index].message.severity
            let repeatCount = entries[index].repeatCount + 1
            let contentVersion = entries[index].contentVersion + 1
            let escalated = message.severity > oldSeverity
            let persistent = isPersistent(message)
            let timing = timing(for: policy.duration, persistent: persistent, at: now)
            let replacement = ToastEntry(
                message: message,
                insertedAt: entries[index].insertedAt,
                deadline: timing.deadline,
                frozenRemaining: timing.frozenRemaining,
                repeatCount: repeatCount,
                contentVersion: contentVersion
            )

            if escalated {
                entries.remove(at: index)
                entries.insert(replacement, at: 0)
                return ToastQueueEffects(
                    inserted: message.id,
                    removed: [ToastRemoval(id: message.id, reason: .replacedByEscalation)]
                )
            }

            entries[index] = replacement
            return ToastQueueEffects(updated: message.id)
        }

        let persistent = isPersistent(message)
        let timing = timing(for: policy.duration, persistent: persistent, at: now)
        let entry = ToastEntry(
            message: message,
            insertedAt: now,
            deadline: timing.deadline,
            frozenRemaining: timing.frozenRemaining,
            repeatCount: 1,
            contentVersion: 1
        )
        entries.insert(entry, at: 0)
        var effects = ToastQueueEffects(inserted: message.id)
        evictIfNeeded(into: &effects)
        return effects
    }

    @discardableResult
    public mutating func dismiss(_ id: ToastID, at now: ToastInstant) -> ToastQueueEffects {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return ToastQueueEffects() }
        entries.remove(at: index)
        return ToastQueueEffects(removed: [ToastRemoval(id: id, reason: .dismissed)])
    }

    @discardableResult
    public mutating func dismissFront(at now: ToastInstant) -> ToastQueueEffects {
        guard let id = entries.first?.id else { return ToastQueueEffects() }
        return dismiss(id, at: now)
    }

    @discardableResult
    public mutating func dismissAll(at now: ToastInstant) -> ToastQueueEffects {
        guard !entries.isEmpty else { return ToastQueueEffects() }
        let removals = entries.map { ToastRemoval(id: $0.id, reason: .dismissed) }
        entries.removeAll(keepingCapacity: true)
        return ToastQueueEffects(removed: removals)
    }

    @discardableResult
    public mutating func tick(at now: ToastInstant) -> ToastQueueEffects {
        var effects = ToastQueueEffects()
        for entry in entries.reversed() where entry.deadline.map({ $0 <= now }) == true {
            effects.removed.append(ToastRemoval(id: entry.id, reason: .expired))
        }
        guard !effects.removed.isEmpty else { return effects }
        let removedIDs = Set(effects.removed.map(\.id))
        entries.removeAll { removedIDs.contains($0.id) }
        return effects
    }

    public mutating func setPaused(
        _ paused: Bool,
        for reason: ToastPauseReason,
        at now: ToastInstant
    ) {
        let wasPaused = isPaused
        if paused {
            pauseReasons.insert(reason)
        } else {
            pauseReasons.remove(reason)
        }
        guard wasPaused != isPaused else { return }

        if isPaused {
            for index in entries.indices {
                guard let deadline = entries[index].deadline else { continue }
                entries[index].frozenRemaining = max(deadline - now, .zero)
                entries[index].deadline = nil
            }
        } else {
            for index in entries.indices {
                guard let remaining = entries[index].frozenRemaining else { continue }
                entries[index].deadline = now + remaining
                entries[index].frozenRemaining = nil
            }
        }
    }

    public func nextDeadline() -> ToastInstant? {
        guard !isPaused else { return nil }
        return entries.compactMap(\.deadline).min()
    }

    private func isPersistent(_ message: ToastMessage) -> Bool {
        message.isPersistent == true
            || message.severity == .error
            || (policy.actionsArePersistent && message.action != nil)
    }

    private func timing(
        for duration: Duration,
        persistent: Bool,
        at now: ToastInstant
    ) -> (deadline: ToastInstant?, frozenRemaining: Duration?) {
        guard !persistent else { return (nil, nil) }
        return isPaused ? (nil, duration) : (now + duration, nil)
    }


    private mutating func evictIfNeeded(into effects: inout ToastQueueEffects) {
        let limit = max(0, policy.visibleLimit)
        while entries.count > limit {
            let index = entries.lastIndex(where: { !$0.isPersistent }) ?? entries.index(before: entries.endIndex)
            let removed = entries.remove(at: index)
            effects.removed.append(ToastRemoval(id: removed.id, reason: .evicted))
        }
    }
}

// MARK: - Swipe dismissal

/// What a released toast drag asks for.
public enum ToastSwipeOutcome: Hashable, Sendable {
    case dismiss
    case restore
}

/// One released toast drag, in points and monotonic wall-clock time.
///
/// `travel` and `projectedTravel` point toward the exit edge: a positive value
/// moves the card away, a negative value moves it back into the stack. The
/// view layer applies the sign, so this type never learns which edge it is.
public struct ToastSwipe: Hashable, Sendable {
    /// Distance the pointer covered, measured toward the exit edge.
    public var travel: Double

    /// Where the platform projects the drag to stop, measured the same way.
    public var projectedTravel: Double

    /// Time from the first drag update to the release.
    public var elapsed: Duration

    public init(travel: Double, projectedTravel: Double = 0, elapsed: Duration = .zero) {
        self.travel = travel
        self.projectedTravel = projectedTravel
        self.elapsed = elapsed
    }

    /// Mean speed over the whole drag, in points per millisecond.
    ///
    /// The threshold this feeds is an average, not the speed at release. A
    /// deliberate 300 pt drag over 3 s must restore, and its instantaneous
    /// speed is above the threshold for the whole drag. `max(_:1)` keeps a
    /// zero-length drag from dividing by zero.
    public var averageSpeed: Double {
        travel / max(elapsed.toastMilliseconds, 1)
    }
}

/// The numbers that decide a toast dismissal.
public struct ToastSwipeThresholds: Hashable, Sendable {
    /// Travel that dismisses on distance alone.
    public var distance: Double

    /// Projected travel that dismisses, so a flick needs no distance.
    public var projectedDistance: Double

    /// Mean speed that dismisses, in points per millisecond.
    public var averageSpeed: Double

    /// Travel below which speed cannot dismiss. A 2 pt twitch in 4 ms has a
    /// mean speed of 0.5 pt/ms, so speed alone needs a jitter guard.
    public var minimumTravelForSpeed: Double

    /// The value the card approaches when the drag goes the wrong way.
    public var resistanceLimit: Double

    public init(
        distance: Double = 40,
        projectedDistance: Double = 40,
        averageSpeed: Double = 0.11,
        minimumTravelForSpeed: Double = 12,
        resistanceLimit: Double = 36
    ) {
        self.distance = distance
        self.projectedDistance = projectedDistance
        self.averageSpeed = averageSpeed
        self.minimumTravelForSpeed = minimumTravelForSpeed
        self.resistanceLimit = resistanceLimit
    }

    public static let `default` = ToastSwipeThresholds()

    /// Damped translation for a drag that moves away from the exit edge.
    ///
    /// Monotonic and asymptotic at `resistanceLimit`, so the card never stops
    /// dead against an invisible wall. Travel toward the exit passes 1:1,
    /// because direct manipulation must track the pointer exactly.
    ///
    /// A positive `translation` moves away from the exit edge.
    public func resisted(_ translation: Double) -> Double {
        guard translation > 0 else { return translation }
        return resistanceLimit * (1 - 1 / (translation / resistanceLimit + 1))
    }
}

/// The dismissal decision for a released toast drag.
///
/// Pure, so the one part of the toast surface that needs no pixel is tested
/// without one. Order matters: distance first, then the platform's own
/// momentum projection, then mean speed behind the jitter guard.
public func toastSwipeOutcome(
    _ swipe: ToastSwipe,
    thresholds: ToastSwipeThresholds = .default
) -> ToastSwipeOutcome {
    guard swipe.travel > 0 else { return .restore }
    if swipe.travel >= thresholds.distance { return .dismiss }
    if swipe.projectedTravel >= thresholds.projectedDistance { return .dismiss }
    if swipe.travel >= thresholds.minimumTravelForSpeed,
       swipe.averageSpeed > thresholds.averageSpeed {
        return .dismiss
    }
    return .restore
}

private extension Duration {
    /// This duration in milliseconds.
    ///
    /// `Duration` exposes no millisecond accessor, and `components` avoids the
    /// overflow that scaling attoseconds in one integer would risk.
    var toastMilliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000
            + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}

// MARK: - Stack geometry

/// The stack arithmetic for the toast surface, in points.
///
/// It lives here, and not in the view, for two reasons: it is testable without
/// a window, and it is the single home for every number the stack uses. It
/// uses `Double` rather than `CGFloat` so this module keeps importing
/// `Foundation` alone; the view converts at the boundary.
public enum ToastStackGeometry {
    /// The visible sliver between two stacked cards. It equals the card corner
    /// radius, so the sliver equals the corner it reveals.
    public static let gap: Double = 14

    /// How much smaller each card behind the front card is drawn.
    public static let scaleStep: Double = 0.05

    /// The opacity step that replaces `scaleStep` under reduced motion, where
    /// depth must not be carried by a size change.
    public static let reducedOpacityStep: Double = 0.08

    /// Cards drawn at once. `ToastPolicy.visibleLimit` bounds the queue; this
    /// bounds the view as well, so a later policy change cannot make the view
    /// draw an unbounded stack.
    public static let renderedLimit = 3

    /// The height of a card that is not measured yet: the 44 pt minimum height
    /// plus 2 x 11 pt of vertical padding.
    public static let estimatedCardHeight: Double = 66

    /// Clearance a flung card needs beyond the stack so that its shadow
    /// (radius 14, offset y 8) also leaves the surface.
    public static let flingHeadroom: Double = 24

    /// Card width, and the total horizontal inset that keeps it off the
    /// window edges. The toast is deliberately narrower than the search
    /// panel: the two surfaces share only their vertical origin.
    public static let maximumWidth: Double = 360
    public static let horizontalInset: Double = 32

    /// The scale an arriving card grows from. Far from zero, because nothing
    /// appears from nothing.
    public static let enterScale: Double = 0.94

    /// Where an arriving card starts, and where a leaving card ends.
    public static let enterOffset: Double = -12
    public static let exitOffset: Double = -10

    /// Opacity a card loses at the dismissal distance under reduced motion,
    /// where the drag reports progress by colour instead of position.
    public static let dragFeedbackFade: Double = 0.4

    public static func width(in containerWidth: Double) -> Double {
        min(maximumWidth, max(0, containerWidth - horizontalInset))
    }

    /// Offset of a card in the collapsed stack: one gap for each card in
    /// front of it, which leaves exactly one sliver of each card visible.
    public static func collapsedOffset(depth: Int) -> Double {
        Double(depth) * gap
    }

    /// Offset of a card in the expanded stack: every preceding card's height
    /// plus a gap after each. It never includes the card's own height, which
    /// would drift the whole stack down by one card.
    public static func expandedOffset(depth: Int, heights: [Double]) -> Double {
        guard depth > 0 else { return 0 }
        let preceding = heights.prefix(depth)
        return preceding.reduce(0, +) + Double(preceding.count) * gap
    }

    public static func depthScale(depth: Int, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : 1 - Double(depth) * scaleStep
    }

    /// Opacity that carries depth when scale cannot.
    ///
    /// With motion allowed, scale and shadow carry depth and every card is
    /// fully opaque: fading a translucent surface would double-dip. Under
    /// reduced motion, opacity is the only depth cue left.
    public static func depthOpacity(depth: Int, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 - Double(depth) * reducedOpacityStep : 1
    }

    /// Height of the collapsed stack: the front card plus one gap for each
    /// card behind it, because the cards behind adopt the front height.
    public static func stackedHeight(of heights: [Double]) -> Double {
        guard let front = heights.first else { return 0 }
        return front + Double(heights.count - 1) * gap
    }

    /// Height of the expanded stack: every card plus the gaps between them.
    public static func expandedHeight(of heights: [Double]) -> Double {
        guard !heights.isEmpty else { return 0 }
        return heights.reduce(0, +) + Double(heights.count - 1) * gap
    }

    public static func regionHeight(of heights: [Double], expanded: Bool) -> Double {
        expanded ? expandedHeight(of: heights) : stackedHeight(of: heights)
    }

    /// Opacity that reports drag progress without moving the card, for
    /// reduced motion. A colour change, which reduced motion keeps.
    public static func dragFeedbackOpacity(
        travel: Double,
        thresholds: ToastSwipeThresholds = .default
    ) -> Double {
        1 - dragFeedbackFade * min(1, max(0, travel) / thresholds.distance)
    }

    /// The measured heights that are still in use.
    ///
    /// The view measures one height per card and keys it by toast id. Those
    /// ids are fresh UUIDs, so a store that is never pruned grows for the
    /// whole process lifetime. Returns the input untouched when there is
    /// nothing to drop, so a live measurement never rewrites the store.
    public static func pruned<Value>(
        _ heights: [ToastID: Value],
        keeping ids: some Sequence<ToastID>
    ) -> [ToastID: Value] {
        let live = Set(ids)
        guard heights.contains(where: { !live.contains($0.key) }) else { return heights }
        return heights.filter { live.contains($0.key) }
    }
}
