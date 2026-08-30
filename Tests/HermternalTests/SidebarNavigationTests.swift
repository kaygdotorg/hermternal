import AppKit
import Foundation
import HermternalCore
import Testing
@testable import Hermternal

@Test("Deferred sidebar navigation keeps the displayed transcript until it opens")
@MainActor
func deferredSidebarNavigationPreservesDisplayedTranscript() {
    let model = AppModel()
    let current = chatSession(id: "current")
    let next = chatSession(id: "next")
    let transcript = [ChatMessage(role: .assistant, text: "Current transcript")]

    model.messages = transcript
    model.transcriptRouteIdentity = "live:current"
    model.selectedSessionID = current.id
    model.noteTranscriptDisplayed(sessionID: current.id)

    _ = model.requestOpen(next, deferStart: true)

    #expect(model.selectedSessionID == next.id)
    #expect(model.messages.map(\.text) == transcript.map(\.text))
    #expect(model.transcriptRouteIdentity == "live:current")
    #expect(model.displayedTranscriptSessionID == current.id)
}

@Test("An unrelated key-up does not finish repeated sidebar navigation")
func unrelatedKeyUpDoesNotFlushRepeatedArrowNavigation() {
    var tracker = SidebarNavigationRepeatTracker()

    tracker.recordKeyDown(keyCode: 124, isRepeat: true)

    let didFinish = tracker.recordKeyUp(keyCode: 12)
    #expect(!didFinish)
    #expect(tracker.isNavigationRepeat)
}

@Test("The repeated arrow key-up finishes sidebar navigation once")
func repeatedArrowKeyUpFlushesSidebarNavigationOnce() {
    var tracker = SidebarNavigationRepeatTracker()

    tracker.recordKeyDown(keyCode: 124, isRepeat: true)

    let didFinish = tracker.recordKeyUp(keyCode: 124)
    #expect(didFinish)
    let didFinishAgain = tracker.recordKeyUp(keyCode: 124)
    #expect(!didFinishAgain)
    #expect(!tracker.isNavigationRepeat)
}

private func chatSession(id: String) -> ChatSession {
    ChatSession(from: .object(["id": .string(id)]))
}

@Test("A completed List tap uses only context and modified facts")
@MainActor
func completedTapActivationUsesClickFacts() {
    #expect(
        SidebarSelectionEventAdapter.allowsCompletedTapActivation(
            isContextClick: false,
            isModified: false
        )
    )
    let contextClickActivation = SidebarSelectionEventAdapter.allowsCompletedTapActivation(
        isContextClick: true,
        isModified: false
    )
    #expect(!contextClickActivation)
    let modifiedClickActivation = SidebarSelectionEventAdapter.allowsCompletedTapActivation(
        isContextClick: false,
        isModified: true
    )
    #expect(!modifiedClickActivation)
}

@Test("Observer registration ends repeated sidebar navigation once and cleans up")
@MainActor
func observerRegistrationEndsRepeatedSidebarNavigationOnceAndCleansUp() {
    SidebarSelectionEventAdapter.stop()
    defer { SidebarSelectionEventAdapter.stop() }

    var navigationEndCount = 0
    SidebarSelectionEventAdapter.start { navigationEndCount += 1 }
    SidebarSelectionEventAdapter.recordKeyDown(keyCode: 124, isRepeat: false)
    SidebarSelectionEventAdapter.recordKeyDown(keyCode: 124, isRepeat: true)

    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
    #expect(navigationEndCount == 1)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
    #expect(navigationEndCount == 1)

    SidebarSelectionEventAdapter.recordKeyDown(keyCode: 124, isRepeat: true)
    SidebarSelectionEventAdapter.stop()
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
    #expect(navigationEndCount == 1)
}
