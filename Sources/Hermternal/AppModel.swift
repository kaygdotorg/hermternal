import AppKit
import Foundation
import HermternalCore
import Observation

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case signedOut
        case connecting
        case ready
        case failed(String)
    }

    // MARK: - Observable state

    var phase: Phase = .signedOut
    var sessions: [ChatSession] = []
    var messages: [ChatMessage] = []
    /// Durable id of the sidebar selection.
    var selectedSessionID: String?
    /// A routed message target waiting for ChatView to consume after the
    /// transcript has been rendered. The view clears this one-shot value.
    var pendingMessageLocation: MessageLocation?

    var isAwaitingReply = false
    var composerText = ""
    var serverText: String = AppModel.storedServer
    /// Host of the configured gateway, used to keep deep links authoritative
    /// to the backend that created them.
    var configuredGatewayHost: String? { serverURL?.host }

    /// Non-fatal problems (a failed history load, a dropped socket) surfaced
    /// without tearing down the whole session.
    var notice: String?

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
    /// Injectable seam for exercising cache-first opening without a live app
    /// connection; production builds construct the gateway/rest adapter.
    private let injectedTranscriptSource: (any TranscriptSource)?
    private var eventTask: Task<Void, Never>?
    private let cache: HistoryCache
    private var prefetchTask: Task<Void, Never>?
    private var cacheControlTask: Task<Void, Never>?
    private var cacheControlGeneration = 0
    private var prefetchGeneration = 0
    /// Core-owned generation guard used by opening and terminal reconciliation.
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
        transcriptSource: (any TranscriptSource)? = nil
    ) {
        self.cache = cache
        self.injectedTranscriptSource = transcriptSource
    }

    // MARK: - Lifecycle

    /// Reconnect silently when a stored session is already present, so a
    /// relaunch lands straight in the chat.
    func restoreOrPromptSignIn() async {
        // Cache disablement is a privacy/storage promise and must not depend
        // on auth or network success. Recover an interrupted purge before
        // attempting either.
        if !cacheEnabled {
            let cleared = await cache.clear()
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
        guard await auth.storedCredentials != nil else {
            phase = .signedOut
            return
        }
        await connect()
    }

    func signIn() async {
        guard let url = serverURL else {
            phase = .failed(AuthError.badServerURL.localizedDescription)
            return
        }
        UserDefaults.standard.set(serverText, forKey: Self.serverKey)
        let auth = AuthClient(server: url, openURL: { NSWorkspace.shared.open($0) })
        self.auth = auth

        phase = .connecting
        do {
            Log.info("signIn: starting native PKCE flow against \(url.absoluteString)")
            _ = try await auth.signIn()
            Log.info("signIn: token exchange succeeded")
            await connect()
        } catch {
            Log.error("signIn failed: \(error)")
            phase = .failed(error.localizedDescription)
        }
    }

    func signOut() async {
        _ = openGenerations.begin()
        eventTask?.cancel()
        eventTask = nil
        prefetchTask?.cancel()
        prefetchGeneration += 1
        prefetchTask = nil
        cacheControlTask?.cancel()
        cacheControlTask = nil
        cacheControlGeneration += 1
        await gateway?.disconnect()
        gateway = nil
        rest = nil
        await auth?.signOut()
        // Transcripts are another user's data once signed out.
        await cache.clear()
        cacheCachedCount = 0
        cacheTotalCount = 0
        cacheBytes = 0
        isCacheWarming = false
        liveSessionID = nil
        sessions = []
        streamingReducer.reset()
        messages = []
        isAwaitingReply = streamingReducer.isAwaitingReply
        selectedSessionID = nil
        phase = .signedOut
    }

    // MARK: - Connection

    private func connect() async {
        guard let auth, let url = serverURL else { return }
        phase = .connecting
        do {
            // A ticket is single-use with a 30s TTL, so mint it immediately
            // before dialing.
            let ticket = try await auth.webSocketTicket()
            Log.info("connect: minted ws ticket")
            let gateway = GatewayClient()
            self.gateway = gateway
            try await gateway.connect(server: url, ticket: ticket)
            Log.info("connect: websocket dialed")
            rest = RestClient(server: url, auth: auth)
            observeEvents(on: gateway)
            phase = .ready
            await loadSessions()
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
        guard let gateway else { return }
        do {
            let result = try await gateway.call("session.list")
            let rows = result["sessions"]?.arrayValue ?? []
            sessions = rows.map(ChatSession.init(from:)).filter { !$0.id.isEmpty }
            cacheTotalCount = sessions.count
            Log.info("session.list returned \(sessions.count) sessions")
            await refreshCacheStatistics()
            prefetchTranscripts()
        } catch {
            Log.error("session.list failed: \(error)")
            notice = "Could not load sessions: \(error.localizedDescription)"
        }
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
        prefetchTask?.cancel()
        prefetchGeneration += 1
        prefetchTask = nil
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
                guard await cache.clear() else {
                    notice = "Could not clear the local chat cache."
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
        cacheControlGeneration += 1
        let generation = cacheControlGeneration
        prefetchTask?.cancel()
        prefetchGeneration += 1
        prefetchTask = nil
        cacheControlTask?.cancel()
        cacheControlTask = Task { [weak self] in
            guard let self else { return }
            guard generation == cacheControlGeneration, cacheEnabled else { return }
            guard await cache.clear() else {
                notice = "Could not rebuild the local chat cache."
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
            // Ensures a disabled cache is eventually purged even if the app
            // was terminated before the toggle's asynchronous clear finished.
            guard await cache.clear() else {
                notice = "Could not clear the disabled chat cache."
                Log.error("cache: deferred disabled purge failed")
                isCacheWarming = false
                return
            }
            cacheCachedCount = 0
            cacheBytes = 0
            isCacheWarming = false
            return
        }
        let statistics = await cache.reconcile(validIDs: sessions.map(\.id))
        cacheCachedCount = statistics.entryCount
        cacheBytes = statistics.bytes
    }

    /// Warm the transcript cache in the background so switching chats never
    /// waits on the network.
    ///
    /// Hydration goes over REST, not `session.resume`: resume registers a
    /// live server-side session, so warming every row through it would spin
    /// up one live agent per chat. Concurrency is bounded so a long chat list
    /// does not fan out into one request per row.
    private func prefetchTranscripts() {
        guard cacheEnabled, let rest else {
            isCacheWarming = false
            return
        }
        let ordered = sessions.map(\.id)
        guard cacheCachedCount < ordered.count else {
            isCacheWarming = false
            return
        }

        prefetchTask?.cancel()
        prefetchGeneration += 1
        let generation = prefetchGeneration
        let totals = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount) })
        isCacheWarming = true
        prefetchTask = Task { [weak self, cache] in
            let coordinator = BoundedPrefetchCoordinator(limit: 4)
            let results: [CacheStoreResult] = await coordinator.prefetch(ordered) { id in
                guard await !cache.isCached(id),
                      !Task.isCancelled,
                      let rows = try? await rest.sessionMessages(durableID: id),
                      !Task.isCancelled
                else { return nil }
                let projected = ChatMessage.projectREST(historyRows: rows)
                let snapshot = CacheFirstOpenPolicy.snapshot(
                    sessionID: id,
                    rows: rows,
                    projectedMessages: projected.count,
                    serverTotal: totals[id]
                )
                return await cache.store(projected, snapshot: snapshot, for: id)
            }
            guard let self,
                  generation == self.prefetchGeneration,
                  self.cacheEnabled
            else { return }
            for result in results {
                guard generation == self.prefetchGeneration, self.cacheEnabled else { return }
                self.applyCacheStore(result)
            }
            self.isCacheWarming = false
            Log.info(
                "prefetch: cached \(self.cacheCachedCount)/\(self.cacheTotalCount) "
                + "transcripts"
            )
        }
    }

    private func applyCacheStore(_ result: CacheStoreResult) {
        if result.addedEntry {
            cacheCachedCount = min(cacheCachedCount + 1, cacheTotalCount)
        }
        cacheBytes = max(0, cacheBytes + result.byteDelta)
    }

    func newChat() async {
        _ = openGenerations.begin()
        guard let gateway else { return }
        do {
            let result = try await gateway.call("session.create")
            liveSessionID = result["session_id"]?.stringValue
            streamingReducer.reset()
            messages = []
            isAwaitingReply = streamingReducer.isAwaitingReply
            // `session.create` does not persist a row until the first
            // prompt, so there is nothing to select in the sidebar yet.
            selectedSessionID = nil
            Log.info("session.create -> live id \(liveSessionID ?? "nil")")
        } catch {
            Log.error("session.create failed: \(error)")
            notice = "Could not start a new chat: \(error.localizedDescription)"
        }
    }

    /// Open a sidebar row.
    ///
    /// Renders the cached transcript synchronously so the click feels
    /// instant, then resumes over the socket to bind the live ephemeral id
    /// that `prompt.submit` requires and to reconcile any drift.
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
    @discardableResult
    func open(_ session: ChatSession) async -> Bool {
        guard let source = transcriptSource(for: session) else {
            notice = "Could not open chat \(session.id): the gateway is unavailable."
            return false
        }

        let generation = openGenerations.begin()
        selectedSessionID = session.id

        let opener = TranscriptOpener(
            source: source,
            cache: cache,
            cacheEnabled: cacheEnabled,
            generations: openGenerations
        )
        for await result in opener.openPhases(
            sessionID: session.id,
            serverTotal: session.messageCount,
            generation: generation
        ) {
            guard openGenerations.isCurrent(generation), !Task.isCancelled else { return false }
            if !result.isCachedPhase {
                liveSessionID = result.liveSessionID
            }
            streamingReducer.reset(messages: result.messages)
            messages = result.messages
            isAwaitingReply = streamingReducer.isAwaitingReply
            if let notice = result.notice {
                self.notice = notice
                Log.error("open \(session.id): \(notice)")
            }
            if let cacheStore = result.cacheStore {
                applyCacheStore(cacheStore)
            }
            Log.info(
                "open \(session.id): \(result.messages.count) messages"
                + (result.didFetchREST ? " from REST" : " from cache")
            )
        }
        return true
    }
    /// Opens the target chat and hands a durable target to ChatView only
    /// after all transcript phases have finished. ChatView consumes and
    /// clears the target once its row is ready, then performs the animated
    /// scroll.
    func openThenScroll(to location: MessageLocation) async {
        guard !location.sessionID.isEmpty,
              let session = sessions.first(where: { $0.id == location.sessionID })
        else {
            notice = "Could not open that message: the chat no longer exists."
            return
        }

        pendingMessageLocation = nil
        guard await open(session) else { return }

        guard selectedSessionID == location.sessionID else { return }
        let targetIdentity = MessageIdentity.server(location.messageID)
        guard messages.contains(where: { $0.id == targetIdentity }) else {
            notice = "Could not open that message: it is no longer available."
            return
        }
        pendingMessageLocation = location
    }
    // MARK: - Prompting

    func send() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAwaitingReply, let gateway else { return }

        // A first message with no session yet needs one created first.
        if liveSessionID == nil {
            await newChat()
            guard !Task.isCancelled else { return }
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
            notice = "Send failed: \(error.localizedDescription)"
        }
    }
    func interrupt() async {
        guard let gateway, let sessionID = liveSessionID else { return }
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
        if event.type == "transport.closed" {
            phase = .failed(event.text ?? "The gateway connection closed.")
            let reduction = streamingReducer.cancel()
            messages = reduction.messages
            isAwaitingReply = reduction.isAwaitingReply
            return
        }

        let reduction = streamingReducer.reduce(event)
        messages = reduction.messages
        isAwaitingReply = reduction.isAwaitingReply
        if let notice = reduction.notice {
            self.notice = notice
        }
        await reconcileTerminal(reduction.terminal)
    }

    private func reconcileTerminal(_ terminal: StreamingTerminal?) async {
        guard terminal != nil else { return }
        let generation = openGenerations.current()
        let sessionID = selectedSessionID
        let serverTotal = sessionID.flatMap { id in
            sessions.first { $0.id == id }?.messageCount
        }
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
            generation: generation
        ) else { return }
        guard openGenerations.isCurrent(generation), !Task.isCancelled else { return }
        streamingReducer.reset(messages: result.messages)
        messages = result.messages
        isAwaitingReply = streamingReducer.isAwaitingReply
        if let notice = result.notice {
            self.notice = notice
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
