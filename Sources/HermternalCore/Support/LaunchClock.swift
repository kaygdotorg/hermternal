import Foundation

/// Process-lifetime launch timing for the file log.
///
/// Capture the origin at the first Swift line in app init. Each mark is one
/// log line with milliseconds from that origin. The breakdown line is the
/// release-audit report; wall time is machine-dependent and is not a CI gate.
public enum LaunchClock {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var processStartNanoseconds: UInt64?
        var token = "--------"
        var marks: [String: Int] = [:]
        var didReportBreakdown = false
    }

    private static let state = State()

    /// Records the process origin once. Later calls keep the first timestamp.
    public static func captureProcessStart() {
        state.lock.lock()
        if state.processStartNanoseconds == nil {
            state.processStartNanoseconds = DispatchTime.now().uptimeNanoseconds
            state.token = String(UUID().uuidString.prefix(8))
        }
        state.lock.unlock()
        mark("processStart")
    }

    /// Milliseconds since ``captureProcessStart``. Zero if capture has not run.
    public static func milliseconds() -> Int {
        state.lock.lock()
        let start = state.processStartNanoseconds
        state.lock.unlock()
        guard let start else { return 0 }
        return Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }

    /// Writes one timestamped marker. Duplicate names keep the first value.
    public static func mark(_ name: String) {
        let ms = milliseconds()
        state.lock.lock()
        if state.marks[name] != nil {
            state.lock.unlock()
            return
        }
        state.marks[name] = ms
        let token = state.token
        state.lock.unlock()
        Log.info("PERF|launch marker|\(name) ms=\(ms) token=\(token)")
    }

    /// First recorded value for `name`, if the mark has fired.
    public static func recordedMilliseconds(for name: String) -> Int? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.marks[name]
    }

    /// Marks interactivity when the key window has a field and the runloop is idle.
    public static func markReadyIfInteractive() {
        guard recordedMilliseconds(for: "interactivity.firstResponder") != nil,
              recordedMilliseconds(for: "window.becameKey") != nil,
              recordedMilliseconds(for: "interactivity.runloopIdle") != nil
        else { return }
        mark("interactivity.ready")
    }

    /// Formats the wall-time report from the marks recorded so far.
    public static func formatBreakdown() -> String {
        state.lock.lock()
        let token = state.token
        let marks = state.marks
        state.lock.unlock()
        return formatBreakdown(marks: marks, token: token)
    }

    /// Emits the mandatory wall-time report once attach and interactivity exist.
    public static func reportBreakdown() {
        state.lock.lock()
        guard !state.didReportBreakdown else {
            state.lock.unlock()
            return
        }
        state.didReportBreakdown = true
        let token = state.token
        let marks = state.marks
        state.lock.unlock()
        Log.info(formatBreakdown(marks: marks, token: token))
    }

    /// Clears process-lifetime state. Tests call this so marks do not leak.
    public static func resetForTests() {
        state.lock.lock()
        state.processStartNanoseconds = nil
        state.token = "--------"
        state.marks = [:]
        state.didReportBreakdown = false
        state.lock.unlock()
    }

    private static func formatBreakdown(marks: [String: Int], token: String) -> String {
        func value(_ name: String) -> String {
            marks[name].map(String.init) ?? "-"
        }
        func delta(_ startName: String, _ endName: String) -> String {
            guard let start = marks[startName], let end = marks[endName], end >= start else {
                return "-"
            }
            return String(end - start)
        }
        return "PERF|launch wall breakdown"
            + "|processStartMs=\(value("processStart"))"
            + " appModelInitMs=\(delta("appModel.init.begin", "appModel.init.end"))"
            + " searchIndexMs=\(delta("searchIndex.open.begin", "searchIndex.open.end"))"
            + " sessionListMs=\(delta("sessionList.cache.begin", "sessionList.cache.end"))"
            + " residentVisibleTailMs=\(delta("residentVisibleTail.begin", "residentVisibleTail.end"))"
            + " restoredTranscriptMs=\(value("restoredTranscript.published"))"
            + " windowShowBeginMs=\(value("window.show.begin"))"
            + " shellConstructMs=\(delta("window.shellConstruct.begin", "window.shellConstruct.end"))"
            + " windowCreateMs=\(delta("window.create.begin", "window.create.end"))"
            + " windowPrepareMs=\(delta("window.prepare.begin", "window.prepare.end"))"
            + " hostingViewLoadMs=\(delta("window.hostingView.begin", "window.hostingView.end"))"
            + " attachDeferredMs=\(value("window.attach.deferred"))"
            + " attachMs=\(delta("window.attach.begin", "window.attach.end"))"
            + " contentViewAssignedMs=\(value("window.contentViewAssigned"))"
            + " frameRestoredMs=\(value("window.frameRestored"))"
            + " firstSwiftUIRenderMs=\(value("window.firstSwiftUIRender"))"
            + " toolbarMs=\(delta("window.toolbar.begin", "window.toolbar.end"))"
            + " backdropHostedMs=\(value("window.backdropHosted"))"
            + " orderFrontBeginMs=\(value("window.orderFront.begin"))"
            + " orderFrontMs=\(delta("window.orderFront.begin", "window.orderedFront"))"
            + " publishToFrontMs=\(delta("restoredTranscript.published", "window.orderedFront"))"
            + " windowOrderedFrontMs=\(value("window.orderedFront"))"
            + " becameKeyMs=\(value("window.becameKey"))"
            + " firstResponderMs=\(value("interactivity.firstResponder"))"
            + " runloopIdleMs=\(value("interactivity.runloopIdle"))"
            + " interactiveMs=\(value("interactivity.ready"))"
            + " orderFrontToInteractiveMs=\(delta("window.orderedFront", "interactivity.ready"))"
            + " token=\(token)"
    }
}
