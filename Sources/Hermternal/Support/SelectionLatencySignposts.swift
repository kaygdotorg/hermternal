import Foundation
import HermternalCore
import os

/// Instruments-only intervals for the click-to-selection path.
///
/// Every entry point first tests the existing switch-phase measurement mask, so
/// normal launches perform no clock, string, or signpost work. The active
/// record is probe state, not observable app state; it is only used to carry
/// the route identity and warm-projection result to the Core Animation
/// completion callback.
@MainActor
enum SelectionLatencySignposts {
    private static let log = OSLog(
        subsystem: AppIdentity.bundleID,
        category: "selection-latency"
    )
    private static var activeClick: ActiveClick?

    private struct ActiveClick {
        let id: OSSignpostID
        let sessionID: String
        let generation: Int
        var warmProjection: Bool?
    }

    @inline(__always)
    private static var enabled: Bool {
        MeasurementGate.isEnabled(.switchPhases)
    }

    static func beginClick(sessionID: String, generation: Int) {
        guard enabled else { return }
        if let previous = activeClick {
            os_signpost(
                .end,
                log: log,
                name: "click-to-commit",
                signpostID: previous.id,
                "session=%{public}s generation=%d warm=%{public}s outcome=superseded",
                previous.sessionID,
                previous.generation,
                warmDescription(previous.warmProjection)
            )
        }
        let id = OSSignpostID(log: log)
        activeClick = ActiveClick(
            id: id,
            sessionID: sessionID,
            generation: generation,
            warmProjection: nil
        )
        os_signpost(
            .begin,
            log: log,
            name: "click-to-commit",
            signpostID: id,
            "session=%{public}s generation=%d",
            sessionID,
            generation
        )
    }

    static func markWarmProjection(_ warm: Bool, sessionID: String, generation: Int) {
        guard enabled,
              var activeClick,
              activeClick.sessionID == sessionID,
              activeClick.generation == generation
        else { return }
        activeClick.warmProjection = warm
        self.activeClick = activeClick
        os_signpost(
            .event,
            log: log,
            name: "warm-projection",
            signpostID: activeClick.id,
            "session=%{public}s generation=%d warm=%{public}s",
            sessionID,
            generation,
            warm ? "yes" : "no"
        )
    }

    static func beginSelectionMutation(sessionID: String, generation: Int) -> OSSignpostID? {
        beginInterval(
            name: "selection-mutation",
            sessionID: sessionID,
            generation: generation
        )
    }

    static func endSelectionMutation(_ id: OSSignpostID?) {
        endInterval(name: "selection-mutation", id: id)
    }

    static func beginSidebarBody(sessionID: String?, generation: Int) -> OSSignpostID? {
        beginInterval(
            name: "sidebar-body",
            sessionID: sessionID ?? "none",
            generation: generation
        )
    }

    static func endSidebarBody(_ id: OSSignpostID?) {
        endInterval(name: "sidebar-body", id: id)
    }

    static func beginTranscriptUpdate(sessionID: String?, generation: Int) -> OSSignpostID? {
        beginInterval(
            name: "transcript-update",
            sessionID: sessionID ?? "none",
            generation: generation
        )
    }

    static func endTranscriptUpdate(_ id: OSSignpostID?) {
        endInterval(name: "transcript-update", id: id)
    }

    /// Starts at the representable boundary and ends from the current Core
    /// Animation transaction's completion block. This is the only stage that
    /// includes compositor commit time rather than application work.
    static func beginCommit(sessionID: String?, generation: Int) -> OSSignpostID? {
        beginInterval(
            name: "core-animation-commit",
            sessionID: sessionID ?? "none",
            generation: generation
        )
    }

    static func endCommit(_ id: OSSignpostID?) {
        endInterval(name: "core-animation-commit", id: id)
        guard enabled, let activeClick else { return }
        os_signpost(
            .end,
            log: log,
            name: "click-to-commit",
            signpostID: activeClick.id,
            "session=%{public}s generation=%d warm=%{public}s outcome=committed",
            activeClick.sessionID,
            activeClick.generation,
            warmDescription(activeClick.warmProjection)
        )
        self.activeClick = nil
    }

    private static func beginInterval(
        name: StaticString,
        sessionID: String,
        generation: Int
    ) -> OSSignpostID? {
        guard enabled else { return nil }
        let id = OSSignpostID(log: log)
        os_signpost(
            .begin,
            log: log,
            name: name,
            signpostID: id,
            "session=%{public}s generation=%d",
            sessionID,
            generation
        )
        return id
    }

    private static func endInterval(name: StaticString, id: OSSignpostID?) {
        guard enabled, let id else { return }
        os_signpost(.end, log: log, name: name, signpostID: id)
    }

    private static func warmDescription(_ value: Bool?) -> String {
        switch value {
        case true: "yes"
        case false: "no"
        case nil: "unknown"
        }
    }
}
