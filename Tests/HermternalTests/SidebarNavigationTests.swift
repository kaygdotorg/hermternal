@testable import Hermternal
import AppKit
import Testing

@Test("An active repeat reset clears deferred navigation")
@MainActor
func activeRepeatResetClearsDeferredNavigation() {
    var tracker = SidebarNavigationRepeatTracker()
    tracker.recordKeyDown(keyCode: 126, isRepeat: true)

    #expect(tracker.reset())
    #expect(!tracker.isNavigationRepeat)
}

@Test("A repeat reset reports active state once")
@MainActor
func repeatResetReportsActiveStateOnce() {
    var tracker = SidebarNavigationRepeatTracker()
    tracker.recordKeyDown(keyCode: 125, isRepeat: true)

    #expect(tracker.reset())
    #expect(!tracker.reset())
    #expect(!tracker.isNavigationRepeat)
}

@Test("An inactive repeat reset does not report deferred navigation")
@MainActor
func inactiveRepeatResetDoesNotReportDeferredNavigation() {
    var tracker = SidebarNavigationRepeatTracker()

    #expect(!tracker.reset())
    #expect(!tracker.isNavigationRepeat)
}

@Test("Observer registration ends repeated sidebar navigation once and cleans up")
@MainActor
func observerRegistrationEndsRepeatedSidebarNavigationOnceAndCleansUp() async {
    SidebarSelectionEventAdapter.stop()
    defer { SidebarSelectionEventAdapter.stop() }

    var navigationEndCount = 0
    SidebarSelectionEventAdapter.start {
        navigationEndCount += 1
    }
    SidebarSelectionEventAdapter.recordKeyDown(keyCode: 126, isRepeat: false)
    SidebarSelectionEventAdapter.recordKeyDown(keyCode: 126, isRepeat: true)

    NotificationCenter.default.post(
        name: NSApplication.didResignActiveNotification,
        object: nil
    )
    await Task.yield()
    #expect(navigationEndCount == 1)

    NotificationCenter.default.post(
        name: NSApplication.didResignActiveNotification,
        object: nil
    )
    await Task.yield()
    #expect(navigationEndCount == 1)

    SidebarSelectionEventAdapter.recordKeyDown(keyCode: 126, isRepeat: true)
    SidebarSelectionEventAdapter.stop()

    NotificationCenter.default.post(
        name: NSApplication.didResignActiveNotification,
        object: nil
    )
    await Task.yield()
    #expect(navigationEndCount == 1)
}
