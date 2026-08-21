import Foundation
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
    var isAwaitingReply = false
    var composerText = ""
    var serverText: String = AppModel.storedServer

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
    private var eventTask: Task<Void, Never>?
    private let cache = HistoryCache()
    private var prefetchTask: Task<Void, Never>?
    private var cacheControlTask: Task<Void, Never>?
    private var cacheControlGeneration = 0
    private var prefetchGeneration = 0
    /// Guards against a slow resume for an earlier click overwriting the
    /// transcript the user is now looking at.
    private var openGeneration = 0

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
        let auth = AuthClient(server: url)
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
        let auth = AuthClient(server: url)
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
        messages = []
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
        isCacheWarming = true
        prefetchTask = Task { [weak self, cache] in
            let lanes = 4
            await withTaskGroup(of: CacheStoreResult?.self) { group in
                var next = 0
                func addTask(_ id: String) {
                    group.addTask {
                        guard await !cache.isCached(id) else { return nil }
                        guard !Task.isCancelled,
                              let rows = try? await rest.sessionMessages(durableID: id)
                        else { return nil }
                        guard !Task.isCancelled else { return nil }
                        return await cache.store(
                            rows.compactMap(ChatMessage.init(historyRow:)),
                            for: id
                        )
                    }
                }
                while next < ordered.count, next < lanes {
                    addTask(ordered[next])
                    next += 1
                }
                while let result = await group.next() {
                    guard let self,
                          generation == self.prefetchGeneration,
                          self.cacheEnabled
                    else {
                        group.cancelAll()
                        return
                    }
                    if let result {
                        self.applyCacheStore(result)
                    }
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    if next < ordered.count {
                        addTask(ordered[next])
                        next += 1
                    }
                }
            }
            guard let self,
                  generation == self.prefetchGeneration,
                  self.cacheEnabled
            else { return }
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
        guard let gateway else { return }
        do {
            let result = try await gateway.call("session.create")
            liveSessionID = result["session_id"]?.stringValue
            messages = []
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
    func open(_ session: ChatSession) async {
        guard let gateway else { return }
        openGeneration += 1
        let generation = openGeneration
        selectedSessionID = session.id

        if cacheEnabled, let cached = await cache.messages(for: session.id) {
            // Only paint if this is still the row the user is looking at.
            guard generation == openGeneration else { return }
            messages = cached
            Log.info("open \(session.id): \(cached.count) messages from cache")
        } else {
            messages = []
        }

        do {
            let result = try await gateway.call(
                "session.resume",
                params: ["session_id": session.id]
            )
            // A superseded arrow-selection request may still receive its RPC
            // response because GatewayClient.call is continuation-based. Stop
            // before row projection, encoding, disk I/O, or UI publication.
            guard generation == openGeneration, !Task.isCancelled else { return }
            let rows = result["messages"]?.arrayValue ?? []
            let resumed = rows.compactMap(ChatMessage.init(historyRow:))
            if cacheEnabled {
                let result = await cache.store(resumed, for: session.id)
                applyCacheStore(result)
            }
            liveSessionID = result["session_id"]?.stringValue
            messages = resumed
            Log.info(
                "session.resume -> live id \(liveSessionID ?? "nil"), "
                + "\(rows.count) rows, \(resumed.count) rendered"
            )
        } catch {
            Log.error("session.resume failed: \(error)")
            guard generation == openGeneration else { return }
            notice = "Could not open that chat: \(error.localizedDescription)"
        }
    }

    // MARK: - Prompting

    func send() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAwaitingReply, let gateway else { return }

        // A first message with no session yet needs one created first.
        if liveSessionID == nil {
            await newChat()
        }
        guard let sessionID = liveSessionID else { return }

        composerText = ""
        messages.append(ChatMessage(role: .user, text: text))
        isAwaitingReply = true

        do {
            _ = try await gateway.call(
                "prompt.submit",
                params: ["session_id": sessionID, "text": text]
            )
        } catch {
            isAwaitingReply = false
            notice = "Send failed: \(error.localizedDescription)"
        }
    }

    func interrupt() async {
        guard let gateway, let sessionID = liveSessionID else { return }
        _ = try? await gateway.call("session.interrupt", params: ["session_id": sessionID])
        finishStreaming()
    }

    // MARK: - Events

    private func handle(_ event: GatewayEvent) async {
        switch event.type {
        case "message.start":
            messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))

        case "message.delta":
            guard let delta = event.text, !delta.isEmpty else { return }
            appendDelta(delta)

        case "message.complete":
            // The final frame carries the authoritative full text, which may
            // differ from the concatenated deltas (post-processing, cleanup).
            if let full = event.text, !full.isEmpty {
                if let index = streamingIndex {
                    messages[index].text = full
                } else {
                    messages.append(ChatMessage(role: .assistant, text: full))
                }
            }
            finishStreaming()
            // Keep the cache in step with the completed turn so reopening
            // this chat does not briefly show a stale transcript.
            if let id = selectedSessionID {
                if cacheEnabled {
                    let result = await cache.store(messages, for: id)
                    applyCacheStore(result)
                }
            } else {
                // A first turn only now creates the durable row; refresh so
                // it appears in the sidebar.
                await loadSessions()
            }

        case "error":
            notice = event.text ?? "The agent reported an error."
            finishStreaming()

        case "transport.closed":
            phase = .failed(event.text ?? "The gateway connection closed.")
            finishStreaming()

        default:
            // tool.*, thinking.*, reasoning.*, status.* are deliberately
            // ignored in v1 — chat text only.
            break
        }
    }

    private var streamingIndex: Int? {
        messages.lastIndex { $0.isStreaming }
    }

    private func appendDelta(_ delta: String) {
        if let index = streamingIndex {
            messages[index].text += delta
        } else {
            // Some turns stream without a preceding message.start.
            messages.append(ChatMessage(role: .assistant, text: delta, isStreaming: true))
        }
    }

    private func finishStreaming() {
        if let index = streamingIndex {
            messages[index].isStreaming = false
        }
        isAwaitingReply = false
    }
}
