import AppKit
import Foundation
import HermternalCore
import Observation
/// Launch: `HERMTERNAL_SWITCH_TRACE=1 /home/kayg/Developer/hermternal-apple/build/Hermternal.app/Contents/MacOS/Hermternal > /tmp/herm-switch-trace.log 2>&1`
/// Summarize coverage and latency: `awk '{ ns=event=token=gen=""; for (i=1;i<=NF;i++) { split($i,p,"="); if (p[1]=="ns") ns=p[2]; else if (p[1]=="event") event=p[2]; else if (p[1]=="token") token=p[2]; else if (p[1]=="gen") gen=p[2] } key=token "/" gen; if (event=="selection.publish") { publications++; pub[key]=ns } else if (event=="transcript.visible" && (key in pub)) { paints++; print "LATENCY ms=" (ns-pub[key])/1000000; delete pub[key] } else if (event=="transcript.superseded" && (key in pub)) { superseded++; delete pub[key] } else if (event=="transcript.stalePaint") { stale++ } } END { terminal=paints+superseded; coverage=publications ? 100*terminal/publications : 100; printf "COVERAGE publications=%d paints=%d superseded=%d stalePaints=%d terminal=%d coverage=%.1f%%\\n", publications, paints, superseded, stale, terminal, coverage }' /tmp/herm-switch-trace.log | tee /tmp/herm-switch-coverage.log; awk '$1=="LATENCY" { split($2,p,"="); print p[2] }' /tmp/herm-switch-coverage.log | sort -n | awk '{ v[NR]=$1 } END { if (NR) printf "LATENCY count=%d median=%.1fms p90=%.1fms max=%.1fms\\n", NR, v[int((NR+1)/2)], v[int((90*NR+99)/100)], v[NR] }'`
/// Each `selection.publish` has exactly one terminal event: either
/// `transcript.visible` after a real paint or `transcript.superseded` when a
/// newer publication wins before that paint. Stale paint candidates are
/// reported as `transcript.stalePaint` and do not terminate the publication.
/// Temporary, opt-in trace sink for session switching and sidebar selection.
@MainActor
enum HermternalSwitchTrace {
    private static var gate = DebugModuleGate(mask: .none)
    private static var debugModules: (any DebugModuleCapability)?
    /// Counts are cumulative over the samples retained since the capability's
    /// last clear. The next accepted event observes an emptied ring and resets
    /// these counters before contributing to a new sample series.
    private static var selectionCount = 0
    private static var publicationCount = 0
    private static var stalePaintCount = 0
    /// Layout-cache hits over the process lifetime, not per publication. A
    /// route's first publication reads heights before preparation has written
    /// any, so a per-publication count of zero is expected there and says
    /// nothing about whether the cache works.
    private static var heightCacheHitsLifetime = 0
    private static var hasRecordedMetricSample = false
    /// The one publication that has not reached a terminal paint outcome.
    /// A newer publication closes this record as superseded before replacing
    /// it, so the trace cannot silently lose a publication.
    private struct PendingTranscriptPublication {
        let id: String
        let generation: Int
        let publishedAtNanoseconds: UInt64
        var updateNSViewNanoseconds: UInt64 = 0
        var coordinatorDiffNanoseconds: UInt64 = 0
        var heightCalls = 0
        var heightCacheHits = 0
        var heightCacheHitNanoseconds: UInt64 = 0
        var heightEstimatorCalls = 0
        var heightEstimatorNanoseconds: UInt64 = 0
        var rowConfigurations = 0
        var reusedRowConfigurations = 0
        var newRowConfigurations = 0
        var textSliceCount = 0
        var textSliceNanoseconds: UInt64 = 0
        var contentHashCount = 0
        var contentHashNanoseconds: UInt64 = 0
        var fullReloadRows = 0
        var targetedReloadRows = 0
        /// End of the latest updateNSView pass, from the same monotonic clock
        /// as publication and paint timestamps.
        var updateEndedAtNanoseconds: UInt64?
    }
    private static var pendingTranscriptPublication: PendingTranscriptPublication?

    static func configure(capability: any DebugModuleCapability) {
        debugModules = capability
        gate = capability.gate
        pendingTranscriptPublication = nil
        selectionCount = 0
        publicationCount = 0
        stalePaintCount = 0
        heightCacheHitsLifetime = 0
        hasRecordedMetricSample = false
        HermternalSelectionOccupancyTrace.configure(gate: gate)
    }

    static var isEnabled: Bool {
        gate.isEnabled(.visiblePaint)
    }

    static func session(
        _ event: String,
        id: String?,
        generation: Int? = nil,
        messages: @autoclosure () -> Int? = nil,
        renderedRows: Int? = nil,
        detail: String? = nil,
        owner: TraceOwner? = nil,
        executor: TraceExecutor? = nil,
        module: DebugModule = .switchPhases,
        timestampNanoseconds: UInt64? = nil
    ) {
        guard gate.isEnabled(module) else { return }
        let eventTimestamp = timestampNanoseconds ?? DispatchTime.now().uptimeNanoseconds
        if event == "selection.publish", let id, let generation {
            if let pending = pendingTranscriptPublication {
                session(
                    "transcript.superseded",
                    id: pending.id,
                    generation: pending.generation,
                    detail: "beforePaint",
                    module: .visiblePaint
                )
            }
            resetCountersIfMetricsCleared()
            publicationCount &+= 1
            pendingTranscriptPublication = PendingTranscriptPublication(
                id: id,
                generation: generation,
                publishedAtNanoseconds: eventTimestamp
            )
        }
        emit(
            prefix: "[DEBUG-switch-7F3A]",
            event: event,
            id: id,
            generation: generation,
            messages: messages(),
            renderedRows: renderedRows,
            detail: detail,
            owner: owner?.rawValue,
            executor: executor?.rawValue,
            seed: 0x01,
            timestampNanoseconds: eventTimestamp
        )
    }

    /// Returns a timestamp only while the visible-paint trace is enabled.
    /// Callers use this to bracket hot AppKit callbacks without paying for
    /// clocks or strings in normal launches.
    static func transcriptPhaseClock() -> UInt64? {
        guard gate.isEnabled(.visiblePaint) else { return nil }
        return DispatchTime.now().uptimeNanoseconds
    }

    static func transcriptPhaseUpdateNSView(start: UInt64, end: UInt64) {
        pendingTranscriptPublication?.updateNSViewNanoseconds &+= elapsedNanoseconds(
            start: start,
            end: end
        )
    }

    static func transcriptPhaseCoordinatorDiff(start: UInt64, end: UInt64) {
        pendingTranscriptPublication?.coordinatorDiffNanoseconds &+= elapsedNanoseconds(
            start: start,
            end: end
        )
    }

    /// Height answers, split by whether the layout cache served them.
    ///
    /// `heightCacheHits` counts only within one publication, and on a route's
    /// first publication the height pass runs before background preparation
    /// has written any measured value, so that field is legitimately zero
    /// there. It is not evidence of a cold cache: a live run confirmed the
    /// write and read keys are byte-identical, field for field. Read
    /// `heightCacheHitsLifetime` to judge whether the cache works at all, and
    /// the per-publication field only to judge that publication.
    static func transcriptPhaseHeight(
        cacheHit: Bool,
        start: UInt64,
        end: UInt64
    ) {
        let duration = elapsedNanoseconds(start: start, end: end)
        if cacheHit {
            heightCacheHitsLifetime &+= 1
        }
        guard var pending = pendingTranscriptPublication else { return }
        pending.heightCalls &+= 1
        if cacheHit {
            pending.heightCacheHits &+= 1
            pending.heightCacheHitNanoseconds &+= duration
        } else {
            pending.heightEstimatorCalls &+= 1
            pending.heightEstimatorNanoseconds &+= duration
        }
        pendingTranscriptPublication = pending
    }

    static func transcriptPhaseRowConfiguration(reused: Bool) {
        guard var pending = pendingTranscriptPublication else { return }
        pending.rowConfigurations &+= 1
        if reused {
            pending.reusedRowConfigurations &+= 1
        } else {
            pending.newRowConfigurations &+= 1
        }
        pendingTranscriptPublication = pending
    }

    static func transcriptPhaseReload(full: Bool, rows: Int) {
        guard var pending = pendingTranscriptPublication else { return }
        if full {
            pending.fullReloadRows &+= rows
        } else {
            pending.targetedReloadRows &+= rows
        }
        pendingTranscriptPublication = pending
    }

    static func transcriptPhaseReloadFallback(
        rows: Int,
        visibleLocation: Int,
        visibleLength: Int
    ) {
        guard gate.isEnabled(.visiblePaint) else { return }
        let pending = pendingTranscriptPublication
        session(
            "transcript.reloadFallback",
            id: pending?.id,
            generation: pending?.generation,
            renderedRows: rows,
            detail: "reason=emptyVisibleIndexes,visibleLocation=\(visibleLocation),visibleLength=\(visibleLength),action=fullReload",
            owner: .blockRowConfiguration,
            executor: .main,
            module: .visiblePaint
        )
    }

    /// A publication that arrived before the hosted view had a usable size.
    ///
    /// The coordinator's update can run before SwiftUI lays the NSView out, so
    /// the clip view is zero-height and no visible row range exists. Reloading
    /// then would rebuild every row and start no preparation, which is what
    /// made every publication take the full-reload path and left the layout
    /// cache permanently cold. The publication is held and applied once a real
    /// layout arrives. This records the wait so a reader can tell a first-paint
    /// deferral from the normal path becoming deferred, which would be a bug.
    static func transcriptPhaseReloadDeferred(
        rows: Int,
        visibleLocation: Int,
        visibleLength: Int
    ) {
        guard gate.isEnabled(.visiblePaint) else { return }
        let pending = pendingTranscriptPublication
        session(
            "transcript.reloadDeferred",
            id: pending?.id,
            generation: pending?.generation,
            renderedRows: rows,
            detail: "reason=noLayoutYet,visibleLocation=\(visibleLocation),visibleLength=\(visibleLength),action=awaitLayout",
            owner: .blockRowConfiguration,
            executor: .main,
            module: .visiblePaint
        )
    }

    static func transcriptPhaseTextSlice(start: UInt64, end: UInt64) {
        guard var pending = pendingTranscriptPublication else { return }
        pending.textSliceCount &+= 1
        pending.textSliceNanoseconds &+= elapsedNanoseconds(start: start, end: end)
        pendingTranscriptPublication = pending
    }

    static func transcriptPhaseContentHash(start: UInt64, end: UInt64) {
        guard var pending = pendingTranscriptPublication else { return }
        pending.contentHashCount &+= 1
        pending.contentHashNanoseconds &+= elapsedNanoseconds(start: start, end: end)
        pendingTranscriptPublication = pending
    }

    static func transcriptPhaseUpdateEnded(at timestamp: UInt64) {
        pendingTranscriptPublication?.updateEndedAtNanoseconds = timestamp
    }

    private static func elapsedNanoseconds(start: UInt64, end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }


    /// The viewport paint is deliberately a separate event from
    /// `transcript.firstFrame`: that anchor is a graph/positioning callback,
    /// not evidence that transcript pixels were drawn.
    static func transcriptVisible(
        id: String,
        generation: Int,
        messages: Int,
        renderedRows: Int,
        visibleAtNanoseconds: UInt64,
        largestRowCharacterCount: () -> Int?
    ) -> Bool {
        guard gate.isEnabled(.visiblePaint) else { return true }
        guard let pending = pendingTranscriptPublication,
              pending.id == id,
              pending.generation == generation
        else {
            return false
        }
        guard visibleAtNanoseconds > pending.publishedAtNanoseconds else {
            stalePaintCount &+= 1
            let signedDeltaNanoseconds =
                Int64(visibleAtNanoseconds) - Int64(pending.publishedAtNanoseconds)
            session(
                "transcript.stalePaint",
                id: id,
                generation: generation,
                messages: messages,
                renderedRows: renderedRows,
                detail: "deltaNs=\(signedDeltaNanoseconds), count=\(stalePaintCount)",
                module: .visiblePaint,
                timestampNanoseconds: visibleAtNanoseconds
            )
            return false
        }
        // A non-empty transcript always has a row to configure before a paint.
        // Zero configured rows means AppKit skipped viewFor, so this is never a valid empty state.
        if messages > 0, pending.rowConfigurations == 0 {
            session(
                "transcript.zeroConfiguredRows",
                id: id,
                generation: generation,
                messages: messages,
                renderedRows: renderedRows,
                detail: "rowConfigs=0,rowNew=0,rowReused=0",
                owner: .blockRowConfiguration,
                executor: .main,
                module: .visiblePaint,
                timestampNanoseconds: visibleAtNanoseconds
            )
        }
        let updateToPaintNanoseconds = pending.updateEndedAtNanoseconds.map {
            visibleAtNanoseconds >= $0 ? visibleAtNanoseconds - $0 : 0
        } ?? 0
        session(
            "transcript.phaseBreakdown",
            id: id,
            generation: generation,
            messages: messages,
            renderedRows: renderedRows,
            detail: "publishToPaintNs=\(visibleAtNanoseconds - pending.publishedAtNanoseconds),updateToPaintNs=\(updateToPaintNanoseconds),updateNs=\(pending.updateNSViewNanoseconds),diffNs=\(pending.coordinatorDiffNanoseconds),heightCalls=\(pending.heightCalls),heightCacheHits=\(pending.heightCacheHits),heightCacheHitsLifetime=\(heightCacheHitsLifetime),heightCacheNs=\(pending.heightCacheHitNanoseconds),heightEstimatorCalls=\(pending.heightEstimatorCalls),heightEstimatorNs=\(pending.heightEstimatorNanoseconds),rowConfigs=\(pending.rowConfigurations),rowReused=\(pending.reusedRowConfigurations),rowNew=\(pending.newRowConfigurations),textSlices=\(pending.textSliceCount),textSliceNs=\(pending.textSliceNanoseconds),contentHashCalls=\(pending.contentHashCount),contentHashNs=\(pending.contentHashNanoseconds),reloadFullRows=\(pending.fullReloadRows),reloadTargetedRows=\(pending.targetedReloadRows)",
            owner: .blockRowConfiguration,
            executor: .main,
            module: .visiblePaint,
            timestampNanoseconds: visibleAtNanoseconds
        )
        pendingTranscriptPublication = nil
        debugModules?.record(
            DebugSelectionAggregate(
                publishToVisibleNanoseconds: visibleAtNanoseconds &- pending.publishedAtNanoseconds,
                selectionCount: selectionCount,
                publicationCount: publicationCount,
                largestRowCharacterCount: largestRowCharacterCount()
            ),
            for: .visiblePaint
        )
        hasRecordedMetricSample = true
        session(
            "transcript.visible",
            id: id,
            generation: generation,
            messages: messages,
            renderedRows: renderedRows,
            module: .visiblePaint,
            timestampNanoseconds: visibleAtNanoseconds
        )
        return true
    }

    /// The graph can receive the selected ID before its deferred publication.
    /// Keep the paint probe behind the corresponding publication event.
    static func hasPublishedSelection(id: String, generation: Int) -> Bool {
        guard gate.isEnabled(.visiblePaint) else { return true }
        guard let pending = pendingTranscriptPublication else { return false }
        return pending.id == id && pending.generation == generation
    }

    static func folder(
        _ event: String,
        id: String?,
        generation: Int? = nil,
        messages: @autoclosure () -> Int? = nil,
        detail: String? = nil
    ) {
        guard gate.isEnabled(.sidebarAndFolderSelection) else { return }
        emit(
            prefix: "[DEBUG-folder-7F3A]",
            event: event,
            id: id,
            generation: generation,
            messages: messages(),
            detail: detail,
            seed: 0x02
        )
    }

    static func selection(
        _ event: String,
        selection: Set<SidebarSelectionID>,
        messages: @autoclosure () -> Int,
        detail: String? = nil,
        module: DebugModule = .sidebarAndFolderSelection
    ) {
        guard gate.isEnabled(module) else { return }
        if event == "sidebarSelection.onChange" {
            resetCountersIfMetricsCleared()
            selectionCount &+= 1
        }
        let id: String?
        let seed: UInt64
        if selection.count == 1, let item = selection.first {
            switch item {
            case let .chat(value):
                id = value
                seed = 0x01
            case let .folder(value):
                id = value
                seed = 0x02
            }
        } else {
            id = nil
            seed = 0x03
        }
        let hasFolder = selection.contains { item in
            switch item {
            case .folder(_):
                true
            case .chat(_):
                false
            }
        }
        emit(
            prefix: hasFolder ? "[DEBUG-folder-7F3A]" : "[DEBUG-switch-7F3A]",
            event: event,
            id: id,
            generation: nil,
            messages: messages(),
            detail: detail,
            seed: seed,
            fallbackToken: "count-\(selection.count)",
            timestampNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }
    /// Records a rejected selection path without doing work when the
    /// sidebar-selection debug module is disabled.
    static func selectionGuard(
        _ guardName: String,
        selection selectedItems: @autoclosure () -> Set<SidebarSelectionID> = [],
        id: String? = nil,
        generation: Int? = nil,
        messages: @autoclosure () -> Int = 0,
        reason: @autoclosure () -> String = ""
    ) {
        guard gate.isEnabled(.sidebarAndFolderSelection) else { return }
        let suppliedReason = reason()
        let detail = "guard=\(guardName)"
            + (id.map { " id=\($0)" } ?? "")
            + (generation.map { " gen=\($0)" } ?? "")
            + (suppliedReason.isEmpty ? "" : " reason=\(suppliedReason)")
        selection(
            "selection.guard",
            selection: selectedItems(),
            messages: messages(),
            detail: detail
        )
    }
    private static func resetCountersIfMetricsCleared() {
        guard hasRecordedMetricSample,
              gate.isEnabled(.visiblePaint),
              debugModules?.metrics == nil
        else { return }
        selectionCount = 0
        publicationCount = 0
        stalePaintCount = 0
        hasRecordedMetricSample = false
    }

    private static func emit(
        prefix: String,
        event: String,
        id: String?,
        generation: Int?,
        messages: Int?,
        renderedRows: Int? = nil,
        detail: String? = nil,
        owner: String? = nil,
        executor: String? = nil,
        seed: UInt64,
        fallbackToken: String = "none",
        timestampNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        let line = "\(prefix) ns=\(timestampNanoseconds)"
            + " event=\(event)"
            + " gen=\(generation.map { String($0) } ?? "-")"
            + " messages=\(messages.map { String($0) } ?? "-")"
            + (renderedRows.map { " rows=\($0)" } ?? "")
            + " token=\(id.map { token($0, seed: seed) } ?? fallbackToken)"
            + (owner.map { " owner=\($0)" } ?? "")
            + (executor.map { " executor=\($0)" } ?? "")
            + (detail.map { " detail=\($0)" } ?? "")
            + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func token(_ value: String, seed: UInt64) -> String {
        var hash = 14695981039346656037 ^ seed
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}


@MainActor
@Observable
final class AppModel: ComposerTurnRouting {
    /// The process capability injected by the composition root. The trace
    /// owner retains this same reference so a paint can record without global
    /// capability lookup or a second registry.
    let debugModules: any DebugModuleCapability

    enum Phase: Equatable {
        case signedOut
        case connecting
        case ready
        case failed(String)
    }

    // MARK: - Observable state

    var phase: Phase = .signedOut
    var sessions: [ChatSession] = []
    var sortMode: SortMode = .lastActivity
    var groupByDate = true
    /// Which of the sidebar's two lists the column shows. The window's
    /// toolbar menu and the column itself both act on this, so neither of
    /// them can own it.
    var sidebarContentMode: SidebarContentMode = .chats
    /// Raised by the New Folder command. The sidebar column owns the prompt,
    /// because the prompt belongs beside the list it adds a folder to.
    var isCreatingFolder = false
    var archivedSessions: [ChatSession] = []
    var archivedSessionsLoading = false
    var archivedSessionsError: String?
    var folders: [Folder] = []
    var membership: [String: String] = [:]
    /// A bounded presentation of the active transcript. Full history lives in
    /// the disk-backed PagedTranscriptStore and is never retained here.
    var messages: [ChatMessage] = [] {
        didSet {
            let bounded = Array(messages.suffix(TranscriptPublicationPolicy.initialMessageCount))
            if bounded.count != messages.count {
                messages = bounded
                return
            }
            messagesRevision &+= 1
            transcriptRevision &+= 1
        }
    }
    /// Monotonic revision for the bounded transcript presentation.
    private(set) var messagesRevision = 0

    /// The active disk-backed transcript and the route used to read it.
    /// Renderer and Find consumers use these values instead of a corpus array.
    private(set) var activeTranscriptStore: PagedTranscriptStore?
    private(set) var activeTranscriptRoute: TranscriptRoute?
    private(set) var transcriptSummary: TranscriptSummary?
    private(set) var transcriptRevision: UInt64 = 0
    private var activeStoreAppGeneration: Int?
    private(set) var activeTranscriptFindCursor: TranscriptFindCursor?

    /// Compatibility projection for legacy callers. This scans only the
    /// bounded visible tail; the full Find path uses `makeTranscriptFindCursor`.
    func transcriptMatches(for query: String) -> [TranscriptMatch] {
        TranscriptFindPass.matches(in: messages, query: query)
    }

    func makeTranscriptFindCursor(
        query: String,
        caseSensitive: Bool = false,
        role: String? = nil
    ) async -> TranscriptFindCursor? {
        guard let store = activeTranscriptStore else { return nil }
        let cursor = try? await store.find(
            FindQuery(text: query, caseSensitive: caseSensitive, role: role)
        )
        activeTranscriptFindCursor = cursor
        return cursor
    }
    var selectedSessionID: String?
    /// Route identity installed with the transcript snapshot.
    ///
    /// Selection changes publish first. The opener changes this identity
    /// together with `messages` after the selection transaction commits.
    var transcriptRouteIdentity = "live:none"
    private(set) var transcriptRouteGeneration = 0
    /// The chat whose transcript has actually been painted, as distinct from
    /// the one that is selected.
    private(set) var displayedTranscriptSessionID: String?

    /// Called when the transcript reports that a route's content reached the
    /// screen. Ignores a stale report for a route the user has already left.
    func noteTranscriptDisplayed(sessionID: String) {
        guard selectedSessionID == sessionID else {
            HermternalSwitchTrace.selectionGuard(
                "transcriptDisplayed.route",
                id: sessionID,
                messages: messages.count,
                reason: "staleVisibilityForCurrentSelection"
            )
            return
        }
        displayedTranscriptSessionID = sessionID
    }
    /// A routed message target that ChatView reads during the transcript's
    /// initial layout. It is single-use and owned by its open generation.
    var pendingMessageLocation: MessageLocation? { pendingMessageRoute?.location }
    var openGeneration: Int { openGenerations.current() }

    var isAwaitingReply = false
    /// True while an explicit open is preparing a replacement transcript.
    var isPreparingTranscriptOpen: Bool { isPreparingOpen }
    /// Reserved for the read-only archived transcript route. It remains nil
    /// until the transcript host can gate the composer and send actions.
    var viewingArchivedSessionID: String?
    var isViewingArchivedTranscript: Bool { viewingArchivedSessionID != nil }
    var composerText = ""
    var serverText: String = AppModel.storedServer
    /// Host of the configured gateway, used to keep deep links authoritative
    /// to the backend that created them.
    var configuredGatewayHost: String? { serverURL?.host }

    /// The gateway status snapshot used by the settings tab.
    var gatewayStatus: GatewayStatus {
        let url = serverURL ?? URL(string: Self.defaultServer)!
        let connection: GatewayConnectionState = switch phase {
        case .signedOut: .signedOut
        case .connecting: .connecting
        case .ready: .ready
        case .failed(let message): .failed(message)
        }
        let method = AuthMethodStore.load(gateway: url) ?? .browserPKCE
        return GatewayStatus(
            url: url,
            connection: connection,
            provider: discoveredProvider,
            method: method,
            gatewayAdvertisedMethods: gatewayAdvertisedMethods
        )
    }
    /// Capability state is composed by the connected gateway module.
    var sessionPurgeCapability: SessionPurgeCapability?
    var sessionPurgeUnavailableReason: String = "Complete deletion is unavailable on this gateway."
    var canPurgeSessions: Bool { sessionPurgeCapability != nil }

    var accountPresentation: AccountIdentityPresentation {
        AccountIdentityResolver.resolve(
            identity: accountIdentity,
            provider: discoveredProvider,
            gateway: gatewayStatus.url
        )
    }
    /// Composer state is created at the connected-gateway composition root.
    /// Composer state is always present; before connection its real gateway
    /// adapter reports transport unavailability rather than disappearing.
    @ObservationIgnored
    private(set) lazy var composerModel: ComposerModel = {
        let gateway = GatewayClient()
        let runtime = GatewayRuntimeAdapter(gateway: gateway)
        return ComposerModel(
            route: composerRoute,
            runtime: runtime,
            attachmentStaging: runtime,
            turn: self,
            dictation: SpeechDictationAdapter(),
            recorder: AudioCaptureAdapter()
        )
    }()
    private(set) var composerRuntimeSnapshot = SessionRuntimeSnapshot(
        model: nil,
        provider: nil,
        reasoning: nil,
        isRunning: false
    )
    private(set) var composerDefaultModel: String?
    private(set) var composerDefaultProvider: String?
    private(set) var composerDefaultReasoning: ReasoningSetting?
    private(set) var composerDefaultsUnavailableReason: String?
    var composerDefaultsAvailable: Bool { composerDefaultsUnavailableReason == nil }
    var composerInventory: ModelInventory? {
        if case let .loaded(value) = composerModel.inventory { return value }
        return nil
    }
    var currentSessionModel: String? { composerRuntimeSnapshot.model }
    var currentSessionReasoning: ReasoningSetting? { composerRuntimeSnapshot.reasoning }

    /// The command-K surface is owned by the app model so the command menu
    /// and the window overlay share one source of truth.
    var isSearchPresented = false
    /// Incremented by the application Find command. ChatView observes this
    /// explicit seam because focused values do not cross an AppKit host.
    var findRequestGeneration = 0
    /// Incremented by AppKit commands that need to focus the composer. This
    /// remains a generation rather than a Boolean so a request is observable
    /// even when the current selection is already nil.
    var composerFocusRequestGeneration = 0

    let toastPresenter: ToastPresenter
    private(set) var searchQuerying: (any SearchQuerying)?
    private(set) var searchUnavailableReason: String?

    var cacheEnabled = UserDefaults.standard.object(forKey: "cache.enabled") as? Bool ?? true
    var cacheCachedCount = 0
    var cacheTotalCount = 0
    var cacheBytes: Int64 = 0
    var isCacheWarming = false

    var cacheProgress: Double {
        guard cacheTotalCount > 0 else { return cacheEnabled ? 0 : 1 }
        return min(Double(cacheCachedCount) / Double(cacheTotalCount), 1)
    }

    // MARK: - Private

    /// Live ephemeral session id from `session.create` / `session.resume`.
    /// `prompt.submit` and `session.history` take this, never the durable id.
    private var liveSessionID: String?
    private var auth: AuthClient?
    private var gateway: GatewayClient?
    private var rest: RestClient?
    private var capabilityModule: GatewayCapabilityModule?
    private var composerRuntime: GatewayRuntimeAdapter?
    private let organizationStore: SessionOrganizationStore
    private var organizationSnapshot: SessionOrganization?
    private var organizationLoaded = false
    /// True only after a complete REST paging pass has loaded the sessions.
    /// Reconciliation must never use a partial page as the authoritative set.
    private var sessionsLoadedCompletely = false
    /// Injectable seam for exercising cache-first opening without a live app
    /// connection; production builds construct the gateway/rest adapter.
    private let injectedTranscriptSource: (any TranscriptSource)?
    private var eventTask: Task<Void, Never>?
    private let cache: any TranscriptPersisting
    /// Kept separately because the search decorator intentionally hides the
    /// paged-store seam; both layers still share the same on-disk directory.
    private let historyCache: HistoryCache
    private let warmStore: TranscriptWarmStore
    private var accountIdentity: AccountIdentity?
    private var discoveredProvider: AuthProvider?
    private var gatewayAdvertisedMethods = AuthMethod.clientSupported
    private var prefetchTask: Task<Void, Never>?
    private var cacheControlTask: Task<Void, Never>?
    private var cacheControlGeneration = 0
    private var prefetchGeneration = 0
    private var accountGeneration = 0
    private var archivedLoadGeneration = 0
    private var purgePreparationGeneration = 0
    /// Core-owned generation guard used to invalidate superseded opens.
    private struct PendingMessageRoute: Equatable {
        let location: MessageLocation
        let generation: Int
    }
    private var pendingMessageRoute: PendingMessageRoute?
    private var pendingExternalRoute = PendingRouteCoordinator()

    /// The current opener is explicitly cancelled before another selection
    /// starts. Its handle clears producer-owned transcript state synchronously.
    private var activeOpenTask: Task<Void, Never>?
    private var activeOpenHandle: TranscriptOpenHandle?
    private var externalRouteTask: Task<Void, Never>?
    private let openGenerations = OpenGenerationController()
    private var streamingReducer = StreamingEventReducer()
    /// Invalidates in-flight optimistic persist work when the user turn is
    /// rolled back before the gateway accepts it.
    private var transcriptPersistGeneration = 0
    /// Suppresses gateway deltas while a newly selected transcript is being
    /// prepared. Selection changes invalidate the previous live stream before
    /// the first actor yield; without this guard an event arriving in that
    /// gap could reduce into the newly selected chat's empty reducer.
    private var isPreparingOpen = false
    /// Identifies the request that owns `isPreparingOpen`, so a superseded
    /// request cannot clear a newer request's preparation state.
    private var preparingOpenGeneration: Int?

    private static let serverKey = "serverURL"
    private static let defaultServer = "https://hermes-dashboard.kayg.org"

    private static var storedServer: String {
        UserDefaults.standard.string(forKey: serverKey) ?? defaultServer
    }

    private var serverURL: URL? {
        let trimmed = serverText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return nil
        }
        return url
    }
    init(
        cache: HistoryCache = HistoryCache(),
        transcriptSource: (any TranscriptSource)? = nil,
        toastPresenter: ToastPresenter = ToastPresenter(),
        organizationStore: SessionOrganizationStore = SessionOrganizationStore(),
        warmStore: TranscriptWarmStore = TranscriptWarmStore(),
        debugModules: any DebugModuleCapability = OmittedDebugModuleCapability()
    ) {
        self.debugModules = debugModules
        self.injectedTranscriptSource = transcriptSource
        self.toastPresenter = toastPresenter
        self.organizationStore = organizationStore
        self.historyCache = cache
        self.warmStore = warmStore
        HermternalSwitchTrace.configure(capability: debugModules)
        guard let historyDirectory = cache.storageDirectory else {
            self.cache = cache
            self.searchQuerying = nil
            self.searchUnavailableReason = "The system cache directory is unavailable."
            return
        }

        let indexURL = Self.searchIndexURL(forHistoryDirectory: historyDirectory)
        do {
            let index = try SearchIndex(url: indexURL)
            self.cache = SearchIndexReconciliation(cache: cache, index: index)
            self.searchQuerying = index
            self.searchUnavailableReason = nil
        } catch {
            self.cache = cache
            self.searchQuerying = nil
            self.searchUnavailableReason = error.localizedDescription
            Log.error("Search index unavailable; using transcript cache only: \(error)")
        }
    }

    /// Search lives beside the default history directory, and inside any
    /// injected temporary directory so tests never open the user cache.
    private static func searchIndexURL(forHistoryDirectory historyDirectory: URL) -> URL {
        if let defaultDirectory = HistoryCache.defaultDirectory(),
           historyDirectory.resolvingSymlinksInPath() == defaultDirectory.resolvingSymlinksInPath() {
            return historyDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("search.sqlite", isDirectory: false)
        }
        return historyDirectory.appendingPathComponent("search.sqlite", isDirectory: false)
    }

    // MARK: - Lifecycle
    /// Reconnect silently when a stored session is already present, so a
    /// relaunch lands straight in the chat.
    func restoreOrPromptSignIn() async {
        await loadOrganizationIfNeeded()
        // Cache disablement is a privacy/storage promise and must not depend
        // on auth or network success. Recover an interrupted purge before
        // attempting either.
        if !cacheEnabled {
            warmStore.clear()
            let cleared = (try? await cache.clear()) == true
            if !cleared {
                Log.error("cache: could not finish disabled-on-launch purge")
            }
            cacheCachedCount = 0
            cacheTotalCount = 0
            cacheBytes = 0
            isCacheWarming = false
        }

        guard let url = serverURL else {
            phase = .failed(AuthError.badServerURL.localizedDescription)
            return
        }
        let auth = AuthClient(server: url, openURL: { NSWorkspace.shared.open($0) })
        self.auth = auth
        do {
            guard try await auth.loadStoredCredentials() != nil else {
                phase = .signedOut
                return
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        await refreshGatewayDiscovery(using: auth)
        accountIdentity = await auth.fetchAccountIdentity()
        await connect()
    }

    private func loadOrganizationIfNeeded() async {
        guard !organizationLoaded else {
            applyOrganizationForCurrentGateway()
            return
        }
        do {
            let organization = try await organizationStore.load()
            organizationLoaded = true
            applyOrganization(organization)
        } catch {
            postError("Could not load sidebar organization", detail: error.localizedDescription)
        }
    }

    /// The only seam that publishes organization state. The snapshot and all
    /// visible fields change together, so reconnects cannot restore launch
    /// state over a successful mutation.
    private func applyOrganization(_ organization: SessionOrganization) {
        organizationSnapshot = organization
        sortMode = organization.sort.mode
        groupByDate = organization.grouping.byDate
        folders = organization.folders
        membership = configuredGatewayHost
            .flatMap { organization.gateways[$0]?.folderMembership }
            ?? [:]
    }

    private func applyOrganizationForCurrentGateway() {
        guard let organization = organizationSnapshot else { return }
        applyOrganization(organization)
    }

    private func refreshOrganizationAfterMutation() async throws {
        applyOrganization(try await organizationStore.load())
    }

    func signIn() async {
        accountGeneration += 1
        await loadOrganizationIfNeeded()
        guard let url = serverURL else {
            phase = .failed(AuthError.badServerURL.localizedDescription)
            return
        }
        UserDefaults.standard.set(serverText, forKey: Self.serverKey)
        let auth = AuthClient(server: url, openURL: { NSWorkspace.shared.open($0) })
        self.auth = auth
        await refreshGatewayDiscovery(using: auth)

        phase = .connecting
        do {
            Log.info("signIn: starting native PKCE flow against \(url.absoluteString)")
            _ = try await auth.signIn()
            accountIdentity = await auth.fetchAccountIdentity()
            Log.info("signIn: token exchange succeeded")
            await connect()
        } catch {
            Log.error("signIn failed: \(error)")
            phase = .failed(error.localizedDescription)
        }
    }

    func signOut() async {
        pendingExternalRoute.clearPending()
        _ = openGenerations.begin()
        accountGeneration += 1
        archivedLoadGeneration += 1
        purgePreparationGeneration += 1
        pendingExternalRoute.clearPending()
        pendingMessageRoute = nil
        sessionsLoadedCompletely = false
        warmStore.clear()
        // Clear all account-owned rows before the first suspension point.
        sessions = []
        archivedSessions = []
        setSelectedSessionID(nil, event: "selectedSessionID.signOut")
        viewingArchivedSessionID = nil
        phase = .signedOut
        eventTask?.cancel()
        eventTask = nil
        cancelPrefetch()
        cacheControlTask?.cancel()
        cacheControlTask = nil
        cacheControlGeneration += 1
        composerModel.shutdown()
        composerRuntime = nil
        clearActiveTranscriptStore()
        await gateway?.disconnect()
        gateway = nil
        rest = nil
        await auth?.signOut()
        // Transcripts are another user's data once signed out.
        _ = try? await cache.clear()
        cacheCachedCount = 0
        cacheTotalCount = 0
        cacheBytes = 0
        isCacheWarming = false
        accountIdentity = nil
        discoveredProvider = nil
        gatewayAdvertisedMethods = [.browserPKCE]
        streamingReducer.reset()
        messages = []
        isAwaitingReply = streamingReducer.isAwaitingReply
        sessionsLoadedCompletely = false
        isSearchPresented = false
        toastPresenter.setSuppressed(false)
        capabilityModule = nil
        composerRuntimeSnapshot = SessionRuntimeSnapshot(
            model: nil,
            provider: nil,
            reasoning: nil,
            isRunning: false
        )
        composerDefaultModel = nil
        composerDefaultProvider = nil
        composerDefaultReasoning = nil
        composerDefaultsUnavailableReason = nil
        sessionPurgeCapability = nil
        sessionPurgeUnavailableReason = "Complete deletion is unavailable on this gateway."
    }
    private func refreshGatewayDiscovery(using auth: AuthClient) async {
        guard let providers = await auth.discoverProviders() else {
            discoveredProvider = nil
            // Discovery is optional: the browser flow remains the only
            // supported client method when the endpoint is unavailable.
            gatewayAdvertisedMethods = [.browserPKCE]
            return
        }
        discoveredProvider = providers.first
        // Password auth is not implemented by this client yet.
        gatewayAdvertisedMethods = [.browserPKCE]
    }

    func setAuthenticationMethod(_ requested: AuthMethod) {
        let status = gatewayStatus
        guard let method = AuthMethod.validatedSelection(
            requested,
            from: status.availableMethods
        ) else {
            toastPresenter.error(
                "Authentication method unavailable",
                detail: "\(requested.displayName) is not supported by this gateway."
            )
            return
        }
        AuthMethodStore.save(method, gateway: status.url)
    }

    private func isUnsupportedComposerDefaultsError(_ error: Error) -> Bool {
        guard let gatewayError = error as? GatewayError else { return false }
        guard case let .rpc(code, message) = gatewayError else { return false }
        let normalized = message.lowercased()
        return (code == 4002 || code == 40002)
            && normalized.contains("unknown config key")
    }
    /// Reads gateway-wide composer defaults. This intentionally omits
    /// `session_id`: these values apply to future chats, not the open turn.
    func loadComposerDefaults() async {
        guard composerDefaultsUnavailableReason == nil, let gateway else { return }
        do {
            let response = try await gateway.call("config.get")
            let values: [String: JSONValue]
            if case let .object(root) = response,
               case let .object(config)? = root["config"] {
                values = config
            } else if case let .object(root) = response {
                values = root
            } else {
                values = [:]
            }
            composerDefaultModel = values["model"]?.stringValue
            composerDefaultProvider = values["provider"]?.stringValue
            if let raw = values["reasoning"]?.stringValue
                ?? values["reasoning_effort"]?.stringValue {
                let normalized = raw.lowercased()
                composerDefaultReasoning = normalized == "none"
                    ? .off
                    : ReasoningEffort(rawValue: normalized).map(ReasoningSetting.effort)
            }
        } catch {
            if isUnsupportedComposerDefaultsError(error) {
                composerDefaultsUnavailableReason = "This gateway does not support global model defaults."
            } else {
                postError("Could not load model defaults", detail: error.localizedDescription)
            }
        }
    }

    func setComposerDefaults(
        model: String?,
        provider: String?,
        reasoning: ReasoningSetting?
    ) async {
        guard composerDefaultsUnavailableReason == nil, let gateway else {
            if composerDefaultsUnavailableReason == nil {
                postError("Could not save model defaults", detail: "The gateway connection is unavailable.")
            }
            return
        }
        do {
            if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let normalizedProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
                let wireValue: String
                if let normalizedProvider, !normalizedProvider.isEmpty {
                    wireValue = "\(model) --provider \(normalizedProvider)"
                } else {
                    wireValue = model
                }
                _ = try await gateway.call(
                    "config.set",
                    params: ["key": "model", "value": wireValue]
                )
            }
            if let reasoning {
                _ = try await gateway.call(
                    "config.set",
                    params: ["key": "reasoning", "value": reasoning.wireValue]
                )
            }
            composerDefaultModel = model
            composerDefaultProvider = provider
            composerDefaultReasoning = reasoning
        } catch {
            if isUnsupportedComposerDefaultsError(error) {
                composerDefaultsUnavailableReason = "This gateway does not support global model defaults."
            } else {
                postError("Could not save model defaults", detail: error.localizedDescription)
            }
        }
    }

    func requestFind() {
        guard case .ready = phase else { return }
        findRequestGeneration &+= 1
    }

    func requestComposerFocus() {
        composerFocusRequestGeneration &+= 1
    }

    func toggleSearch() {
        guard searchQuerying != nil else {
            toastPresenter.error(
                "Search unavailable",
                detail: searchUnavailableReason ?? "The local search index could not be opened."
            )
            return
        }
        isSearchPresented.toggle()
    }

    // MARK: - Connection

    private func connect() async {
        await loadOrganizationIfNeeded()
        guard let auth, let url = serverURL else { return }
        phase = .connecting
        do {
            let ticket = try await auth.webSocketTicket()
            Log.info("connect: minted ws ticket")
            let gateway = GatewayClient()
            self.gateway = gateway
            try await gateway.connect(server: url, ticket: ticket.ticket)
            installComposer(gateway: gateway)
            Log.info("connect: websocket dialed")
            rest = RestClient(server: url, auth: auth)
            let capabilities = GatewayCapabilityModule(server: url, auth: auth)
            capabilityModule = capabilities
            let snapshot = try await capabilities.snapshot()
            sessionPurgeCapability = snapshot.sessionPurge
            sessionPurgeUnavailableReason = snapshot.unavailableReason
                ?? "Complete deletion is unavailable on this gateway."
            observeEvents(on: gateway)
            phase = .ready
            await loadComposerDefaults()
            await loadSessions()
        } catch is CancellationError {
            return
        } catch {
            Log.error("connect failed: \(error)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func observeEvents(on gateway: GatewayClient) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in gateway.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    // MARK: - Sessions

    func loadSessions() async {
        guard let rest else { return }
        sessionsLoadedCompletely = false
        do {
            // The gateway already denies tool and kanban rows. Subagent rows
            // are machine sessions, not chats, and the server excludes them.
            let rows = try await rest.allSessions(excludeSources: Self.nonChatSources)
            sessions = rows.compactMap { row in
                let session = ChatSession(from: row)
                guard !session.id.isEmpty else { return nil }
                return session
            }
            // A complete authoritative list supersedes every in-flight warm
            // pass before retention or disk/index reconciliation can run.
            cancelPrefetch()
            sessions.sort(by: Self.sessionComesBefore)
            if viewingArchivedSessionID == nil,
               selectedSessionID == nil,
               let liveSessionID,
               sessions.contains(where: { candidate in candidate.id == liveSessionID }) {
                // Bind the new durable row to the live session. A full open
                // would reset the reducer and drop the first turn.
                // Defended by adoptingNewChatKeepsInFlightSend.
                setSelectedSessionID(
                    liveSessionID,
                    event: "selectedSessionID.liveBecameDurable",
                    preserveDisplayedTranscript: true
                )
            } else if viewingArchivedSessionID == nil,
               let selectedSessionID,
               !sessions.contains(where: { candidate in candidate.id == selectedSessionID }) {
                clearActiveTranscriptIfNeeded(selectedSessionID)
            }
            sessionsLoadedCompletely = true
            warmStore.retain(sessionIDs: Set(sessions.map(\.id)))
            drainPendingExternalRouteIfReady()
            cacheTotalCount = sessions.count
            Log.info("REST session list returned \(sessions.count) sessions")
            let expectedAccountGeneration = accountGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshCacheStatistics()
                guard self.accountGeneration == expectedAccountGeneration,
                      self.sessionsLoadedCompletely
                else { return }
                self.prefetchTranscripts()
            }
        } catch {
            Log.error("REST session list failed: \(error)")
            postError("Could not load sessions", detail: error.localizedDescription)
        }
    }
    func loadArchivedSessions() async {
        archivedLoadGeneration += 1
        let loadGeneration = archivedLoadGeneration
        let requestAccountGeneration = accountGeneration
        archivedSessions = []
        archivedSessionsError = nil
        archivedSessionsLoading = true
        defer {
            if archivedLoadGeneration == loadGeneration,
               accountGeneration == requestAccountGeneration {
                archivedSessionsLoading = false
            }
        }
        guard let rest else {
            archivedSessionsError = "The server connection is unavailable."
            return
        }
        do {
            let rows = try await rest.allSessions(
                archived: .only,
                excludeSources: Self.nonChatSources
            )
            guard archivedLoadGeneration == loadGeneration,
                  accountGeneration == requestAccountGeneration,
                  !Task.isCancelled
            else { return }
            archivedSessions = rows.compactMap { row in
                let session = ChatSession(from: row)
                return session.id.isEmpty ? nil : session
            }
            archivedSessions.sort(by: Self.sessionComesBefore)
        } catch is CancellationError {
            return
        } catch {
            guard archivedLoadGeneration == loadGeneration,
                  accountGeneration == requestAccountGeneration
            else { return }
            archivedSessions = []
            archivedSessionsError = error.localizedDescription
        }
    }
    func restoreArchived(_ selected: [ChatSession]) async {
        pendingExternalRoute.clearPending()
        let generation = openGenerations.begin()
        pendingMessageRoute = nil
        let previewID = viewingArchivedSessionID
        await setArchived(selected, archived: false)
        guard openGenerations.isCurrent(generation), !Task.isCancelled else { return }
        await loadArchivedSessions()
        guard openGenerations.isCurrent(generation), !Task.isCancelled else { return }
        guard let previewID,
              selected.contains(where: { $0.id == previewID }),
              let restored = sessions.first(where: { $0.id == previewID })
        else { return }
        viewingArchivedSessionID = nil
        guard openGenerations.isCurrent(generation) else { return }
        _ = await open(restored)
    }
    func restoreArchived(_ session: ChatSession) async {
        pendingExternalRoute.clearPending()
        let generation = openGenerations.begin()
        pendingMessageRoute = nil
        guard let rest else {
            postError("Could not restore chat", detail: "The server connection is unavailable.")
            return
        }
        do {
            _ = try await rest.patchSession(
                durableID: session.id,
                archived: false,
                profile: session.profile
            )
        } catch {
            guard openGenerations.isCurrent(generation) else { return }
            postError("Could not restore chat", detail: error.localizedDescription)
            return
        }
        guard openGenerations.isCurrent(generation), !Task.isCancelled else { return }
        await loadSessions()
        guard openGenerations.isCurrent(generation), !Task.isCancelled else { return }
        await loadArchivedSessions()
        guard openGenerations.isCurrent(generation), !Task.isCancelled else { return }
        viewingArchivedSessionID = nil
        let restored = sessions.first(where: { $0.id == session.id })
            ?? session.withArchived(false)
        guard openGenerations.isCurrent(generation) else { return }
        _ = await open(restored)
    }

    // MARK: - Sidebar organization

    func copyDeepLink(for session: ChatSession) {
        copyDeepLinks(for: [session])
    }

    /// Writes all links in visible order with one pasteboard transaction.
    /// There is deliberately no success toast: the pasteboard is the result.
    func copyDeepLinks(for sessions: [ChatSession]) {
        guard let host = configuredGatewayHost else {
            postError("Could not copy links", detail: "The gateway address is unavailable.")
            return
        }
        let links = sessions.compactMap {
            MessageDeepLink(gatewayHost: host, sessionID: $0.id)?.url.absoluteString
        }
        guard !links.isEmpty else {
            postError("Could not copy links", detail: "No valid chat links were available.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }

    func createFolder(named name: String) async {
        do {
            _ = try await organizationStore.createFolder(name: name)
            try await refreshOrganizationAfterMutation()
        } catch {
            postError("Could not create folder", detail: error.localizedDescription)
        }
    }

    func renameFolder(id: String, to name: String) async {
        do {
            try await organizationStore.renameFolder(id: id, name: name)
            try await refreshOrganizationAfterMutation()
        } catch {
            postError("Could not rename folder", detail: error.localizedDescription)
        }
    }

    func deleteFolder(id: String) async {
        await deleteFolders(ids: [id])
    }

    func deleteFolders(ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            _ = try await organizationStore.deleteFolders(ids: ids)
            try await refreshOrganizationAfterMutation()
        } catch {
            postError("Could not delete folders", detail: error.localizedDescription)
        }
    }
    func reorderFolders(ids: [String]) async {
        do {
            try await organizationStore.reorderFolders(ids: ids)
            try await refreshOrganizationAfterMutation()
        } catch {
            postError("Could not reorder folders", detail: error.localizedDescription)
        }
    }

    /// Deletes selected folders locally without touching their chats.
    func deleteFoldersOnly(ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            _ = try await organizationStore.deleteFolders(ids: uniqueIDs(ids))
            try await refreshOrganizationAfterMutation()
        } catch {
            postError("Could not delete folders", detail: error.localizedDescription)
        }
    }

    /// Resolves an immutable purge plan from complete server rows and local
    /// organization membership. The plan is the only input accepted by
    /// execution, so membership changes after confirmation cannot add chats.
    func preparePurge(
        selectedChatIDs: [String],
        selectedFolderIDs: [String],
        mode: SessionPurgeActionMode
    ) async -> SessionPurgePlan? {
        purgePreparationGeneration += 1
        let preparationGeneration = purgePreparationGeneration
        let requestAccountGeneration = accountGeneration
        guard let rest else {
            postError("Complete deletion unavailable", detail: sessionPurgeUnavailableReason)
            return nil
        }
        do {
            let rows = try await rest.allSessions(
                archived: .include,
                excludeSources: Self.nonChatSources
            )
            guard purgePreparationGeneration == preparationGeneration,
                  accountGeneration == requestAccountGeneration,
                  !Task.isCancelled
            else { return nil }
            let organization = try await organizationStore.load()
            guard purgePreparationGeneration == preparationGeneration,
                  accountGeneration == requestAccountGeneration,
                  !Task.isCancelled
            else { return nil }
            let authoritativeSessions = rows.compactMap { row -> ChatSession? in
                let session = ChatSession(from: row)
                return session.id.isEmpty ? nil : session
            }
            let host = serverURL?.host
            let completeMembership = host
                .flatMap { organization.gateways[$0]?.folderMembership }
                ?? [:]
            let folderIDs = Set(organization.folders.map(\.id))
            let requestedFolders = selectedFolderIDs.filter { folderIDs.contains($0) }
            return SessionPurgePolicy.plan(
                selectedChatIDs: selectedChatIDs,
                selectedFolderIDs: requestedFolders,
                mode: mode,
                membership: completeMembership,
                visibleChatIDs: authoritativeSessions.map(\.id),
                activeSessionID: selectedSessionID,
                isStreaming: isAwaitingReply,
                authoritativeSessions: authoritativeSessions
            )
        } catch is CancellationError {
            return nil
        } catch {
            guard purgePreparationGeneration == preparationGeneration,
                  accountGeneration == requestAccountGeneration
            else { return nil }
            postError("Could not prepare deletion", detail: error.localizedDescription)
            return nil
        }
    }

    /// Executes the exact immutable plan shown by the confirmation surface.
    func purge(plan: SessionPurgePlan) async {
        guard !Task.isCancelled else {
            cancelPrefetch()
            return
        }
        let requestAccountGeneration = accountGeneration
        guard !plan.blockedByActiveStream else {
            postError("Cannot delete the active chat", detail: "Wait for its response to finish.")
            return
        }
        guard !plan.isEmpty else {
            postError("Nothing to delete", detail: "The selected chats and folders are no longer available.")
            return
        }

        if plan.chatIDs.isEmpty {
            do {
                _ = try await organizationStore.deleteFolders(ids: plan.folderIDs)
                guard accountGeneration == requestAccountGeneration, !Task.isCancelled else { return }
                try await refreshOrganizationAfterMutation()
            } catch is CancellationError {
                return
            } catch {
                guard accountGeneration == requestAccountGeneration else { return }
                postError("Could not delete folders", detail: error.localizedDescription)
            }
            return
        }
        cancelPrefetch()

        guard let rest else {
            postError("Complete deletion unavailable", detail: sessionPurgeUnavailableReason)
            return
        }
        var groups = plan.profileGroups
        if groups.isEmpty {
            groups = [SessionPurgeProfileGroup(profile: nil, chatIDs: plan.chatIDs)]
        }
        var confirmed = Set<String>()
        var failed = Set(plan.chatIDs)
        var groupFailures = 0
        for group in groups {
            guard accountGeneration == requestAccountGeneration, !Task.isCancelled else { return }
            let capability: SessionPurgeCapability?
            if let capabilityModule {
                do {
                    let snapshot = try await capabilityModule.snapshot(profile: group.profile)
                    guard accountGeneration == requestAccountGeneration, !Task.isCancelled else { return }
                    capability = snapshot.sessionPurge
                } catch is CancellationError {
                    return
                } catch {
                    capability = nil
                }
            } else {
                capability = sessionPurgeCapability
            }
            guard accountGeneration == requestAccountGeneration, !Task.isCancelled else { return }
            guard let capability else {
                groupFailures += group.chatIDs.count
                continue
            }
            for batch in batches(group.chatIDs, maxCount: capability.maxBatch) {
                do {
                    let result = try await rest.purgeSessions(
                        ids: batch,
                        capability: capability,
                        profile: group.profile
                    )
                    guard accountGeneration == requestAccountGeneration, !Task.isCancelled else { return }
                    let accepted = Set(result.purged).intersection(Set(batch))
                    confirmed.formUnion(accepted)
                    failed.subtract(accepted)
                } catch is CancellationError {
                    return
                } catch {
                    groupFailures += batch.count
                }
            }
        }
        guard accountGeneration == requestAccountGeneration, !Task.isCancelled else { return }

        guard !confirmed.isEmpty else {
            postError(
                "No chats were deleted",
                detail: groupFailures > 0
                    ? "The gateway did not confirm any selected chat."
                    : sessionPurgeUnavailableReason
            )
            return
        }

        // The server result reconciles rows even when local storage fails.
        _ = openGenerations.begin()
        pendingMessageRoute = nil
        cancelPrefetch()
        warmStore.remove(sessionIDs: confirmed)
        var cleanupFailures: [String] = []
        for id in confirmed.sorted() {
            do {
                let result = try await cache.remove(sessionID: id)
                guard accountGeneration == requestAccountGeneration, !Task.isCancelled else { return }
                if !result.succeeded {
                    cleanupFailures.append(
                        "\(id): cache \(result.cache), index \(result.index)"
                    )
                }
            } catch {
                guard accountGeneration == requestAccountGeneration else { return }
                cleanupFailures.append("\(id): \(error.localizedDescription)")
            }
        }
        sessions.removeAll { confirmed.contains($0.id) }
        archivedSessions.removeAll { confirmed.contains($0.id) }
        if let selectedSessionID, confirmed.contains(selectedSessionID) {
            self.setSelectedSessionID(nil, event: "selectedSessionID.purge")
            viewingArchivedSessionID = nil
            liveSessionID = nil
            messages = []
            clearActiveTranscriptStore()
            streamingReducer.reset()
            isAwaitingReply = streamingReducer.isAwaitingReply
            updateComposerRoute()
        }

        let reconciliation = SessionPurgePolicy.reconcile(
            requestedIDs: plan.chatIDs,
            result: SessionPurgeResult(
                object: "hermes.session.purge_result",
                complete: failed.isEmpty,
                purged: Array(confirmed),
                retainedBranches: [],
                failed: []
            ),
            folderIDs: Set(plan.folderIDs),
            membership: plan.folderMembership
        )
        var organizationChanged = false
        guard let gatewayHost = configuredGatewayHost else {
            return
        }
        do {
            organizationChanged = try await organizationStore.reconcilePurge(
                confirmedSessionIDs: confirmed,
                folderIDs: reconciliation.removableFolderIDs,
                gatewayHost: gatewayHost
            )
            guard accountGeneration == requestAccountGeneration, !Task.isCancelled else { return }
        } catch {
            guard accountGeneration == requestAccountGeneration else { return }
            cleanupFailures.append("organization: \(error.localizedDescription)")
        }
        if organizationChanged {
            do {
                try await refreshOrganizationAfterMutation()
                guard accountGeneration == requestAccountGeneration, !Task.isCancelled else { return }
            } catch {
                guard accountGeneration == requestAccountGeneration else { return }
                cleanupFailures.append("organization refresh: \(error.localizedDescription)")
            }
        }
        let retainedDetail = failed.isEmpty ? nil : "\(failed.count) selected chat(s) were retained."
        let detail: String?
        if cleanupFailures.isEmpty {
            detail = retainedDetail
        } else {
            detail = [retainedDetail, "Local cleanup is incomplete.", cleanupFailures.joined(separator: "; ")]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        toastPresenter.post(
            ToastMessage(
                id: ToastID("purge-\(UUID().uuidString)"),
                title: cleanupFailures.isEmpty
                    ? "Deleted \(confirmed.count) chat(s) permanently"
                    : "Deleted \(confirmed.count) chat(s), but local cleanup is incomplete",
                detail: detail,
                severity: cleanupFailures.isEmpty

                    ? (failed.isEmpty ? .success : .warning)
                    : .error
            )
        )
    }
    private func clearActiveTranscriptIfNeeded(_ sessionID: String) {
        guard selectedSessionID == sessionID else { return }
        setSelectedSessionID(nil, event: "selectedSessionID.clear")
        viewingArchivedSessionID = nil
        liveSessionID = nil
        pendingMessageRoute = nil
        messages = []
        clearActiveTranscriptStore()
        streamingReducer.reset()
        isAwaitingReply = streamingReducer.isAwaitingReply
    }
    /// Leaves the archived transcript preview without opening another session.
    /// Invalidating the open generation prevents a delayed cache/REST phase
    /// from restoring read-only state after explicit Chats navigation.
    func leaveArchivedView() {
        _ = openGenerations.begin()
        pendingExternalRoute.clearPending()
        pendingMessageRoute = nil
        viewingArchivedSessionID = nil
        setSelectedSessionID(nil, event: "selectedSessionID.leaveArchived")
        liveSessionID = nil
        messages = []
        clearActiveTranscriptStore()
        composerText = ""
        streamingReducer.reset()
        isAwaitingReply = streamingReducer.isAwaitingReply
    }

    /// Shows the live chat list. An archived preview is read-only, so leaving
    /// it is part of the same command.
    func showChatsList() {
        if viewingArchivedSessionID != nil {
            leaveArchivedView()
        }
        sidebarContentMode = .chats
    }

    /// Shows the archived chat list. The list is fetched on demand, because
    /// the archive is not part of the sidebar's normal load.
    func showArchivedList() async {
        sidebarContentMode = .archived
        await loadArchivedSessions()
    }

    /// Raises the New Folder prompt. The sidebar column presents it.
    func beginFolderCreate() {
        isCreatingFolder = true
    }
    

    private func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }


    private func batches(_ ids: [String], maxCount: Int) -> [[String]] {
        guard maxCount > 0 else { return [] }
        var result: [[String]] = []
        result.reserveCapacity((ids.count + maxCount - 1) / maxCount)
        var index = 0
        while index < ids.count {
            let end = min(index + maxCount, ids.count)
            result.append(Array(ids[index..<end]))
            index = end
        }
        return result
    }

    func assign(_ session: ChatSession, toFolder folderID: String) async {
        guard let host = configuredGatewayHost else {
            postError("Could not move chat", detail: "The gateway address is unavailable.")
            return
        }
        do {
            try await organizationStore.assignChat(
                sessionID: session.id,
                toFolderID: folderID,
                gatewayHost: host
            )
            try await refreshOrganizationAfterMutation()
        } catch {
            postError("Could not move chat", detail: error.localizedDescription)
        }
    }

    func unassign(_ session: ChatSession) async {
        guard let host = configuredGatewayHost else {
            postError("Could not remove chat from folder", detail: "The gateway address is unavailable.")
            return
        }
        do {
            try await organizationStore.clearChatAssignment(
                sessionID: session.id,
                gatewayHost: host
            )
            try await refreshOrganizationAfterMutation()
        } catch {
            postError("Could not remove chat from folder", detail: error.localizedDescription)
        }
    }
    /// Moves or unfiles a selection with one organization refresh. Each
    /// request is independent so a failed chat remains truthful.
    func assign(_ selected: [ChatSession], toFolder folderID: String?) async {
        guard let host = configuredGatewayHost else {
            postError(
                folderID == nil ? "Could not remove chats from folder" : "Could not move chats",
                detail: "The gateway address is unavailable."
            )
            return
        }
        var unique = [ChatSession]()
        var seen = Set<String>()
        for session in selected where seen.insert(session.id).inserted {
            unique.append(session)
        }
        guard !unique.isEmpty else { return }

        var failures = 0
        for session in unique {
            do {
                if let folderID {
                    try await organizationStore.assignChat(
                        sessionID: session.id,
                        toFolderID: folderID,
                        gatewayHost: host
                    )
                } else {
                    try await organizationStore.clearChatAssignment(
                        sessionID: session.id,
                        gatewayHost: host
                    )
                }
            } catch {
                failures += 1
            }
        }
        if failures < unique.count {
            do {
                try await refreshOrganizationAfterMutation()
            } catch {
                postError("Could not refresh folders", detail: error.localizedDescription)
                return
            }
        }
        if failures > 0 {
            postError(
                folderID == nil
                    ? "Could not remove \(failures) of \(unique.count) chats"
                    : "Could not move \(failures) of \(unique.count) chats",
                detail: "The remaining \(unique.count - failures) chat(s) were updated."
            )
        }
    }

    func setSortMode(_ mode: SortMode) async {
        do {
            try await organizationStore.setSortMode(mode)
            try await refreshOrganizationAfterMutation()
        } catch {
            postError("Could not save sidebar sorting", detail: error.localizedDescription)
        }
    }
    func setGroupByDate(_ enabled: Bool) async {
        do {
            try await organizationStore.setGrouping(byDate: enabled)
            try await refreshOrganizationAfterMutation()
        } catch {
            postError("Could not save sidebar grouping", detail: error.localizedDescription)
        }
    }

    /// Changes the server pin state without waiting for the network to move the row.
    func setPinned(_ session: ChatSession, pinned: Bool) async {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let previous = sessions[index]
        sessions[index] = previous.withPinned(pinned)
        sessions.sort(by: Self.sessionComesBefore)

        guard let rest else {
            if let index = sessions.firstIndex(where: { $0.id == session.id }),
               sessions[index].pinned == pinned {
                sessions[index] = previous
                sessions.sort(by: Self.sessionComesBefore)
            }
            postError("Could not update pin", detail: "The server connection is unavailable.")
            return
        }

        do {
            _ = try await rest.patchSession(
                durableID: session.id,
                pinned: pinned,
                profile: session.profile
            )
        } catch {
            if let restError = error as? RestError, case .sessionNotFound = restError {
                sessions.removeAll { $0.id == session.id }
                postError("Chat no longer exists", detail: error.localizedDescription)
                return
            }
            if let index = sessions.firstIndex(where: { $0.id == session.id }),
               sessions[index].pinned == pinned {
                sessions[index] = previous
                sessions.sort(by: Self.sessionComesBefore)
            }
            postError("Could not update pin", detail: error.localizedDescription)
        }
    }

    /// Changes the server pin state for a selection. The local optimistic
    /// update is rolled back per failed request.
    func setPinned(_ selected: [ChatSession], pinned: Bool) async {
        var unique = [ChatSession]()
        var seen = Set<String>()
        for session in selected where seen.insert(session.id).inserted {
            guard sessions.contains(where: { $0.id == session.id }) else { continue }
            unique.append(session)
        }
        guard !unique.isEmpty else { return }

        var previous = [String: ChatSession](minimumCapacity: unique.count)
        for session in unique {
            guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { continue }
            previous[session.id] = sessions[index]
            sessions[index] = sessions[index].withPinned(pinned)
        }
        sessions.sort(by: Self.sessionComesBefore)

        guard let rest else {
            for session in unique {
                if let old = previous[session.id],
                   let index = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[index] = old
                }
            }
            sessions.sort(by: Self.sessionComesBefore)
            postError("Could not update pins", detail: "The server connection is unavailable.")
            return
        }

        var failures = 0
        for session in unique {
            do {
                _ = try await rest.patchSession(
                    durableID: session.id,
                    pinned: pinned,
                    profile: session.profile
                )
            } catch {
                failures += 1
                if let restError = error as? RestError, case .sessionNotFound = restError {
                    sessions.removeAll { $0.id == session.id }
                } else if let old = previous[session.id],
                          let index = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[index] = old
                }
            }
        }
        sessions.sort(by: Self.sessionComesBefore)
        if failures > 0 {
            postError(
                "Could not update \(failures) of \(unique.count) pins",
                detail: "The remaining \(unique.count - failures) chat(s) were updated."
            )
        }
    }

    /// Changes the server title while keeping the sidebar responsive.
    func rename(_ session: ChatSession, to newTitle: String) async {
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            postError("Could not rename chat", detail: "The title cannot be empty.")
            return
        }
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let previous = sessions[index]
        sessions[index] = previous.withTitle(trimmedTitle)
        sessions.sort(by: Self.sessionComesBefore)

        guard let rest else {
            if let index = sessions.firstIndex(where: { $0.id == session.id }),
               sessions[index].title == trimmedTitle {
                sessions[index] = previous
                sessions.sort(by: Self.sessionComesBefore)
            }
            postError("Could not rename chat", detail: "The server connection is unavailable.")
            return
        }

        do {
            _ = try await rest.patchSession(
                durableID: session.id,
                title: trimmedTitle,
                profile: session.profile
            )
        } catch {
            if let restError = error as? RestError, case .sessionNotFound = restError {
                sessions.removeAll { $0.id == session.id }
                postError("Chat no longer exists", detail: error.localizedDescription)
                return
            }
            if let index = sessions.firstIndex(where: { $0.id == session.id }),
               sessions[index].title == trimmedTitle {
                sessions[index] = previous
                sessions.sort(by: Self.sessionComesBefore)
            }
            postError("Could not rename chat", detail: error.localizedDescription)
        }
    }

    /// Changes the server archive state while keeping the sidebar responsive.
    func setArchived(_ session: ChatSession, archived: Bool) async {
        let previous: ChatSession
        if archived {
            guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
            previous = sessions.remove(at: index)
        } else {
            let restored = session.withArchived(false)
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                previous = sessions[index]
                sessions[index] = restored
            } else {
                previous = restored
                sessions.append(restored)
            }
            sessions.sort(by: Self.sessionComesBefore)
        }

        guard let rest else {
            if archived {
                if !sessions.contains(where: { $0.id == previous.id }) {
                    sessions.append(previous)
                }
                sessions.sort(by: Self.sessionComesBefore)
            } else {
                sessions.removeAll { $0.id == session.id }
            }
            postError(
                archived ? "Could not archive chat" : "Could not restore chat",
                detail: "The server connection is unavailable."
            )
            return
        }

        do {
            _ = try await rest.patchSession(
                durableID: session.id,
                archived: archived,
                profile: session.profile
            )
            if archived {
                clearActiveTranscriptIfNeeded(session.id)
            }
            guard archived else { return }
            toastPresenter.post(
                ToastMessage(
                    id: ToastID("archive-\(session.id)-\(UUID().uuidString)"),
                    title: "Chat archived",
                    severity: .success,
                    action: ToastAction(label: "Undo"),
                    isPersistent: true
                ),
                action: { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.setArchived(session, archived: false)
                    }
                }
            )
        } catch {
            if let restError = error as? RestError, case .sessionNotFound = restError {
                sessions.removeAll { $0.id == session.id }
                postError("Chat no longer exists", detail: error.localizedDescription)
                return
            }
            if archived {
                if !sessions.contains(where: { $0.id == previous.id }) {
                    sessions.append(previous)
                }
                sessions.sort(by: Self.sessionComesBefore)
            } else {
                sessions.removeAll { $0.id == session.id }
            }
            postError(
                archived ? "Could not archive chat" : "Could not restore chat",
                detail: error.localizedDescription
            )
        }
    }
    /// Archives or restores a selection with one operation-level outcome.
    /// Archive keeps one persistent Undo that retries only successful writes.
    func setArchived(_ selected: [ChatSession], archived: Bool) async {
        var unique = [ChatSession]()
        var seen = Set<String>()
        for session in selected
        where session.archived != archived && seen.insert(session.id).inserted {
            unique.append(session)
        }
        guard !unique.isEmpty else { return }
        guard let rest else {
            postError(
                archived ? "Could not archive chats" : "Could not restore chats",
                detail: "The server connection is unavailable."
            )
            return
        }

        let previous = Dictionary(unique.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if archived {
            sessions.removeAll { previous[$0.id] != nil }
        }

        var successful = [ChatSession]()
        var failed = [ChatSession]()
        for session in unique {
            do {
                _ = try await rest.patchSession(
                    durableID: session.id,
                    archived: archived,
                    profile: session.profile
                )
                successful.append(session)
            } catch {
                failed.append(session)
                if !archived, let index = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions.remove(at: index)
                }
            }
        }

        if archived {
            for session in failed where !sessions.contains(where: { $0.id == session.id }) {
                sessions.append(session)
            }
            sessions.sort(by: Self.sessionComesBefore)
            if let selectedSessionID,
               successful.contains(where: { $0.id == selectedSessionID }) {
                clearActiveTranscriptIfNeeded(selectedSessionID)
            }
            guard !successful.isEmpty else {
                let noun = failed.count == 1 ? "chat" : "chats"
                postError(
                    "Could not archive \(failed.count) \(noun)",
                    detail: "No selected chat was archived."
                )
                return
            }
            let detail = failed.isEmpty
                ? nil
                : "\(failed.count) of \(unique.count) chats could not be archived."
            toastPresenter.post(
                ToastMessage(
                    id: ToastID("archive-selection-\(UUID().uuidString)"),
                    title: "Archived \(successful.count) chats",
                    detail: detail,
                    severity: failed.isEmpty ? .success : .warning,
                    action: ToastAction(label: "Undo"),
                    isPersistent: true
                ),
                action: { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.restoreArchivedSessions(successful)
                    }
                }
            )
        } else {
            for session in successful where !sessions.contains(where: { $0.id == session.id }) {
                sessions.append(session.withArchived(false))
            }
            sessions.sort(by: Self.sessionComesBefore)
            if !failed.isEmpty {
                postError(
                    "Could not restore \(failed.count) of \(unique.count) chats",
                    detail: "The remaining \(successful.count) chat(s) were restored."
                )
            }
        }
    }

    private func restoreArchivedSessions(_ archived: [ChatSession]) async {
        guard let rest else {
            postError("Could not restore archived chats", detail: "The server connection is unavailable.")
            return
        }
        var failed = 0
        for session in archived {
            do {
                _ = try await rest.patchSession(
                    durableID: session.id,
                    archived: false,
                    profile: session.profile
                )
                if !sessions.contains(where: { $0.id == session.id }) {
                    sessions.append(session.withArchived(false))
                }
            } catch {
                failed += 1
            }
        }
        sessions.sort(by: Self.sessionComesBefore)
        if failed > 0 {
            postError(
                "Could not restore \(failed) of \(archived.count) chats",
                detail: "The remaining \(archived.count - failed) chat(s) were restored."
            )
        }
    }


    /// Sources whose sessions are machine work rather than chats.
    ///
    /// The gateway denies `tool` and `kanban` itself, so naming them here would
    /// be redundant.
    private static let nonChatSources = ["subagent"]

    private static func sessionComesBefore(_ lhs: ChatSession, _ rhs: ChatSession) -> Bool {
        switch (lhs.lastActive, rhs.lastActive) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        switch (lhs.startedAt, rhs.startedAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        return lhs.id < rhs.id
    }

    func setCacheEnabled(_ enabled: Bool) {
        guard cacheEnabled != enabled else { return }
        // Invalidate every opener before beginning the purge. A delayed
        // opener captured with caching enabled must not write after disable.
        _ = openGenerations.begin()
        cacheEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "cache.enabled")
        cacheControlGeneration += 1
        let generation = cacheControlGeneration
        cancelPrefetch()
        if !enabled {
            warmStore.clear()
        }
        cacheControlTask?.cancel()
        cacheControlTask = Task { [weak self] in
            guard let self else { return }
            if enabled {
                guard generation == cacheControlGeneration, cacheEnabled else { return }
                await refreshCacheStatistics()
                guard generation == cacheControlGeneration, cacheEnabled else { return }
                prefetchTranscripts()
            } else {
                isCacheWarming = false
                guard generation == cacheControlGeneration, !cacheEnabled else { return }
                guard (try? await cache.clear()) == true else {
                    postError("Could not clear the local chat cache.")
                    Log.error("cache: disable purge failed")
                    return
                }
                // A fast re-enable may have superseded this clear. The newer
                // task will reconcile and warm after the actor finishes it.
                guard generation == cacheControlGeneration, !cacheEnabled else { return }
                cacheCachedCount = 0
                cacheBytes = 0
                Log.info("cache: disabled and cleared")
            }
        }
    }

    /// Clear and immediately repopulate because caching remains enabled.
    func rebuildCache() {
        guard cacheEnabled else { return }
        _ = openGenerations.begin()
        cacheControlGeneration += 1
        let generation = cacheControlGeneration
        cancelPrefetch()
        warmStore.clear()
        cacheControlTask?.cancel()
        cacheControlTask = Task { [weak self] in
            guard let self else { return }
            guard generation == cacheControlGeneration, cacheEnabled else { return }
            guard (try? await cache.clear()) == true else {
                postError("Could not rebuild the local chat cache.")
                Log.error("cache: rebuild clear failed")
                return
            }
            guard generation == cacheControlGeneration, cacheEnabled else { return }
            cacheCachedCount = 0
            cacheBytes = 0
            prefetchTranscripts()
        }
    }

    private func refreshCacheStatistics() async {
        guard cacheEnabled else {
            warmStore.clear()
            // Ensures a disabled cache is eventually purged even if the app
            // was terminated before the toggle's asynchronous clear finished.
            guard (try? await cache.clear()) == true else {
                postError("Could not clear the disabled chat cache.")
                Log.error("cache: deferred disabled purge failed")
                isCacheWarming = false
                return
            }
            cacheCachedCount = 0
            cacheBytes = 0
            isCacheWarming = false
            return
        }
        guard sessionsLoadedCompletely else {
            // A partial REST page would make reconcile delete older chats from
            // the cache and search index. Skipping costs disk space; deleting
            // user data cannot be undone.
            Log.info("cache: skipped reconciliation because session list is incomplete")
            return
        }
        guard let statistics = try? await cache.reconcile(validIDs: sessions.map(\.id)) else {
            isCacheWarming = false
            postError("Could not reconcile the local chat cache.")
            return
        }
        cacheCachedCount = statistics.entryCount
        cacheBytes = statistics.bytes
    }

    private func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchGeneration += 1
        isCacheWarming = false
    }

    /// Warm the transcript cache in the background so switching chats never
    /// waits on the network.
    ///
    /// Hydration goes over REST, not `session.resume`: resume registers a
    /// live server-side session, so warming every row through it would spin
    /// up one live agent per chat. Concurrency is bounded so a long chat list
    /// does not fan out into one request per row.
    /// Reconcile cached transcripts in a cancellable background pass. This
    /// path is deliberately independent of selection: it only consumes the
    /// authoritative session list or an explicit refresh request.
    ///
    /// The pass updates durable cache/search and the warm store only. It never
    /// mutates the visible transcript: live streaming owns the active chat,
    /// and fresher content applies at the next activation.
    private func prefetchTranscripts() {
        guard cacheEnabled,
              let source = transcriptSource(sessionID: nil, serverTotal: nil)
        else {
            isCacheWarming = false
            return
        }
        let ordered = sessions.map(\.id)
        guard !ordered.isEmpty else {
            isCacheWarming = false
            return
        }

        prefetchTask?.cancel()
        prefetchGeneration += 1
        let generation = prefetchGeneration
        let expectedAccountGeneration = accountGeneration
        let requests = sessions.map {
            TranscriptSyncRequest(
                id: $0.id,
                serverTotal: $0.messageCount,
                title: $0.title
            )
        }
        let coordinator = TranscriptSyncCoordinator(concurrency: 4)
        isCacheWarming = true
        prefetchTask = Task { [weak self, cache, source] in
            guard let self else { return }
            defer {
                // A superseded task must not clear state owned by a newer
                // account/cache/list generation.
                if generation == self.prefetchGeneration,
                   expectedAccountGeneration == self.accountGeneration {
                    self.isCacheWarming = false
                }
            }

            let expectedEpoch = await cache.currentEpoch()
            guard generation == self.prefetchGeneration,
                  expectedAccountGeneration == self.accountGeneration,
                  self.cacheEnabled,
                  !Task.isCancelled
            else { return }

            await coordinator.reconcile(
                requests,
                cache: cache,
                source: source,
                onResult: { @MainActor result in
                    guard generation == self.prefetchGeneration,
                          expectedAccountGeneration == self.accountGeneration,
                          self.cacheEnabled,
                          !Task.isCancelled,
                          result.messages.count == result.snapshot.projectedMessages
                    else { return }

                    // Re-check after the coordinator's suspension points. A purge
                    // or account change must not let a completed request publish
                    // into the next cache epoch.
                    let currentEpoch = await cache.currentEpoch()
                    guard generation == self.prefetchGeneration,
                          expectedAccountGeneration == self.accountGeneration,
                          self.cacheEnabled,
                          !Task.isCancelled,
                          currentEpoch == expectedEpoch
                    else { return }

                    let serverTotal = requests.first(where: { $0.id == result.id })?.serverTotal
                    HermternalSwitchTrace.session(
                        "transcript.presegment",
                        id: result.id,
                        messages: result.messages.count,
                        renderedRows: result.presegmentedRows,
                        detail: "source=warm"
                    )
                    let resident = self.warmStore.projection(
                        for: result.id,
                        minimumServerTotal: serverTotal
                    )
                    let duplicate = resident.map {
                        self.snapshotMatches($0.snapshot, result.snapshot)
                    } ?? false
                    if !duplicate {
                        _ = self.warmStore.publish(
                            messages: result.messages,
                            snapshot: result.snapshot,
                            for: result.id,
                            minimumServerTotal: serverTotal
                        )
                    }
                    if let cacheStore = result.cacheStore {
                        self.applyCacheStore(cacheStore)
                    }
                }
            )
        }
    }
    private func postError(_ title: String, detail: String? = nil) {
        toastPresenter.error(title, detail: detail)
    }
    private func setSelectedSessionID(
        _ value: String?,
        event: String,
        generation: Int? = nil,
        preserveDisplayedTranscript: Bool = false
    ) {
        HermternalSwitchTrace.session(
            "\(event).before",
            id: selectedSessionID,
            generation: generation,
            messages: messages.count
        )
        // Leaving a route invalidates the painted-transcript signal. It is
        // cleared here rather than at each call site so no future selection
        // path can forget to, which is how a stale "already open" belief
        // strands a row.
        if !preserveDisplayedTranscript, value != selectedSessionID {
            displayedTranscriptSessionID = nil
        }
        selectedSessionID = value
        updateComposerRoute()
        HermternalSwitchTrace.session(
            "\(event).after",
            id: value,
            generation: generation,
            messages: messages.count
        )
    }



    private func applyCacheStore(_ result: CacheStoreResult) {
        if result.addedEntry {
            cacheCachedCount = min(cacheCachedCount + 1, cacheTotalCount)
        }
        cacheBytes = max(0, cacheBytes + result.byteDelta)
    }
    private func clearActiveTranscriptStore() {
        activeTranscriptStore = nil
        activeTranscriptRoute = nil
        transcriptSummary = nil
        activeTranscriptFindCursor = nil
        activeStoreAppGeneration = nil
        transcriptRevision &+= 1
    }

    /// Installs the disk-backed store for the selected route.
    ///
    /// First paint does not wait for this install. A later swap keeps the
    /// displayed transcript. A store generation is advanced for every route
    /// so stale page reads and writes cannot publish into a replacement
    /// selection.
    private func prepareActiveTranscriptStore(
        sessionID: String,
        appGeneration: Int
    ) async {
        guard !sessionID.isEmpty else {
            clearActiveTranscriptStore()
            return
        }
        guard openGenerations.isCurrent(appGeneration), !Task.isCancelled else {
            return
        }
        if activeStoreAppGeneration == appGeneration,
           activeTranscriptRoute?.sessionID == sessionID {
            return
        }
        do {
            let store = try await historyCache.pagedStore(for: sessionID)
            guard openGenerations.isCurrent(appGeneration), !Task.isCancelled else {
                return
            }
            let route = try await store.beginGeneration()
            guard openGenerations.isCurrent(appGeneration), !Task.isCancelled else {
                return
            }
            let summary = try await store.summary()
            guard openGenerations.isCurrent(appGeneration), !Task.isCancelled else {
                return
            }
            activeTranscriptStore = store
            activeTranscriptRoute = route
            transcriptSummary = summary
            activeTranscriptFindCursor = nil
            activeStoreAppGeneration = appGeneration
            transcriptRevision &+= 1
        } catch {
            guard openGenerations.isCurrent(appGeneration), !Task.isCancelled else {
                return
            }
            clearActiveTranscriptStore()
            Log.error("transcript store unavailable for \(sessionID): \(error)")
        }
    }

    private static func wireRecord(from message: ChatMessage) -> WireMessageRecord {
        let messageID: String
        switch message.id {
        case .server(let id): messageID = String(id.rawValue)
        case .provisional(let id): messageID = id.uuidString
        }
        return WireMessageRecord(
            messageID: messageID,
            role: message.role.rawValue,
            text: message.text,
            reasoning: message.reasoning,
            timestamp: message.timestamp,
            turnID: message.turnID
        )
    }

    /// True when the installed route belongs to the selected chat, or to the
    /// live new-chat session when no sidebar row exists yet.
    /// Defended by newChatPersistWritesWithoutDurableSelection.
    private static func transcriptRouteMatchesSelection(
        _ route: TranscriptRoute,
        selectedSessionID: String?,
        liveSessionID: String?
    ) -> Bool {
        if let selectedSessionID {
            return selectedSessionID == route.sessionID
        }
        if let liveSessionID {
            return liveSessionID == route.sessionID
        }
        return true
    }

    /// Persists only the currently published tail. The complete transcript is
    /// already represented by the paged store's disk records.
    func persistTranscriptTail(_ values: [ChatMessage]) async {
        guard let store = activeTranscriptStore,
              let route = activeTranscriptRoute,
              let value = values.last
        else { return }
        // A new chat has no sidebar selection until the first prompt
        // creates a durable row. Persist into the installed live store.
        // Defended by newChatPersistWritesWithoutDurableSelection.
        guard Self.transcriptRouteMatchesSelection(
            route,
            selectedSessionID: selectedSessionID,
            liveSessionID: liveSessionID
        ) else { return }
        // Live rows without a turn id remain durable provisional rows until
        // an authoritative terminal transcript can replace them.
        do {
            let result = try await store.append(
                Self.wireRecord(from: value),
                expectedGeneration: route.generation,
                expectedEpoch: route.epoch
            )
            guard activeTranscriptStore === store,
                  Self.transcriptRouteMatchesSelection(
                    route,
                    selectedSessionID: selectedSessionID,
                    liveSessionID: liveSessionID
                  ),
                  activeTranscriptRoute?.generation == route.generation,
                  activeTranscriptRoute?.epoch == route.epoch
            else { return }
            transcriptSummary = result.summary
            activeTranscriptRoute = TranscriptRoute(
                sessionID: route.sessionID,
                generation: result.generation,
                epoch: result.epoch
            )
            transcriptRevision &+= 1
        } catch {
            Log.error("transcript store stream write failed: \(error)")
        }
    }
    private func refreshActiveTranscriptMetadata(
        _ summaryHint: TranscriptSummary?,
        expectedGeneration: Int? = nil
    ) async {
        guard let store = activeTranscriptStore,
              let route = activeTranscriptRoute
        else { return }
        let appGeneration = expectedGeneration ?? activeStoreAppGeneration
        guard appGeneration.map({ openGenerations.isCurrent($0) }) ?? true else { return }
        do {
            // The store knows descriptor row counts (including split rows);
            // opener metadata counts server messages and must not overwrite it.
            _ = summaryHint
            let summary = try await store.summary()
            let currentRoute = try await store.currentRoute()
            guard activeTranscriptStore === store,
                  selectedSessionID == route.sessionID,
                  activeTranscriptRoute?.sessionID == route.sessionID,
                  appGeneration.map({ openGenerations.isCurrent($0) }) ?? true
            else { return }
            transcriptSummary = summary
            activeTranscriptRoute = currentRoute
            transcriptRevision &+= 1
        } catch {
            Log.error("transcript store metadata refresh failed: \(error)")
        }
    }

    private func hydratePagedTranscriptStore(
        source: any TranscriptSource,
        session: ChatSession,
        generation: Int
    ) async {
        guard let pagedCache = cache as? any PagedTranscriptPersisting,
              let summary = transcriptSummary,
              summary.messageCount == 0,
              let store = activeTranscriptStore,
              openGenerations.isCurrent(generation)
        else { return }
        let expectedEpoch = await cache.currentEpoch()
        guard openGenerations.isCurrent(generation),
              activeTranscriptStore === store
        else { return }
        do {
            let generations = openGenerations
            _ = try await source.streamAuthoritative(sessionID: session.id) { page in
                try Task.checkCancellation()
                guard generations.isCurrent(generation) else {
                    throw CancellationError()
                }
                _ = try await pagedCache.appendTranscriptPage(
                    page,
                    title: session.title,
                    for: session.id,
                    expectedEpoch: expectedEpoch
                )
            }
            guard openGenerations.isCurrent(generation),
                  activeTranscriptStore === store
            else { return }
            await refreshActiveTranscriptMetadata(nil, expectedGeneration: generation)
        } catch {
            Log.error("paged transcript hydration failed for \(session.id): \(error)")
        }
    }

    private func persistTranscriptMessages(
        _ values: [ChatMessage],
        expectedGeneration: Int? = nil
    ) async {
        guard let store = activeTranscriptStore,
              var route = activeTranscriptRoute
        else { return }
        let appGeneration = expectedGeneration ?? activeStoreAppGeneration
        guard appGeneration.map({ openGenerations.isCurrent($0) }) ?? true else { return }
        do {
            for value in values {
                let result = try await store.append(
                    Self.wireRecord(from: value),
                    expectedGeneration: route.generation,
                    expectedEpoch: route.epoch
                )
                guard activeTranscriptStore === store,
                      activeStoreAppGeneration == appGeneration,
                      appGeneration.map({ openGenerations.isCurrent($0) }) ?? true
                else { return }
                route = TranscriptRoute(
                    sessionID: route.sessionID,
                    generation: result.generation,
                    epoch: result.epoch
                )
            }
            guard activeTranscriptStore === store,
                  activeStoreAppGeneration == appGeneration,
                  appGeneration.map({ openGenerations.isCurrent($0) }) ?? true
            else { return }
            activeTranscriptRoute = route
            transcriptSummary = try await store.summary()
            guard activeTranscriptStore === store,
                  activeStoreAppGeneration == appGeneration,
                  appGeneration.map({ openGenerations.isCurrent($0) }) ?? true
            else { return }
            transcriptRevision &+= 1
        } catch {
            Log.error("transcript store full reconciliation write failed: \(error)")
        }
    }

    private var composerRoute: ComposerRoute {
        ComposerRoute(
            identity: selectedSessionID ?? "new",
            generation: UInt64(max(0, transcriptRouteGeneration)),
            liveSessionID: liveSessionID,
            runtime: composerRuntimeSnapshot,
            isAwaitingReply: isAwaitingReply,
            isReadOnly: isViewingArchivedTranscript
        )
    }

    private func updateComposerRoute() {
        composerModel.update(route: composerRoute)
    }

    private func installComposer(gateway: GatewayClient) {
        let runtime = GatewayRuntimeAdapter(gateway: gateway)
        composerModel = ComposerModel(
            route: composerRoute,
            runtime: runtime,
            attachmentStaging: runtime,
            turn: self,
            dictation: SpeechDictationAdapter(),
            recorder: AudioCaptureAdapter()
        )
    }

    func shutdownComposer() {
        composerModel.shutdown()
        composerRuntime = nil
    }
    /// Installs the paged store for the live session. A new chat has no
    /// durable sidebar row until the first prompt, but the transcript reads
    /// this store for the optimistic turn and the stream.
    /// Defended by newChatPersistWritesWithoutDurableSelection.
    private func ensureLiveTranscriptStore() async {
        guard let liveSessionID, !liveSessionID.isEmpty else { return }
        if activeTranscriptStore != nil,
           activeTranscriptRoute?.sessionID == liveSessionID {
            return
        }
        await prepareActiveTranscriptStore(
            sessionID: liveSessionID,
            appGeneration: openGenerations.current()
        )
    }

    func prepareSession(expectedRoute: ComposerRouteToken) async throws -> String {
        guard composerRoute.token == expectedRoute,
              !isViewingArchivedTranscript,
              let gateway
        else { throw GatewayError.unroutableFrame("Composer route changed.") }
        if let liveSessionID {
            return liveSessionID
        }
        let created: JSONValue
        if selectedSessionID != nil {
            guard await establishLiveSessionForInteraction(),
                  composerRoute.token == expectedRoute,
                  let liveSessionID
            else { throw GatewayError.unroutableFrame("Composer route changed.") }
            return liveSessionID
        } else {
            created = try await gateway.call("session.create")
            guard composerRoute.token == expectedRoute else {
                throw GatewayError.unroutableFrame("Composer route changed.")
            }
            guard let id = created["session_id"]?.stringValue, !id.isEmpty else {
                throw GatewayError.malformedFrame("session.create returned no session id.")
            }
            liveSessionID = id
            composerRuntimeSnapshot = GatewayRuntimeAdapter.decodeRuntimeSnapshot(from: created)
            await ensureLiveTranscriptStore()
            updateComposerRoute()
            return id
        }
    }

    /// Echoes the prompt onto the live store before the gateway accepts it.
    ///
    /// Waiting for the RPC leaves the transcript empty until acceptance.
    /// Defended by sendPublishesUserTurnBeforePreparation.
    func publishUserTurn(text: String, route: ComposerRouteToken) {
        guard composerRoute.token == route, !isViewingArchivedTranscript else { return }
        streamingReducer.appendUser(text)
        messages = streamingReducer.messages
        isAwaitingReply = streamingReducer.isAwaitingReply
        updateComposerRoute()
        transcriptPersistGeneration &+= 1
        let persistGeneration = transcriptPersistGeneration
        Task { @MainActor [weak self] in
            guard let self, self.composerRoute.token == route else { return }
            await self.ensureLiveTranscriptStore()
            guard self.transcriptPersistGeneration == persistGeneration else { return }
            await self.persistTranscriptTail(self.streamingReducer.messages)
        }
    }

    /// Removes the optimistic user turn when send fails before acceptance.
    /// Defended by sendRollsBackPublishedTurnOnPreparationFailure.
    func rollbackUserTurn(route: ComposerRouteToken) {
        guard composerRoute.token == route else { return }
        var removedIDs: [String] = []
        if streamingReducer.isAwaitingReply,
           let last = streamingReducer.messages.last,
           last.role == .user {
            switch last.id {
            case .server(let id): removedIDs = [String(id.rawValue)]
            case .provisional(let id): removedIDs = [id.uuidString]
            }
        }
        transcriptPersistGeneration &+= 1
        let reduction = streamingReducer.rollbackUser()
        messages = reduction.messages
        isAwaitingReply = reduction.isAwaitingReply
        updateComposerRoute()
        guard !removedIDs.isEmpty else { return }
        Task { @MainActor [weak self] in
            await self?.removeTranscriptMessageIDs(removedIDs)
        }
    }

    private func removeTranscriptMessageIDs(_ messageIDs: [String]) async {
        guard let store = activeTranscriptStore,
              let route = activeTranscriptRoute,
              Self.transcriptRouteMatchesSelection(
                route,
                selectedSessionID: selectedSessionID,
                liveSessionID: liveSessionID
              )
        else { return }
        do {
            let result = try await store.apply(
                .removeMany(messageIDs: messageIDs),
                expectedGeneration: route.generation,
                expectedEpoch: route.epoch
            )
            guard activeTranscriptStore === store,
                  Self.transcriptRouteMatchesSelection(
                    route,
                    selectedSessionID: selectedSessionID,
                    liveSessionID: liveSessionID
                  )
            else { return }
            transcriptSummary = result.summary
            activeTranscriptRoute = TranscriptRoute(
                sessionID: route.sessionID,
                generation: result.generation,
                epoch: result.epoch
            )
            transcriptRevision &+= 1
        } catch {
            Log.error("transcript store rollback write failed: " + error.localizedDescription)
        }
    }

    func submit(text: String, sessionID: String) async throws {
        guard !isViewingArchivedTranscript,
              let gateway,
              liveSessionID == sessionID,
              composerRoute.liveSessionID == sessionID
        else { throw GatewayError.unroutableFrame("Composer session is no longer active.") }
        let expectedRoute = composerRoute.token
        let generation = openGenerations.current()
        await ensureLiveTranscriptStore()
        composerText = ""
        await persistTranscriptTail(streamingReducer.messages)
        updateComposerRoute()

        do {
            _ = try await gateway.call(
                "prompt.submit",
                params: ["session_id": sessionID, "text": text]
            )
            guard openGenerations.isCurrent(generation),
                  composerRoute.token == expectedRoute,
                  !Task.isCancelled
            else {
                Log.error("composer.send code=confirmed_stale")
                return
            }
        } catch {
            let routeIsCurrent = openGenerations.isCurrent(generation)
                && composerRoute.token == expectedRoute
            if !(error is CancellationError) {
                Log.error(
                    "composer.send code=failed session=\(sessionID) length=\(text.count) error=\(composerSendFailureDetail(error))"
                )
            }
            if routeIsCurrent {
                rollbackUserTurn(route: expectedRoute)
                if !(error is CancellationError) {
                    postError("Send failed", detail: error.localizedDescription)
                }
            }
            throw error
        }
    }

    func stop() async {
        await interrupt()
    }

    func newChat() async {
        pendingExternalRoute.clearPending()
        _ = openGenerations.begin()
        pendingMessageRoute = nil
        viewingArchivedSessionID = nil
        clearActiveTranscriptStore()
        guard let gateway else { return }
        do {
            let result = try await gateway.call("session.create")
            liveSessionID = result["session_id"]?.stringValue
            composerRuntimeSnapshot = GatewayRuntimeAdapter.decodeRuntimeSnapshot(from: result)
            streamingReducer.reset()
            transcriptRouteIdentity = "live:none"
            transcriptRouteGeneration = openGenerations.current()
            messages = []
            isAwaitingReply = streamingReducer.isAwaitingReply
            await ensureLiveTranscriptStore()
            updateComposerRoute()
            // `session.create` does not persist a row until the first
            // prompt, so there is nothing to select in the sidebar yet.
            setSelectedSessionID(nil, event: "selectedSessionID.newChat")
            Log.info("session.create -> live id \(liveSessionID ?? "nil")")
        } catch {
            Log.error("session.create failed: \(error)")
            postError("Could not start a new chat", detail: error.localizedDescription)
        }
    }

    /// New Chat as a user command. A route without a selection gives focus no
    /// place to stay, so the caret moves to the composer. In all other cases
    /// the focus does not move.
    func newChatCommand() async {
        guard phase == .ready else { return }
        let shouldFocusComposer = selectedSessionID == nil
        await newChat()
        if shouldFocusComposer {
            requestComposerFocus()
        }
    }

    /// Open a sidebar row.
    ///
    /// Publishes a resident warm projection on the turn after selection, then
    /// reconciles over the socket to bind the live ephemeral id that
    /// `prompt.submit` requires and to reconcile any drift.
    private func transcriptSource(for session: ChatSession) -> (any TranscriptSource)? {
        if let injectedTranscriptSource { return injectedTranscriptSource }
        guard let gateway, let rest else { return nil }
        return GatewayTranscriptSource(
            gateway: gateway,
            rest: rest,
            serverTotals: [session.id: session.messageCount]
        )
    }
    private func transcriptSource(
        sessionID: String?,
        serverTotal: Int?
    ) -> (any TranscriptSource)? {
        if let injectedTranscriptSource { return injectedTranscriptSource }
        guard let gateway, let rest else {
            HermternalSwitchTrace.selectionGuard(
                "transcriptSource.gateway",
                id: sessionID,
                messages: messages.count,
                reason: "gatewayOrRESTUnavailable"
            )
            return nil
        }
        var totals: [String: Int] = [:]
        if let sessionID, let serverTotal { totals[sessionID] = serverTotal }

        return GatewayTranscriptSource(gateway: gateway, rest: rest, serverTotals: totals)
    }
    /// Routes a validated external destination after session authority exists.
    /// A route received during restore replaces any older queued destination.
    func route(_ destination: MessageDeepLink.Destination) {
        cancelActiveOpen()
        let generation = openGenerations.begin()
        pendingMessageRoute = nil
        let decision = pendingExternalRoute.route(
            destination,
            phase: pendingRoutePhase,
            sessionsLoadedCompletely: sessionsLoadedCompletely
        )
        guard case let .open(destination, routeGeneration) = decision else {
            HermternalSwitchTrace.selectionGuard(
                "externalRoute.routeDecision",
                generation: generation,
                messages: messages.count,
                reason: "routeQueuedOrRejected"
            )
            return
        }
        dispatchExternalRoute(
            destination,
            routeGeneration: routeGeneration,
            generation: generation
        )
    }

    /// Invalidates a queued external route when user navigation opens a new route.
    func userNavigationDidBegin() {
        cancelActiveOpen()
        pendingExternalRoute.clearPending()
        _ = openGenerations.begin()
        pendingMessageRoute = nil
    }

    private var pendingRoutePhase: PendingRouteCoordinator.Phase {
        switch phase {
        case .signedOut: .signedOut
        case .connecting: .connecting
        case .ready: .ready
        case .failed: .failed
        }
    }

    private func drainPendingExternalRouteIfReady() {
        guard phase == .ready,
              let decision = pendingExternalRoute.sessionsLoadedCompletely(phase: pendingRoutePhase),
              case let .open(destination, routeGeneration) = decision
        else {
            HermternalSwitchTrace.selectionGuard(
                "externalRoute.ready",
                messages: messages.count,
                reason: "notReadyOrNoOpenDecision"
            )
            return
        }
        cancelActiveOpen()
        let generation = openGenerations.begin()
        dispatchExternalRoute(
            destination,
            routeGeneration: routeGeneration,
            generation: generation
        )
    }
    private func dispatchExternalRoute(
        _ destination: MessageDeepLink.Destination,
        routeGeneration: Int,
        generation: Int
    ) {
        externalRouteTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self,
                  self.pendingExternalRoute.isCurrent(routeGeneration),
                  self.openGenerations.isCurrent(generation)
            else {
                HermternalSwitchTrace.selectionGuard(
                    "externalRoute.dispatch",
                    generation: generation,
                    messages: self?.messages.count ?? 0,
                    reason: "routeOrOpenGenerationSuperseded"
                )
                return
            }
            await self.openExternalDestination(
                destination,
                routeGeneration: routeGeneration,
                generation: generation
            )
        }
        externalRouteTask = task
    }
    private func openExternalDestination(
        _ destination: MessageDeepLink.Destination,
        routeGeneration: Int,
        generation: Int
    ) async {
        activeOpenHandle?.cancel()
        activeOpenTask?.cancel()
        activeOpenHandle = nil
        activeOpenTask = nil
        guard pendingExternalRoute.isCurrent(routeGeneration),
              openGenerations.isCurrent(generation)
        else {
            HermternalSwitchTrace.selectionGuard(
                "externalRoute.open",
                generation: generation,
                messages: messages.count,
                reason: "routeOrOpenGenerationSuperseded"
            )
            return
        }
        switch destination {
        case .chat(let sessionID):
            await openChat(sessionID: sessionID, generation: generation)
        case .message(let location):
            await open(at: location, generation: generation)
        }
    }
    private func cancelActiveOpen() {
        externalRouteTask?.cancel()
        externalRouteTask = nil
        activeOpenHandle?.cancel()
        activeOpenTask?.cancel()
        activeOpenHandle = nil
        activeOpenTask = nil
        isPreparingOpen = false
        preparingOpenGeneration = nil
    }
    /// Cancels a sidebar open when its hosting view disappears.
    func cancelOpenPreparation() {
        guard isPreparingOpen
            || activeOpenTask != nil
            || activeOpenHandle != nil
            || externalRouteTask != nil
        else {
            HermternalSwitchTrace.selectionGuard(
                "cancelOpenPreparation.noActiveOpen",
                messages: messages.count,
                reason: "idempotentNoOp"
            )
            return
        }
        isPreparingOpen = false
        preparingOpenGeneration = nil
        _ = openGenerations.begin()
        externalRouteTask?.cancel()
        externalRouteTask = nil
        activeOpenHandle?.cancel()
        activeOpenTask?.cancel()
        activeOpenHandle = nil
        activeOpenTask = nil
    }
    private func finishOpenPreparation(generation: Int, sessionID: String) {
        guard preparingOpenGeneration == generation else {
            HermternalSwitchTrace.selectionGuard(
                "requestOpen.preparingOpen.clear",
                id: sessionID,
                generation: generation,
                messages: messages.count,
                reason: "ownerSuperseded;newPreparationOwnsFlag"
            )
            return
        }
        isPreparingOpen = false
        preparingOpenGeneration = nil
        activeOpenTask = nil
        activeOpenHandle = nil
        HermternalSwitchTrace.selectionGuard(
            "requestOpen.preparingOpen.clear",
            id: sessionID,
            generation: generation,
            messages: messages.count,
            reason: "taskFinishedOrCancelledOrSuperseded"
        )
    }
    /// Lets stream events reduce after first paint. The paged-store swap
    /// must not reset the displayed transcript.
    private func releaseOpenEventGate(generation: Int, sessionID: String) {
        guard preparingOpenGeneration == generation else { return }
        isPreparingOpen = false
        HermternalSwitchTrace.selectionGuard(
            "requestOpen.eventGate.release",
            id: sessionID,
            generation: generation,
            messages: messages.count,
            reason: "firstPaintPublished"
        )
    }
    /// Publishes the first transcript snapshot after the selection turn.
    ///
    /// The main-queue hop runs after the current run-loop transaction commits.
    /// The generation check guards the route and content install together.
    @MainActor
    private func publishTranscriptAfterSelectionTurn(
        _ initialMessages: [ChatMessage],
        session: ChatSession,
        generation: Int,
        warm: WarmTranscriptProjection?
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                guard self.openGenerations.isCurrent(generation) else {
                    HermternalSwitchTrace.selectionGuard(
                        "requestOpen.afterSelectionTurn",
                        id: session.id,
                        generation: generation,
                        messages: self.messages.count,
                        reason: "generationSuperseded"
                    )
                    continuation.resume(returning: false)
                    return
                }
                self.transcriptRouteIdentity = "live:\(session.id)"
                self.transcriptRouteGeneration = generation
                self.streamingReducer.reset(messages: initialMessages)
                self.messages = initialMessages
                self.isAwaitingReply = self.streamingReducer.isAwaitingReply
                HermternalSwitchTrace.session(
                    "transcript.publish",
                    id: session.id,
                    generation: generation,
                    messages: initialMessages.count,
                    detail: warm == nil ? "route.publish" : "warm.tail.publish"
                )
                ContentionTrace.snapshotAndReset(phase: "first-publish")
                HermternalSwitchTrace.session(
                    warm == nil ? "route.publish" : "warm.tail.publish",
                    id: session.id,
                    generation: generation,
                    messages: initialMessages.count
                )
                continuation.resume(returning: true)
            }
        }
    }


    /// Publishes the durable selection identity synchronously. Warm-cache
    /// projection and transcript publication begin only after the first actor
    /// suspension, so SwiftUI's List can commit the real selection highlight
    /// before transcript observation invalidates the chat view. The selection
    /// mutation invalidates both SidebarView and ChatView in one SwiftUI
    /// transaction. A later actor yield alone does not end that transaction.
    ///
    /// Transcript publication therefore crosses a run-loop turn before it
    /// mutates `messages`. The generation guard remains on that assignment.
    @discardableResult
    func requestOpen(
        _ session: ChatSession
    ) -> Task<Void, Never> {
        // The first prompt makes the live session durable. Adopting that
        // row must not reset the reducer or the store; those already hold
        // the optimistic turn and the in-flight stream.
        // Defended by adoptingNewChatKeepsInFlightSend.
        if selectedSessionID == nil,
           liveSessionID == session.id,
           activeTranscriptRoute?.sessionID == session.id,
           activeTranscriptStore != nil {
            setSelectedSessionID(
                session.id,
                event: "selectedSessionID.adoptLive",
                preserveDisplayedTranscript: true
            )
            transcriptRouteIdentity = "live:" + session.id
            return Task { }
        }
        cancelActiveOpen()
        pendingExternalRoute.clearPending()
        let generation = openGenerations.begin()
        SelectionLatencySignposts.beginClick(
            sessionID: session.id,
            generation: generation
        )
        let handle = TranscriptOpenHandle()
        activeOpenHandle = handle
        pendingMessageRoute = nil
        viewingArchivedSessionID = nil
        liveSessionID = nil
        isPreparingOpen = true
        preparingOpenGeneration = generation
        // Invalidate the previous stream before yielding. Event handling is
        // also gated below until this open has installed its transcript.
        clearActiveTranscriptStore()
        streamingReducer.reset()
        ContentionTrace.reset()
        HermternalSwitchTrace.session(
            "selection.begin",
            id: session.id,
            generation: generation,
            messages: messages.count
        )
        let selectionMutation = SelectionLatencySignposts.beginSelectionMutation(
            sessionID: session.id,
            generation: generation
        )
        setSelectedSessionID(
            session.id,
            event: "selectedSessionID.mutation",
            generation: generation
        )
        SelectionLatencySignposts.endSelectionMutation(selectionMutation)
        HermternalSwitchTrace.session(
            "selection.publish",
            id: session.id,
            generation: generation,
            messages: messages.count,
            detail: "route.selection"
        )
        let warmStoreForOpen = warmStore
        let cacheEnabledForOpen = cacheEnabled
        let generationsForOpen = openGenerations
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // Task cancellation can happen before the opener's
                // AsyncStream consumer observes termination. Cancel the
                // handle here so the source and its cache state terminate
                // even when this task never reaches the opener call.
                handle.cancel()
                self.finishOpenPreparation(
                    generation: generation,
                    sessionID: session.id
                )
            }
            // The first yield keeps warm lookup off the selection turn.
            // Transcript publication below also crosses the commit boundary;
            // a yield before lookup alone does not provide that guarantee.
            await Task.yield()
            guard self.openGenerations.isCurrent(generation), !Task.isCancelled else {
                HermternalSwitchTrace.selectionGuard(
                    "requestOpen.afterFirstYield",
                    id: session.id,
                    generation: generation,
                    messages: self.messages.count,
                    reason: self.openGenerations.isCurrent(generation)
                        ? "taskCancelled"
                        : "generationSuperseded"
                )
                return
            }
            var warm = await Task.detached(priority: .userInitiated) {
                () -> WarmTranscriptProjection? in
                guard cacheEnabledForOpen,
                      generationsForOpen.isCurrent(generation)
                else { return nil }
                let projection = warmStoreForOpen.projection(
                    for: session.id,
                    minimumServerTotal: session.messageCount
                )
                guard generationsForOpen.isCurrent(generation) else {
                    return nil
                }
                return projection
            }.value
            guard self.openGenerations.isCurrent(generation), !Task.isCancelled else {
                HermternalSwitchTrace.selectionGuard(
                    "requestOpen.afterWarmLookup",
                    id: session.id,
                    generation: generation,
                    messages: self.messages.count,
                    reason: self.openGenerations.isCurrent(generation)
                        ? "taskCancelled"
                        : "generationSuperseded"
                )
                return
            }
            var initialMessages = warm.map {
                Array($0.messages.suffix(TranscriptPublicationPolicy.initialMessageCount))
            } ?? []
            if initialMessages.isEmpty, cacheEnabledForOpen {
                let historyCacheForOpen = self.historyCache
                let transcript = await Task.detached(priority: .userInitiated) {
                    await historyCacheForOpen.readForWarming(for: session.id).transcript
                }.value
                if let transcript, !transcript.messages.isEmpty {
                    initialMessages = Array(
                        transcript.messages.suffix(TranscriptPublicationPolicy.initialMessageCount)
                    )
                    let snapshot = transcript.snapshot ?? AuthoritativeTranscriptSnapshot(
                        sessionID: session.id,
                        serverTotal: max(session.messageCount, transcript.messages.count),
                        fetchedRows: transcript.messages.count,
                        projectedMessages: transcript.messages.count,
                        truncated: false,
                        fetchedAt: Date(timeIntervalSince1970: 0)
                    )
                    _ = self.warmStore.publish(
                        messages: transcript.messages,
                        snapshot: snapshot,
                        for: session.id,
                        minimumServerTotal: session.messageCount
                    )
                    warm = self.warmStore.projection(
                        for: session.id,
                        minimumServerTotal: session.messageCount
                    )
                }
            }
            guard self.openGenerations.isCurrent(generation), !Task.isCancelled else {
                return
            }
            SelectionLatencySignposts.markWarmProjection(
                warm != nil,
                sessionID: session.id,
                generation: generation
            )
            // The first-frame tail is bounded. Publish it after the
            // selection transaction has completed, and never after a
            // v3-to-paged migration. A later store swap keeps this tail.
            guard await self.publishTranscriptAfterSelectionTurn(
                initialMessages,
                session: session,
                generation: generation,
                warm: warm
            ) else {
                return
            }
            self.releaseOpenEventGate(generation: generation, sessionID: session.id)
            await self.prepareActiveTranscriptStore(
                sessionID: session.id,
                appGeneration: generation
            )
            guard self.openGenerations.isCurrent(generation), !Task.isCancelled else {
                return
            }
            await self.persistTranscriptTail(self.messages)
            _ = await self.open(
                session,
                generation: generation,
                skipWarmProjection: warm,
                selectionAlreadyPublished: true,
                handle: handle
            )
        }
        activeOpenTask = task
        return task
    }

    @discardableResult
    func open(_ session: ChatSession) async -> Bool {
        cancelActiveOpen()
        pendingExternalRoute.clearPending()
        let generation = openGenerations.begin()
        clearActiveTranscriptStore()
        HermternalSwitchTrace.session(
            "open.generation.begins",
            id: session.id,
            generation: generation,
            messages: messages.count
        )
        pendingMessageRoute = nil
        viewingArchivedSessionID = nil
        let handle = TranscriptOpenHandle()
        activeOpenHandle = handle
        return await open(session, generation: generation, handle: handle)
    }
    private func open(
        _ session: ChatSession,
        generation: Int,
        skipWarmProjection: WarmTranscriptProjection? = nil,
        selectionAlreadyPublished: Bool = false,
        handle: TranscriptOpenHandle? = nil
    ) async -> Bool {
        let handle = handle
            ?? (activeOpenHandle?.isTerminated == false ? activeOpenHandle : nil)
            ?? TranscriptOpenHandle()
        activeOpenHandle = handle
        // Browsing never binds a live server-side session. Any live id belongs
        // to the previously selected chat and must not leak into a later send.
        if selectedSessionID != session.id {
            liveSessionID = nil
        }
        guard let source = transcriptSource(for: session) else {
            HermternalSwitchTrace.selectionGuard(
                "open.transcriptSource",
                id: session.id,
                generation: generation,
                messages: messages.count,
                reason: "gatewayUnavailable;emptyColdRoute"
            )
            postError("Could not open chat \(session.id)", detail: "The gateway is unavailable.")
            return false
        }
        await prepareActiveTranscriptStore(
            sessionID: session.id,
            appGeneration: generation
        )
        guard openGenerations.isCurrent(generation), !Task.isCancelled else {
            return false
        }
        updateComposerRoute()

        if !selectionAlreadyPublished {
            setSelectedSessionID(
                session.id,
                event: "selectedSessionID.mutation",
                generation: generation
            )
        }

        let opener = TranscriptOpener(
            source: source,
            cache: cache,
            cacheEnabled: cacheEnabled,
            generations: openGenerations
        )
        for await result in opener.openPhases(
            sessionID: session.id,
            serverTotal: session.messageCount,
            generation: generation,
            sessionTitle: session.title,
            handle: handle
        ) {
            guard openGenerations.isCurrent(generation), !Task.isCancelled else {
                HermternalSwitchTrace.selectionGuard(
                    "open.phase",
                    id: session.id,
                    generation: generation,
                    messages: messages.count,
                    reason: openGenerations.isCurrent(generation)
                        ? "taskCancelled"
                        : "generationSuperseded"
                )
                return false
            }
            if !result.isCachedPhase {
                liveSessionID = result.liveSessionID
            }

            let resident = cacheEnabled
                ? warmStore.projection(
                    for: session.id,
                    minimumServerTotal: session.messageCount
                )
                : nil
            let sameResidentSnapshot = result.snapshot.map { snapshot in
                resident.map {
                    snapshotMatches(snapshot, $0.snapshot)
                } ?? false
            } ?? false
            let isInitialWarmPhase = result.isCachedPhase && skipWarmProjection != nil
            let sameWarmProjection = sameResidentSnapshot
                || (skipWarmProjection.map { warm in
                    guard let snapshot = result.snapshot else { return false }
                    return snapshotMatches(snapshot, warm.snapshot)
                } ?? false)
            let warmTailNeedsExpansion = skipWarmProjection.map {
                messages.count < $0.messages.count
            } ?? false
            let validatedProjection = resident ?? skipWarmProjection
            let sameValidatedProjection = resident != nil
                ? sameResidentSnapshot
                : sameWarmProjection
            let rejectsCacheDerivedDowngrade =
                !result.didFetchREST
                    && validatedProjection != nil
                    && !sameValidatedProjection

            // Resume/cache completions are not authoritative. Once a
            // validated warm projection exists, they must not replace it with
            // an older or weaker snapshot; only a REST result may reconcile it.

            // A validated warm projection may have published only its bounded
            // tail synchronously. The opener expands that tail here without
            // putting any transcript walk back on the selection keypress.
            if let snapshot = result.snapshot,
               cacheEnabled,
               !isInitialWarmPhase,
               !rejectsCacheDerivedDowngrade,
               !sameResidentSnapshot,
               result.messages.count == snapshot.projectedMessages {
                _ = warmStore.publish(
                    messages: result.messages,
                    snapshot: snapshot,
                    for: session.id,
                    minimumServerTotal: session.messageCount
                )
            }
            // A live row that is not in this result stays on screen.
            // A REST result may replace it.
            let liveHasDistinctMessages = messages.contains { displayed in
                !result.messages.contains { candidate in candidate.id == displayed.id }
            }
            let cacheWouldDropVisibleTail = result.isCachedPhase
                && !result.didFetchREST
                && !messages.isEmpty
                && result.messages.count < messages.count
            let preservesLiveReductions = !result.didFetchREST
                && (liveHasDistinctMessages || cacheWouldDropVisibleTail)
            if !preservesLiveReductions,
               !rejectsCacheDerivedDowngrade,
               (!sameWarmProjection || warmTailNeedsExpansion) {
                streamingReducer.reset(
                    messages: Array(result.messages.suffix(TranscriptPublicationPolicy.initialMessageCount))
                )
                transcriptRouteIdentity = "live:\(session.id)"
                transcriptRouteGeneration = generation
                messages = result.messages
                isAwaitingReply = streamingReducer.isAwaitingReply
                updateComposerRoute()
            }
            if result.didFetchREST, !result.isInitialPage {
                await hydratePagedTranscriptStore(
                    source: source,
                    session: session,
                    generation: generation
                )
            }
            await refreshActiveTranscriptMetadata(
                result.summary,
                expectedGeneration: generation
            )
            let phase = result.isCachedPhase
                ? "cache.publish"
                : (result.didFetchREST ? "rest.publish" : "resume.complete")
            HermternalSwitchTrace.session(
                phase,
                id: session.id,
                generation: generation,
                messages: result.messages.count
            )
            if phase == "rest.publish" {
                ContentionTrace.snapshotAndReset(phase: "authoritative-publish")
            }
            if let notice = result.notice {
                postError("Could not fully open chat \(session.id)", detail: notice)
                Log.error("open \(session.id): \(notice)")
            }
            if !rejectsCacheDerivedDowngrade,
               let cacheStore = result.cacheStore {
                applyCacheStore(cacheStore)
            }
            Log.info(
                "open \(session.id): \(result.messages.count) messages"
                    + (result.didFetchREST ? " from REST" : " from cache")
            )
        }
        return true
    }
    private func snapshotMatches(
        _ lhs: AuthoritativeTranscriptSnapshot,
        _ rhs: AuthoritativeTranscriptSnapshot
    ) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.serverTotal == rhs.serverTotal
            && lhs.fetchedRows == rhs.fetchedRows
            && lhs.projectedMessages == rhs.projectedMessages
            && lhs.truncated == rhs.truncated
            && lhs.fetchedAt == rhs.fetchedAt
    }
    /// Opens an archived transcript from cache, then refreshes it from REST.
    /// This path never resumes a live gateway session.
    @discardableResult
    func openArchived(_ session: ChatSession) async -> Bool {
        cancelActiveOpen()
        pendingExternalRoute.clearPending()
        let generation = openGenerations.begin()
        HermternalSwitchTrace.session(
            "open.generation.begins.archived",
            id: session.id,
            generation: generation,
            messages: messages.count
        )
        pendingMessageRoute = nil
        clearActiveTranscriptStore()
        guard let source = transcriptSource(for: session) else {
            postError(
                "Could not open archived chat \(session.id)",
                detail: "The gateway is unavailable."
            )
            return false
        }
        await prepareActiveTranscriptStore(
            sessionID: session.id,
            appGeneration: generation
        )
        guard openGenerations.isCurrent(generation), !Task.isCancelled else {
            return false
        }

        viewingArchivedSessionID = session.id
        setSelectedSessionID(
            session.id,
            event: "selectedSessionID.mutation.archived",
            generation: generation
        )
        liveSessionID = nil
        updateComposerRoute()
        let cached: CachedTranscript?
        let cacheEpoch: UInt64?
        if cacheEnabled {
            let read = await cache.read(for: session.id)
            cached = read.transcript
            cacheEpoch = read.epoch
        } else {
            cached = nil
            cacheEpoch = nil
        }
        guard openGenerations.isCurrent(generation), !Task.isCancelled else { return false }
        streamingReducer.reset(
            messages: Array((cached?.messages ?? []).suffix(TranscriptPublicationPolicy.initialMessageCount))
        )
        transcriptRouteIdentity = "archived:\(session.id)"
        transcriptRouteGeneration = generation
        messages = cached?.messages ?? []
        isAwaitingReply = streamingReducer.isAwaitingReply
        HermternalSwitchTrace.session(
            "cache.publish.archived",
            id: session.id,
            generation: generation,
            messages: messages.count
        )
        Log.info("open archived \(session.id): \(messages.count) messages from cache")

        let authoritative: AuthoritativeTranscript
        do {
            authoritative = try await source.fetchAuthoritative(sessionID: session.id)
        } catch {
            guard openGenerations.isCurrent(generation), !Task.isCancelled else { return false }
            postError(
                "Could not fully open archived chat \(session.id)",
                detail: error.localizedDescription
            )
            Log.error("open archived \(session.id): \(error)")
            return false
        }
        guard openGenerations.isCurrent(generation), !Task.isCancelled else { return false }

        let projected = ChatMessage.projectREST(historyRows: authoritative.rows)
        let snapshot = CacheFirstOpenPolicy.snapshot(
            sessionID: session.id,
            rows: authoritative.rows,
            projectedMessages: projected.count,
            serverTotal: authoritative.serverTotal ?? session.messageCount
        )
        if transcriptSummary?.messageCount == 0 {
            await persistTranscriptMessages(
                projected,
                expectedGeneration: generation
            )
            guard openGenerations.isCurrent(generation), !Task.isCancelled else {
                return false
            }
        }
        if cacheEnabled,
           projected.count == snapshot.projectedMessages {
            let resident = warmStore.projection(
                for: session.id,
                minimumServerTotal: session.messageCount
            )
            let duplicate = resident.map {
                snapshotMatches($0.snapshot, snapshot)
            } ?? false
            if !duplicate {
                _ = warmStore.publish(
                    messages: projected,
                    snapshot: snapshot,
                    for: session.id,
                    minimumServerTotal: session.messageCount
                )
            }
        }
        var cacheStore: CacheStoreResult?
        if cacheEnabled {
            cacheStore = try? await cache.store(
                projected,
                snapshot: snapshot,
                title: session.title,
                for: session.id,
                expectedEpoch: cacheEpoch
            )
            guard openGenerations.isCurrent(generation), !Task.isCancelled else { return false }
        }
        streamingReducer.reset(
            messages: Array(projected.suffix(TranscriptPublicationPolicy.initialMessageCount))
        )
        transcriptRouteIdentity = "archived:\(session.id)"
        transcriptRouteGeneration = generation
        messages = projected
        isAwaitingReply = streamingReducer.isAwaitingReply
        updateComposerRoute()
        await refreshActiveTranscriptMetadata(
            TranscriptSummary(
                rowCount: projected.count,
                messageCount: projected.count,
                countKind: .exact
            ),
            expectedGeneration: generation
        )
        HermternalSwitchTrace.session(
            "rest.publish.archived",
            id: session.id,
            generation: generation,
            messages: messages.count
        )
        if let cacheStore {
            applyCacheStore(cacheStore)
        }
        Log.info("open archived \(session.id): \(messages.count) messages from REST")
        return true
    }
    func openChat(sessionID: String) async {
        cancelActiveOpen()
        pendingExternalRoute.clearPending()
        let generation = openGenerations.begin()
        await openChat(sessionID: sessionID, generation: generation)
    }

    private func openChat(sessionID: String, generation: Int) async {
        viewingArchivedSessionID = nil
        pendingMessageRoute = nil
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            postError("Could not open chat", detail: "The chat no longer exists.")
            return
        }
        _ = await open(session, generation: generation)
    }

    func open(at location: MessageLocation) async {
        cancelActiveOpen()
        pendingExternalRoute.clearPending()
        let generation = openGenerations.begin()
        await open(at: location, generation: generation)

    }
    private func open(at location: MessageLocation, generation: Int) async {
        pendingMessageRoute = nil
        viewingArchivedSessionID = nil
        guard !location.sessionID.isEmpty,
              let session = sessions.first(where: { $0.id == location.sessionID })
        else {
            postError("Could not open that message", detail: "The chat no longer exists.")
            return
        }

        pendingMessageRoute = PendingMessageRoute(location: location, generation: generation)
        let opened = await open(session, generation: generation)
        guard pendingMessageRoute?.generation == generation else { return }
        guard opened else {
            pendingMessageRoute = nil
            return
        }

        guard selectedSessionID == location.sessionID else {
            pendingMessageRoute = nil
            return
        }
        let targetIdentity = MessageIdentity.server(location.messageID)
        let isPublished = messages.contains { $0.id == targetIdentity }
        let store = activeTranscriptStore
        let targetExistsInStore: Bool
        if let store,
           activeStoreAppGeneration == generation,
           activeTranscriptRoute?.sessionID == location.sessionID {
            targetExistsInStore = (try? await store.locate(
                messageID: String(location.messageID.rawValue)
            )) != nil
            guard activeTranscriptStore === store,
                  activeStoreAppGeneration == generation,
                  selectedSessionID == location.sessionID,
                  pendingMessageRoute?.generation == generation,
                  openGenerations.isCurrent(generation),
                  Task.isCancelled == false
            else { return }
        } else {
            targetExistsInStore = false
        }
        guard isPublished || targetExistsInStore else {
            pendingMessageRoute = nil
            postError("Could not open that message", detail: "It is no longer available.")
            return
        }
    }
    // MARK: - Prompting

    /// Establishes the ephemeral session only for an interaction that needs
    /// gateway state. Browsing uses `openPhases` and never calls this helper.
    private func establishLiveSessionForInteraction() async -> Bool {
        guard let sessionID = selectedSessionID,
              let session = sessions.first(where: { $0.id == sessionID }),
              let source = transcriptSource(for: session)
        else {
            return liveSessionID != nil
        }
        let generation = openGenerations.current()
        let opener = TranscriptOpener(
            source: source,
            cache: cache,
            cacheEnabled: cacheEnabled,
            generations: openGenerations
        )
        var established = false
        for await result in opener.openInteractionPhases(
            sessionID: session.id,
            serverTotal: session.messageCount,
            generation: generation,
            sessionTitle: session.title
        ) {
            guard openGenerations.isCurrent(generation), !Task.isCancelled else {
                return false
            }
            if let liveSessionID = result.liveSessionID {
                self.liveSessionID = liveSessionID
                established = true
            }
            if let summary = result.summary {
                await refreshActiveTranscriptMetadata(
                    summary,
                    expectedGeneration: generation
                )
            }
            updateComposerRoute()
            if let cacheStore = result.cacheStore {
                applyCacheStore(cacheStore)
            }
        }
        return established
    }

    func interrupt() async {
        guard !isViewingArchivedTranscript else { return }
        guard let gateway else { return }
        if liveSessionID == nil {
            guard await establishLiveSessionForInteraction() else { return }
        }
        guard let sessionID = liveSessionID else { return }
        let generation = openGenerations.current()
        _ = try? await gateway.call("session.interrupt", params: ["session_id": sessionID])
        guard openGenerations.isCurrent(generation), !Task.isCancelled else { return }
        let reduction = streamingReducer.interrupt()
        messages = reduction.messages
        isAwaitingReply = reduction.isAwaitingReply
        await persistTranscriptTail(reduction.messages)
        updateComposerRoute()
        await reconcileTerminal(reduction.terminal)
    }

    // MARK: - Events

    func handle(_ event: GatewayEvent) async {
        guard !isViewingArchivedTranscript else {
            HermternalSwitchTrace.selectionGuard(
                "gatewayEvent.archivedTranscript",
                id: selectedSessionID,
                messages: messages.count,
                reason: "readOnlyTranscript"
            )
            return
        }
        if event.type == "transport.closed" {
            phase = .failed(event.text ?? "The gateway connection closed.")
            let reduction = streamingReducer.cancel()
            messages = reduction.messages
            isAwaitingReply = reduction.isAwaitingReply
            await persistTranscriptTail(reduction.messages)
            updateComposerRoute()
            HermternalSwitchTrace.selectionGuard(
                "gatewayEvent.transportClosed",
                id: selectedSessionID,
                messages: messages.count,
                reason: "transportClosed;cancelledReducer"
            )
            return
        }
        if event.type == "transport.malformed" {
            postError(
                "Malformed gateway response",
                detail: event.text ?? "The gateway sent an invalid frame."
            )
            HermternalSwitchTrace.selectionGuard(
                "gatewayEvent.transportMalformed",
                id: selectedSessionID,
                messages: messages.count,
                reason: "malformedFrame"
            )
            return
        }

        // Stream events name the live session. The durable sidebar id
        // appears only after the first prompt. Route by live id or
        // selection, not by the missing row.
        // Defended by foreignSessionEventsDoNotReduceOpenChat.
        if let eventSessionID = event.sessionID,
           liveSessionID != nil || selectedSessionID != nil {
            let isActive =
                eventSessionID == liveSessionID
                || eventSessionID == selectedSessionID
            if !isActive {
                HermternalSwitchTrace.selectionGuard(
                    "gatewayEvent.foreignSession",
                    id: selectedSessionID,
                    messages: messages.count,
                    reason: "session=" + eventSessionID
                )
                return
            }
        }

        if event.type == "session.info",
           event.sessionID == liveSessionID || event.sessionID == selectedSessionID {
            composerRuntimeSnapshot = GatewayRuntimeAdapter.decodeRuntimeSnapshot(
                from: event.payload
            )
            updateComposerRoute()
        }
        guard !isPreparingOpen else {
            HermternalSwitchTrace.selectionGuard(
                "gatewayEvent.preparingOpen",
                id: selectedSessionID,
                messages: messages.count,
                reason: "preparingOpenSuppressesReducer"
            )
            return
        }
        let reduction = streamingReducer.reduce(event)
        messages = reduction.messages
        isAwaitingReply = reduction.isAwaitingReply
        await persistTranscriptTail(reduction.messages)
        updateComposerRoute()
        if let notice = reduction.notice {
            postError("The gateway reported an error", detail: notice)
        }
        await reconcileTerminal(reduction.terminal)
    }

    /// Removes only provisional rows with the same gateway turn identity and role
    /// as an authoritative durable row. Text and timestamps never establish identity.
    private func reconcileProvisionalTranscriptRows(
        with authoritativeMessages: [ChatMessage],
        expectedGeneration: Int
    ) async {
        guard let store = activeTranscriptStore,
              let activeRoute = activeTranscriptRoute,
              activeStoreAppGeneration == expectedGeneration,
              openGenerations.isCurrent(expectedGeneration),
              Task.isCancelled == false
        else { return }
        let currentRoute: TranscriptRoute
        do {
            currentRoute = try await store.currentRoute()
        } catch {
            Log.error("transcript provisional route lookup failed: \(error)")
            return
        }
        guard currentRoute.sessionID == activeRoute.sessionID,
              activeTranscriptStore === store,
              activeStoreAppGeneration == expectedGeneration,
              openGenerations.isCurrent(expectedGeneration),
              Task.isCancelled == false
        else { return }
        var route = currentRoute

        let provisionalIDs = messages.compactMap { message -> String? in
            guard case .provisional(let id) = message.id,
                  let turnID = message.turnID,
                  authoritativeMessages.contains(where: { candidate in
                      guard case .server = candidate.id else { return false }
                      return candidate.role == message.role && candidate.turnID == turnID
                  })
            else { return nil }
            return id.uuidString
        }
        guard !provisionalIDs.isEmpty else { return }

        do {
            let result = try await store.apply(
                .removeMany(messageIDs: provisionalIDs),
                expectedGeneration: route.generation,
                expectedEpoch: route.epoch
            )
            guard activeTranscriptStore === store,
                  activeStoreAppGeneration == expectedGeneration,
                  selectedSessionID == route.sessionID,
                  openGenerations.isCurrent(expectedGeneration),
                  Task.isCancelled == false
            else { return }
            route = TranscriptRoute(
                sessionID: route.sessionID,
                generation: result.generation,
                epoch: result.epoch
            )
            transcriptSummary = result.summary
            guard activeTranscriptStore === store,
                  activeStoreAppGeneration == expectedGeneration,
                  selectedSessionID == route.sessionID,
                  openGenerations.isCurrent(expectedGeneration),
                  Task.isCancelled == false
            else { return }
            activeTranscriptRoute = route
            transcriptRevision &+= 1
        } catch {
            Log.error("transcript provisional reconciliation failed: \(error)")
        }
    }

    func reconcileTerminal(_ terminal: StreamingTerminal?) async {
        guard !isViewingArchivedTranscript, terminal != nil else { return }
        let generation = openGenerations.current()
        let sessionID = selectedSessionID
        let session = sessionID.flatMap { id in
            sessions.first { $0.id == id }
        }
        let serverTotal = session?.messageCount
        // An unavailable session row has no title; the empty title is the
        // canonical representation used by the index for that absence.
        let sessionTitle = session?.title ?? ""
        guard let source = transcriptSource(sessionID: sessionID, serverTotal: serverTotal) else {
            if sessionID == nil {
                await loadSessions()
                guard openGenerations.isCurrent(generation), !Task.isCancelled else { return }
            }
            return
        }
        let opener = TranscriptOpener(
            source: source,
            cache: cache,
            cacheEnabled: cacheEnabled,
            generations: openGenerations
        )
        guard let result = await opener.reconcileTerminal(
            sessionID: sessionID,
            serverTotal: serverTotal,
            currentMessages: messages,
            generation: generation,
            sessionTitle: sessionTitle
        ) else { return }
        guard openGenerations.isCurrent(generation), !Task.isCancelled else { return }
        await reconcileProvisionalTranscriptRows(
            with: result.messages,
            expectedGeneration: generation
        )
        guard openGenerations.isCurrent(generation), !Task.isCancelled else { return }
        let reconciledMessages = result.messages.isEmpty ? messages : result.messages
        streamingReducer.reset(
            messages: Array(reconciledMessages.suffix(TranscriptPublicationPolicy.initialMessageCount))
        )
        messages = reconciledMessages
        updateComposerRoute()
        await refreshActiveTranscriptMetadata(nil, expectedGeneration: generation)
        if let snapshot = result.snapshot,
           let selectedSessionID,
           cacheEnabled,
           result.messages.count == snapshot.projectedMessages {
            let resident = warmStore.projection(
                for: selectedSessionID,
                minimumServerTotal: serverTotal
            )
            let duplicate = resident.map {
                snapshotMatches($0.snapshot, snapshot)
            } ?? false
            if !duplicate {
                _ = warmStore.publish(
                    messages: result.messages,
                    snapshot: snapshot,
                    for: selectedSessionID,
                    minimumServerTotal: serverTotal
                )
            }
        }
        isAwaitingReply = streamingReducer.isAwaitingReply
        if let notice = result.notice {
            postError("Transcript reconciliation failed", detail: notice)
            Log.error("terminal transcript reconciliation failed: \(notice)")
        }
        if let cacheStore = result.cacheStore {
            applyCacheStore(cacheStore)
        }
        if result.requiresSessionRefresh {
            await loadSessions()
            guard openGenerations.isCurrent(generation), !Task.isCancelled else { return }
        }
    }
}
