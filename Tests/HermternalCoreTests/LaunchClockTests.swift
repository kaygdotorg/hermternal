import Foundation
import Testing
@testable import HermternalCore

@Test("launch clock reports interactivity on the wall breakdown")
func launchBreakdownReportsInteractivity() {
    let line = LaunchClock.formatBreakdown()
    #expect(line.hasPrefix("PERF|launch wall breakdown"))
    #expect(line.contains("interactiveMs="))
    #expect(line.contains("firstResponderMs="))
    #expect(line.contains("runloopIdleMs="))
    #expect(line.contains("becameKeyMs="))
    #expect(line.contains("orderFrontToInteractiveMs="))
    #expect(line.contains("attachDeferredMs="))
    #expect(line.contains("windowOrderedFrontMs="))
}
