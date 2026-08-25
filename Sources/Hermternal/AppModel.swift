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

    static func transcriptPhaseHeight(
        cacheHit: Bool,
        start: UInt64,
        end: UInt64
    ) {
        guard var pending = pendingTranscriptPublication else { return }
        let duration = elapsedNanoseconds(start: start, end: end)
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
        let updateToPaintNanoseconds = pending.updateEndedAtNanoseconds.map {
            visibleAtNanoseconds >= $0 ? visibleAtNanoseconds - $0 : 0
        } ?? 0
        session(
            "transcript.phaseBreakdown",
            id: id,
            generation: generation,
            messages: messages,
            renderedRows: renderedRows,
            detail: "publishToPaintNs=\(visibleAtNanoseconds - pending.publishedAtNanoseconds),updateNs=\(pending.updateNSViewNanoseconds),diffNs=\(pending.coordinatorDiffNanoseconds),heightCalls=\(pending.heightCalls),heightCacheHits=\(pending.heightCacheHits),heightCacheNs=\(pending.heightCacheHitNanoseconds),heightEstimatorCalls=\(pending.heightEstimatorCalls),heightEstimatorNs=\(pending.heightEstimatorNanoseconds),rowConfigs=\(pending.rowConfigurations),rowReused=\(pending.reusedRowConfigurations),rowNew=\(pending.newRowConfigurations),textSlices=\(pending.textSliceCount),textSliceNs=\(pending.textSliceNanoseconds),contentHashCalls=\(pending.contentHashCount),contentHashNs=\(pending.contentHashNanoseconds),reloadFullRows=\(pending.fullReloadRows),reloadTargetedRows=\(pending.targetedReloadRows),updateToPaintNs=\(updateToPaintNanoseconds)",
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


private struct TranscriptMatchCache {
    let query: String
    let revision: Int
    let matches: [TranscriptMatch]
}
@MainActor
@Observable
final class AppModel {
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
    var archivedSessions: [ChatSession] = []
    var archivedSessionsLoading = false
    var archivedSessionsError: String?
    var folders: [Folder] = []
    var membership: [String: String] = [:]
    var messages: [ChatMessage] = [] {
        didSet {
            messagesRevision &+= 1
            transcriptMatchCache = nil
        }
    }
    /// Monotonic revision for transcript content. Find memoization keys on
    /// this value rather than repeatedly comparing all message text.
    private(set) var messagesRevision = 0
    private var transcriptMatchCache: TranscriptMatchCache?

    /// Returns the memoized Find result for the current transcript revision.
    ///
    /// The revision increments from `messages`' didSet, including element
    /// replacement and streaming text updates. The single-entry cache avoids
    /// retaining match arrays for old transcripts or queries.
    func transcriptMatches(for query: String) -> [TranscriptMatch] {
        let revision = messagesRevision
        if let cache = transcriptMatchCache,
           cache.revision == revision,
           cache.query == query {
            return cache.matches
        }
        // ChatView previously caused five full scans per body pass.
        let matches = TranscriptFindPass.matches(in: messages, query: query)
        transcriptMatchCache = TranscriptMatchCache(
            query: query,
            revision: revision,
            matches: matches
        )
        return matches
    }
    var selectedSessionID: String?
    /// A routed message target that ChatView reads during the transcript's
    /// initial layout. It is single-use and owned by its open generation.
    var pendingMessageLocation: MessageLocation? { pendingMessageRoute?.location }
    var openGeneration: Int { openGenerations.current() }

    var isAwaitingReply = false
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
    /// Capability state is composed once by the connected gateway module.
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

    /// The command-K surface is owned by the app model so the command menu
    /// and the window overlay share one source of truth.
    var isSearchPresented = false

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
        self.warmStore = warmStore
        HermternalSwitchTrace.configure(capability: debugModules)
        guard let historyDirectory = HistoryCache.defaultDirectory() else {
            self.cache = cache
            self.searchQuerying = nil
            self.searchUnavailableReason = "The system cache directory is unavailable."
            return
        }

        let indexURL = historyDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("search.sqlite", isDirectory: false)
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
        archivedSessionsLoading = false
        archivedSessionsError = nil
        setSelectedSessionID(nil, event: "selectedSessionID.signOut")
        viewingArchivedSessionID = nil
        phase = .signedOut
        eventTask?.cancel()
        eventTask = nil
        cancelPrefetch()
        cacheControlTask?.cancel()
        cacheControlTask = nil
        cacheControlGeneration += 1
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
               let selectedSessionID,
               !sessions.contains(where: { $0.id == selectedSessionID }) {
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
            postError("Could not copy deep links", detail: "The gateway address is unavailable.")
            return
        }
        let links = sessions.compactMap {
            MessageDeepLink(gatewayHost: host, sessionID: $0.id)?.url.absoluteString
        }
        guard !links.isEmpty else {
            postError("Could not copy deep links", detail: "No valid chat links were available.")
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
            streamingReducer.reset()
            isAwaitingReply = streamingReducer.isAwaitingReply
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
        composerText = ""
        streamingReducer.reset()
        isAwaitingReply = streamingReducer.isAwaitingReply
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
        generation: Int? = nil
    ) {
        HermternalSwitchTrace.session(
            "\(event).before",
            id: selectedSessionID,
            generation: generation,
            messages: messages.count
        )
        selectedSessionID = value
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
    func newChat() async {
        pendingExternalRoute.clearPending()
        _ = openGenerations.begin()
        pendingMessageRoute = nil
        viewingArchivedSessionID = nil
        guard let gateway else { return }
        do {
            let result = try await gateway.call("session.create")
            liveSessionID = result["session_id"]?.stringValue
            streamingReducer.reset()
            messages = []
            isAwaitingReply = streamingReducer.isAwaitingReply
            // `session.create` does not persist a row until the first
            // prompt, so there is nothing to select in the sidebar yet.
            setSelectedSessionID(nil, event: "selectedSessionID.newChat")
            Log.info("session.create -> live id \(liveSessionID ?? "nil")")
        } catch {
            Log.error("session.create failed: \(error)")
            postError("Could not start a new chat", detail: error.localizedDescription)
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
        guard let gateway, let rest else { return nil }
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
        guard case let .open(destination, routeGeneration) = decision else { return }
        dispatchExternalRoute(
            destination,
            routeGeneration: routeGeneration,
            generation: generation
        )
    }

    /// Invalidates a queued external route when the user starts navigation.
    /// This runs before the delayed transcript open can begin.
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
        else { return }
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
            else { return }
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
        else { return }
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
    }

    /// Selection bookkeeping and the warm projection publish synchronously so
    /// the sidebar highlight and transcript advance in the same interaction
    /// turn. Only the authoritative opener runs in a cancellable task.
    @discardableResult
    func requestOpen(_ session: ChatSession) -> Task<Void, Never> {
        cancelActiveOpen()
        pendingExternalRoute.clearPending()
        let generation = openGenerations.begin()
        let handle = TranscriptOpenHandle()
        activeOpenHandle = handle
        pendingMessageRoute = nil
        viewingArchivedSessionID = nil
        liveSessionID = nil
        ContentionTrace.reset()
        HermternalSwitchTrace.session(
            "selection.begin",
            id: session.id,
            generation: generation,
            messages: messages.count
        )
        setSelectedSessionID(
            session.id,
            event: "selectedSessionID.mutation",
            generation: generation
        )

        // Publication is deliberately synchronous. The warm-store lookup is
        // cheap; doing it before the first suspension means key-repeat task
        // cancellation cannot suppress a settled selection.
        let warm = cacheEnabled
            ? warmStore.projection(
                for: session.id,
                minimumServerTotal: session.messageCount
            )
            : nil
        if let warm {
            streamingReducer.reset(messages: warm.messages)
            messages = warm.messages
            isAwaitingReply = streamingReducer.isAwaitingReply
            HermternalSwitchTrace.session(
                "selection.publish",
                id: session.id,
                generation: generation,
                messages: warm.messages.count,
                detail: "warm.publish"
            )
            ContentionTrace.snapshotAndReset(phase: "first-publish")
            HermternalSwitchTrace.session(
                "warm.publish",
                id: session.id,
                generation: generation,
                messages: warm.messages.count
            )
        } else {
            // A cold miss must not leave the prior chat painted while the
            // cancellable opener obtains its first authoritative phase.
            streamingReducer.reset()
            messages = []
            isAwaitingReply = streamingReducer.isAwaitingReply
            HermternalSwitchTrace.session(
                "selection.publish",
                id: session.id,
                generation: generation,
                messages: 0,
                detail: "cold.publish"
            )
            ContentionTrace.snapshotAndReset(phase: "first-publish")
            HermternalSwitchTrace.session(
                "cold.publish",
                id: session.id,
                generation: generation,
                messages: 0
            )
        }

        // Only expensive work remains in this task. A newer selection cancels
        // opener tasks and handles, cache reads, REST fetches, and block
        // preparation through the generation and TranscriptOpenHandle guards.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            guard self.openGenerations.isCurrent(generation), !Task.isCancelled else { return }
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
            postError("Could not open chat \(session.id)", detail: "The gateway is unavailable.")
            return false
        }

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
            guard openGenerations.isCurrent(generation), !Task.isCancelled else { return false }
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

            // A validated synchronous warm projection is already complete
            // against the current session total. The opener's initial disk
            // phase cannot replace it, even when its snapshot is older or
            // otherwise differs. Resume/REST phases may still be newer.
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
            if !isInitialWarmPhase
                && !rejectsCacheDerivedDowngrade
                && !sameWarmProjection {
                streamingReducer.reset(messages: result.messages)
                messages = result.messages
                isAwaitingReply = streamingReducer.isAwaitingReply
            }
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
        guard let source = transcriptSource(for: session) else {
            postError(
                "Could not open archived chat \(session.id)",
                detail: "The gateway is unavailable."
            )
            return false
        }

        viewingArchivedSessionID = session.id
        setSelectedSessionID(
            session.id,
            event: "selectedSessionID.mutation.archived",
            generation: generation
        )
        liveSessionID = nil
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
        streamingReducer.reset(messages: cached?.messages ?? [])
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
        streamingReducer.reset(messages: projected)
        messages = projected
        isAwaitingReply = streamingReducer.isAwaitingReply
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
        guard messages.contains(where: { $0.id == targetIdentity }) else {
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
            if let cacheStore = result.cacheStore {
                applyCacheStore(cacheStore)
            }
        }
        return established
    }

    func send() async {
        guard !isViewingArchivedTranscript else { return }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAwaitingReply, let gateway else { return }

        // A first message with no session yet needs one created first.
        if liveSessionID == nil {
            if selectedSessionID != nil {
                guard await establishLiveSessionForInteraction() else { return }
            } else {
                await newChat()
                guard !Task.isCancelled else { return }
            }
        }
        guard let sessionID = liveSessionID else { return }
        composerText = ""
        // A new turn supersedes any terminal reconciliation still awaiting
        // REST. Its result must not replace this turn or clear its state.
        let generation = openGenerations.begin()
        streamingReducer.appendUser(text)
        messages = streamingReducer.messages
        isAwaitingReply = streamingReducer.isAwaitingReply

        do {
            _ = try await gateway.call(
                "prompt.submit",
                params: ["session_id": sessionID, "text": text]
            )
            guard openGenerations.isCurrent(generation), !Task.isCancelled else { return }
        } catch {
            guard openGenerations.isCurrent(generation), !Task.isCancelled else { return }
            let reduction = streamingReducer.cancel()
            messages = reduction.messages
            isAwaitingReply = reduction.isAwaitingReply
            postError("Send failed", detail: error.localizedDescription)
        }
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
        await reconcileTerminal(reduction.terminal)
    }

    // MARK: - Events

    private func handle(_ event: GatewayEvent) async {
        guard !isViewingArchivedTranscript else { return }
        if event.type == "transport.closed" {
            phase = .failed(event.text ?? "The gateway connection closed.")
            let reduction = streamingReducer.cancel()
            messages = reduction.messages
            isAwaitingReply = reduction.isAwaitingReply
            return
        }
        if event.type == "transport.malformed" {
            postError(
                "Malformed gateway response",
                detail: event.text ?? "The gateway sent an invalid frame."
            )
            return
        }

        let reduction = streamingReducer.reduce(event)
        messages = reduction.messages
        isAwaitingReply = reduction.isAwaitingReply
        if let notice = reduction.notice {
            postError("The gateway reported an error", detail: notice)
        }
        await reconcileTerminal(reduction.terminal)
    }

    private func reconcileTerminal(_ terminal: StreamingTerminal?) async {
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
        streamingReducer.reset(messages: result.messages)
        messages = result.messages
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
