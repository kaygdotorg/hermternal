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

    /// Emits the mandatory wall-time report once the window has ordered front.
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

        func value(_ name: String) -> String {
            marks[name].map(String.init) ?? "-"
        }
        func delta(_ startName: String, _ endName: String) -> String {
            guard let start = marks[startName], let end = marks[endName], end >= start else {
                return "-"
            }
            return String(end - start)
        }
        Log.info(
            "PERF|launch wall breakdown"
                + "|processStartMs=\(value("processStart"))"
                + " appModelInitMs=\(delta("appModel.init.begin", "appModel.init.end"))"
                + " searchIndexMs=\(delta("searchIndex.open.begin", "searchIndex.open.end"))"
                + " sessionListMs=\(delta("sessionList.cache.begin", "sessionList.cache.end"))"
                + " residentVisibleTailMs=\(delta("residentVisibleTail.begin", "residentVisibleTail.end"))"
                + " restoredTranscriptMs=\(value("restoredTranscript.published"))"
                + " windowShowBeginMs=\(value("window.show.begin"))"
                + " windowOrderedFrontMs=\(value("window.orderedFront"))"
                + " token=\(token)"
        )
    }
}
