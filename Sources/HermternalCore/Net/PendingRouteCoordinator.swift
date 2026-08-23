import Foundation

/// Owns one external destination while authentication and session discovery settle.
///
/// A destination is authoritative only when the app is ready and the complete
/// session list is available. Every route receives a generation so a newer route
/// can supersede work that started for an older route.
public struct PendingRouteCoordinator: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case signedOut
        case connecting
        case ready
        case failed
    }

    public enum Decision: Equatable, Sendable {
        case queued(generation: Int)
        case open(destination: MessageDeepLink.Destination, generation: Int)
    }

    private struct Pending: Equatable, Sendable {
        let destination: MessageDeepLink.Destination
        let generation: Int
    }

    private var generation = 0
    private var pending: Pending?

    public init() {}

    public var pendingDestination: MessageDeepLink.Destination? {
        pending?.destination
    }

    public var currentGeneration: Int { generation }

    /// Routes a destination immediately only after complete session discovery.
    public mutating func route(
        _ destination: MessageDeepLink.Destination,
        phase: Phase,
        sessionsLoadedCompletely: Bool
    ) -> Decision {
        generation &+= 1
        let routeGeneration = generation
        guard phase == .ready, sessionsLoadedCompletely else {
            pending = Pending(destination: destination, generation: routeGeneration)
            return .queued(generation: routeGeneration)
        }

        pending = nil
        return .open(destination: destination, generation: routeGeneration)
    }

    /// Completes one authoritative session load and consumes the pending route.
    public mutating func sessionsLoadedCompletely(phase: Phase) -> Decision? {
        guard phase == .ready, let pending else { return nil }
        self.pending = nil
        return .open(destination: pending.destination, generation: pending.generation)
    }

    /// Invalidates a pending external route when the user starts another open.
    public mutating func clearPending() {
        pending = nil
        generation &+= 1
    }

    public func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation
    }
}
