import Foundation
import HermternalCore
import Testing

private let chatDestination = MessageDeepLink.Destination.chat(sessionID: "chat-1")
private let messageDestination = MessageDeepLink.Destination.message(
    MessageLocation(sessionID: "chat-2", messageID: ServerMessageID(rawValue: 7))
)

@Test("ready complete routes immediately")
func pendingRouteReadyCompleteOpensImmediately() {
    var coordinator = PendingRouteCoordinator()

    let decision = coordinator.route(
        chatDestination,
        phase: .ready,
        sessionsLoadedCompletely: true
    )

    #expect(decision == .open(destination: chatDestination, generation: 1))
    #expect(coordinator.pendingDestination == nil)
}

@Test("cold routes queue until complete session discovery")
func pendingRouteColdLaunchQueues() {
    var coordinator = PendingRouteCoordinator()

    let decision = coordinator.route(
        messageDestination,
        phase: .signedOut,
        sessionsLoadedCompletely: false
    )

    #expect(decision == .queued(generation: 1))
    #expect(coordinator.pendingDestination == messageDestination)
    #expect(coordinator.sessionsLoadedCompletely(phase: .signedOut) == nil)
}

@Test("last queued route supersedes the older route")
func pendingRouteLastWins() throws {
    var coordinator = PendingRouteCoordinator()
    _ = coordinator.route(chatDestination, phase: .connecting, sessionsLoadedCompletely: false)
    let latest = coordinator.route(
        messageDestination,
        phase: .ready,
        sessionsLoadedCompletely: false
    )

    #expect(latest == .queued(generation: 2))
    let drainedResult = coordinator.sessionsLoadedCompletely(phase: .ready)
    let drained = try #require(drainedResult)
    #expect(drained == .open(destination: messageDestination, generation: 2))
    #expect(coordinator.sessionsLoadedCompletely(phase: .ready) == nil)
}

@Test("partial and failed loads preserve the pending route")
func pendingRoutePartialOrFailedLoadHolds() throws {
    var coordinator = PendingRouteCoordinator()
    _ = coordinator.route(chatDestination, phase: .connecting, sessionsLoadedCompletely: false)

    // Partial and failed requests do not call sessionsLoadedCompletely().
    #expect(coordinator.pendingDestination == chatDestination)

    let latest = coordinator.route(
        messageDestination,
        phase: .failed,
        sessionsLoadedCompletely: false
    )
    #expect(latest == .queued(generation: 2))
    #expect(coordinator.pendingDestination == messageDestination)
    #expect(coordinator.sessionsLoadedCompletely(phase: .failed) == nil)

    let drainedResult = coordinator.sessionsLoadedCompletely(phase: .ready)
    let drained = try #require(drainedResult)
    #expect(drained == .open(destination: messageDestination, generation: 2))
}

@Test("invalid deep links remain rejected before routing")
func pendingRouteInvalidLinkIsRejected() {
    let malformed = URL(string: "https://alpha.example/chat/chat-1/message/7")
    #expect(malformed.flatMap(MessageDeepLink.init(url:)) == nil)
}

@Test("successful complete load drains once")
func pendingRouteSuccessfulLoadDrainsOnce() throws {
    var coordinator = PendingRouteCoordinator()
    _ = coordinator.route(chatDestination, phase: .ready, sessionsLoadedCompletely: false)

    let firstResult = coordinator.sessionsLoadedCompletely(phase: .ready)
    let first = try #require(firstResult)
    #expect(first == .open(destination: chatDestination, generation: 1))
    #expect(coordinator.sessionsLoadedCompletely(phase: .ready) == nil)
}

@Test("explicit sign out clears pending route")
func pendingRouteExplicitSignOutClears() {
    var coordinator = PendingRouteCoordinator()
    _ = coordinator.route(chatDestination, phase: .connecting, sessionsLoadedCompletely: false)

    coordinator.clearPending()

    #expect(coordinator.pendingDestination == nil)
    #expect(coordinator.sessionsLoadedCompletely(phase: .ready) == nil)
}

@Test("user navigation before drain prevents dispatch")
func pendingRouteUserNavigationWinsBeforeDrain() {
    var coordinator = PendingRouteCoordinator()
    _ = coordinator.route(
        messageDestination,
        phase: .connecting,
        sessionsLoadedCompletely: false
    )

    coordinator.clearPending()

    #expect(coordinator.pendingDestination == nil)
    #expect(coordinator.sessionsLoadedCompletely(phase: .ready) == nil)
}

@Test("programmatic selection does not cancel queued route")
func pendingRouteProgrammaticSelectionDoesNotCancel() throws {
    var coordinator = PendingRouteCoordinator()
    _ = coordinator.route(
        messageDestination,
        phase: .connecting,
        sessionsLoadedCompletely: false
    )

    // A model-originated selection publishes no user invalidation.
    let decisionResult = coordinator.sessionsLoadedCompletely(phase: .ready)
    let decision = try #require(decisionResult)
    #expect(decision == .open(destination: messageDestination, generation: 1))
}
