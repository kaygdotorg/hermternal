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
