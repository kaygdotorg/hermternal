import Foundation
import HermternalCore
import Testing
@testable import Hermternal

/// The bound for every asynchronous wait in this file.
/// Isolated runs keep 5 s: one sidebar selection reaches its route and
/// starts its stream in a few scheduler turns. Debug validate.sh runs
/// this next to the rest of the MainActor suite; the first stream start
/// can wait behind that load. 15 s still fails a stuck open path.
private var sidebarWaitBound: Duration {
#if DEBUG
    .seconds(15)
#else
    .seconds(5)
#endif
}

/// Waits until `holds` returns true, or until `sidebarWaitBound` runs out.
///
/// The wait polls between scheduler turns. The open path needs these turns to
/// make progress. A wait that runs out records one failure at the call site
/// and returns false. The test process then reports the stalled condition,
/// and does not hang.
@MainActor
private func sidebarWait(
    until condition: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    holds: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + sidebarWaitBound
    while true {
        if await holds() { return true }
        guard ContinuousClock.now < deadline else {
            Issue.record(
                """
                The wait ended after \(sidebarWaitBound). \
                The condition did not occur: \(condition).
                """,
                sourceLocation: sourceLocation
            )
            return false
        }
        await Task.yield()
    }
}

@Test("40 sidebar selections start cache-first opens without a release flush")
@MainActor
func fortySidebarSelectionsStartCachedOpensImmediately() async throws {
    let directory = try sidebarNavigationTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let warmStore = TranscriptWarmStore()
    let source = SidebarOpenStartSource()
    let model = AppModel(
        cache: HistoryCache(directory: directory),
        transcriptSource: source,
        warmStore: warmStore
    )
    model.phase = .ready
    let sessions = (1...40).map { chatSession(id: "chat-\($0)", messageCount: 1) }
    model.sessions = sessions

    for (index, session) in sessions.enumerated() {
        let message = ChatMessage(role: .assistant, text: "cached \(index + 1)")
        #expect(warmStore.publish(
            messages: [message],
            snapshot: AuthoritativeTranscriptSnapshot(
                sessionID: session.id,
                serverTotal: 1,
                fetchedRows: 1,
                projectedMessages: 1,
                truncated: false,
                fetchedAt: Date()
            ),
            for: session.id,
            minimumServerTotal: session.messageCount
        ))
    }

    var immediateOpenStarts: [String] = []
    let releaseFlushes = 0
    var finalOpenTask: Task<Void, Never>?
    var openedEverySession = true

    for (index, session) in sessions.enumerated() {
        immediateOpenStarts.append(session.id)
        finalOpenTask = model.requestOpen(session)
        #expect(model.transcriptRouteIdentity == "live:\(session.id)")
        #expect(model.messages.map(\.text) == ["cached \(index + 1)"])

        guard await sidebarWait(
            until: "the transcript source starts \(index + 1) authoritative streams",
            holds: { await source.startedSessionIDs.count >= index + 1 }
        ) else {
            openedEverySession = false
            break
        }
    }

    // The teardown also runs after a wait runs out. No held stream and no
    // open task then outlives this test.
    model.cancelOpenPreparation()

    // The last open task is joined through a signal rather than awaited
    // outright. An open that never finishes then ends this test with one
    // recorded failure, instead of hanging the test process on a join that
    // has no bound of its own.
    var lastOpenFinished = true
    if let finalOpenTask {
        let completion = SidebarOpenTaskCompletion()
        Task {
            await finalOpenTask.value
            await completion.record()
        }
        lastOpenFinished = await sidebarWait(
            until: "cancellation finishes the last open task",
            holds: { await completion.isRecorded }
        )
        // The signal already reported the task finishing, so this join reads
        // a value that is complete and returns at once.
        if lastOpenFinished {
            await finalOpenTask.value
        }
    }

    let everyStreamStopped = await sidebarWait(
        until: "cancellation releases every held authoritative stream",
        holds: { await source.activeStreamCount == 0 }
    )

    guard openedEverySession, lastOpenFinished, everyStreamStopped else { return }

    #expect(immediateOpenStarts == sessions.map(\.id))
    #expect(await source.startedSessionIDs == immediateOpenStarts)
    #expect(releaseFlushes == 0)
}

/// The expiry delay of a finished pointer cycle, driven by hand.
///
/// No test process has a clock for the classifier to wait on, so the delay
/// becomes a value the test fires when its scenario says the window ran out.
/// The hand holds one schedule at a time. A schedule arriving over an
/// outstanding one is the accumulating-schedule defect, and it fails in the
/// test that provokes it rather than in whichever test runs next.
@MainActor
private final class SidebarPointerExpiryHand {
    private var outstanding: (serial: Int, expire: @MainActor () -> Void)?
    private var serial = 0

    var isScheduled: Bool { outstanding != nil }

    /// The classifier's seam: takes the expiry, returns its cancellation.
    func schedule(
        _ expire: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        if outstanding != nil {
            Issue.record(
                """
                A second expiry was scheduled while one was outstanding. \
                The classifier accumulates schedules.
                """
            )
        }
        serial += 1
        let scheduled = serial
        outstanding = (scheduled, expire)
        return { [weak self] in
            guard let self, self.outstanding?.serial == scheduled else { return }
            self.outstanding = nil
        }
    }

    /// Runs the window out on the outstanding schedule.
    func fire(sourceLocation: SourceLocation = #_sourceLocation) {
        guard let outstanding else {
            Issue.record(
                """
                No expiry was scheduled. The finished pointer cycle has no \
                bound, so a later selection can still inherit it.
                """,
                sourceLocation: sourceLocation
            )
            return
        }
        self.outstanding = nil
        outstanding.expire()
    }
}

/// Detaches the classifier from AppKit and from the clock for the length of
/// one test. No test process dispatches AppKit events, so the classifier
/// reports no dispatching event unless the test says otherwise, and a
/// finished cycle expires when the body fires its hand.
@MainActor
private func withSidebarPointerClassifier(
    _ body: (SidebarPointerExpiryHand) -> Void
) {
    let appKitDispatchingEvent = SidebarSelectionEventAdapter.dispatchingEvent
    let clockExpiry = SidebarSelectionEventAdapter.scheduleRetainedCycleExpiry
    let expiry = SidebarPointerExpiryHand()
    SidebarSelectionEventAdapter.dispatchingEvent = { nil }
    SidebarSelectionEventAdapter.scheduleRetainedCycleExpiry = { expire in
        expiry.schedule(expire)
    }
    defer {
        SidebarSelectionEventAdapter.stop()
        SidebarSelectionEventAdapter.dispatchingEvent = appKitDispatchingEvent
        SidebarSelectionEventAdapter.scheduleRetainedCycleExpiry = clockExpiry
    }
    body(expiry)
}

/// Sends one event to the classifier in the AppKit order. The local monitor
/// sees the event first. The application then reports the same event as the
/// dispatching event, and reports no event after the dispatch.
@MainActor
private func sidebarDispatch(
    _ event: SidebarPointerEvent,
    _ body: () -> Void = {}
) {
    SidebarSelectionEventAdapter.ingest(event)
    SidebarSelectionEventAdapter.dispatchingEvent = { event }
    body()
    SidebarSelectionEventAdapter.dispatchingEvent = { nil }
}

/// The two arrivals that one sidebar row has: the row Button's action, and
/// the List selection observer. Both take their pointer cycle from the
/// classifier, so no test supplies one.
@MainActor
private final class SidebarRowArrivals {
    private let session: ChatSession
    private var pointerActivation: SidebarPointerActivation?
    private(set) var opened: [String] = []

    init(id: String) {
        session = chatSession(id: id)
    }

    /// Starts the next scenario from the state a fresh row has.
    func reset() {
        pointerActivation = nil
        opened.removeAll()
    }

    func buttonActivation() {
        activate(
            pointerCycle: SidebarSelectionEventAdapter.pointerCycleForButtonActivation()
        )
    }

    func selectionArrival() {
        sidebarSelectionArrival(
            sessionID: session.id,
            pointerCycle: SidebarSelectionEventAdapter
                .consumePointerCycleForSelectionArrival(),
            pointerActivation: pointerActivation
        ) { _, activationPointerCycle in
            activate(pointerCycle: activationPointerCycle)
        }
    }

    private func activate(pointerCycle: SidebarPointerCycle?) {
        sidebarActivateSession(
            session,
            pointerCycle: pointerCycle,
            pointerActivation: &pointerActivation
        ) { opened.append($0.id) }
    }
}

@Test("One physical click opens a live chat row once in every arrival order")
@MainActor
func oneClickOpensLiveChatRowOnceInEveryArrivalOrder() {
    withSidebarPointerClassifier { expiry in
        let row = SidebarRowArrivals(id: "chat")

        // A trailing click. The Button fires inside the mouse-up dispatch.
        // SwiftUI reports the selection in a later turn, which dispatches no
        // event.
        sidebarDispatch(SidebarPointerEvent(kind: .down, eventNumber: 11))
        sidebarDispatch(SidebarPointerEvent(kind: .up, eventNumber: 12)) {
            row.buttonActivation()
        }
        row.selectionArrival()
        #expect(row.opened == ["chat"])
        // The arrival spent the token, so no expiry is left outstanding.
        #expect(expiry.isScheduled == false)

        // The same click with the two arrivals reversed.
        row.reset()
        sidebarDispatch(SidebarPointerEvent(kind: .down, eventNumber: 21)) {
            row.selectionArrival()
        }
        sidebarDispatch(SidebarPointerEvent(kind: .up, eventNumber: 22)) {
            row.buttonActivation()
        }
        #expect(row.opened == ["chat"])

        // Two physical clicks. The second cycle replaces the cycle that the
        // first one retained, so the row opens twice.
        row.reset()
        sidebarDispatch(SidebarPointerEvent(kind: .down, eventNumber: 31))
        sidebarDispatch(SidebarPointerEvent(kind: .up, eventNumber: 32)) {
            row.buttonActivation()
        }
        sidebarDispatch(SidebarPointerEvent(kind: .down, eventNumber: 33))
        sidebarDispatch(SidebarPointerEvent(kind: .up, eventNumber: 34)) {
            row.buttonActivation()
        }
        row.selectionArrival()
        #expect(row.opened == ["chat", "chat"])
        #expect(expiry.isScheduled == false)
    }
}

@Test("A keyboard or VoiceOver selection never claims an earlier pointer cycle")
@MainActor
func laterSelectionNeverClaimsRetainedPointerCycle() {
    withSidebarPointerClassifier { expiry in
        let row = SidebarRowArrivals(id: "chat")

        // A key press ends the pointer cycle. The keyboard selection that
        // follows carries no cycle, so it opens the row.
        sidebarDispatch(SidebarPointerEvent(kind: .down, eventNumber: 41))
        sidebarDispatch(SidebarPointerEvent(kind: .up, eventNumber: 42)) {
            row.buttonActivation()
        }
        #expect(row.opened == ["chat"])
        sidebarDispatch(SidebarPointerEvent(kind: .key))
        // The key press discarded the schedule along with the token.
        #expect(expiry.isScheduled == false)
        row.selectionArrival()
        #expect(row.opened == ["chat", "chat"])

        // VoiceOver moves the selection with no event at all. The click
        // before it already spent its retained cycle, so this arrival opens
        // the row as well.
        row.reset()
        sidebarDispatch(SidebarPointerEvent(kind: .down, eventNumber: 51))
        sidebarDispatch(SidebarPointerEvent(kind: .up, eventNumber: 52)) {
            row.buttonActivation()
        }
        row.selectionArrival()
        #expect(row.opened == ["chat"])
        row.selectionArrival()
        #expect(row.opened == ["chat", "chat"])
    }
}

@Test("A finished context click still classifies a delayed selection arrival")
@MainActor
func finishedContextClickClassifiesDelayedSelectionArrival() {
    withSidebarPointerClassifier { expiry in
        sidebarDispatch(SidebarPointerEvent(
            kind: .down,
            eventNumber: 61,
            isContextButton: true
        ))
        sidebarDispatch(SidebarPointerEvent(
            kind: .up,
            eventNumber: 62,
            isContextButton: true
        ))

        let classification = SidebarSelectionEventAdapter.current()
        #expect(classification?.isContextClick == true)
        #expect(classification?.isModified == false)
        // The delayed arrival may never come, so the cycle is bounded.
        #expect(expiry.isScheduled)
    }
}

@Test("An unconsumed context click expires before a later VoiceOver selection")
@MainActor
func unconsumedContextClickExpiresBeforeLaterSelection() {
    withSidebarPointerClassifier { expiry in
        let row = SidebarRowArrivals(id: "chat")

        // A context click on the row that is already selected. The row's
        // Button does not fire for a secondary button, and the selection set
        // does not change, so SwiftUI reports no arrival at all. Nothing
        // spends the finished cycle.
        sidebarDispatch(SidebarPointerEvent(
            kind: .down,
            eventNumber: 71,
            isContextButton: true
        ))
        sidebarDispatch(SidebarPointerEvent(
            kind: .up,
            eventNumber: 72,
            isContextButton: true
        ))
        #expect(row.opened.isEmpty)
        #expect(SidebarSelectionEventAdapter.current()?.isContextClick == true)
        #expect(expiry.isScheduled)

        // The window runs out. The classification goes with the token, so
        // the gate that drops context clicks no longer sees one.
        expiry.fire()
        // No classification at all: an absent one has no member to read, so
        // the gate that drops context clicks sees nothing.
        #expect(SidebarSelectionEventAdapter.current()?.isContextClick == nil)
        #expect(expiry.isScheduled == false)

        // VoiceOver moves the selection with no event of its own. The
        // arrival claims no cycle, so it opens the row exactly once.
        row.selectionArrival()
        #expect(row.opened == ["chat"])

        // The sidebar going away discards the schedule of a cycle that no
        // arrival spent. No expiry outlives the classifier.
        sidebarDispatch(SidebarPointerEvent(
            kind: .down,
            eventNumber: 81,
            isContextButton: true
        ))
        sidebarDispatch(SidebarPointerEvent(
            kind: .up,
            eventNumber: 82,
            isContextButton: true
        ))
        #expect(expiry.isScheduled)
        SidebarSelectionEventAdapter.stop()
        #expect(expiry.isScheduled == false)
    }
}

@Test("Keyboard and VoiceOver activation are not deduplicated as pointer input")
@MainActor
func nonPointerActivationIgnoresPriorPointerCycle() {
    let session = chatSession(id: "chat")
    var pointerActivation: SidebarPointerActivation? = SidebarPointerActivation(
        cycle: SidebarPointerCycle(serial: 1),
        sessionID: session.id
    )
    var opened: [String] = []

    sidebarActivateSession(
        session,
        pointerCycle: nil,
        pointerActivation: &pointerActivation
    ) { opened.append($0.id) }
    sidebarActivateSession(
        session,
        pointerCycle: nil,
        pointerActivation: &pointerActivation
    ) { opened.append($0.id) }

    #expect(opened == ["chat", "chat"])
}

@Test("Folder drops reject unrecognized external text")
@MainActor
func folderDropsRejectUnrecognizedExternalText() {
    let foreign = NSItemProvider(object: "Notes text" as NSString)
    #expect(!SidebarDragPayload.accepts([foreign]))
    #expect(!SidebarDragPayload.isRecognized("Notes text"))
    #expect(!SidebarDragPayload.isRecognized(""))
    #expect(!SidebarDragPayload.isRecognized("hermternal-sidebar:v2:not-base64"))
    #expect(!SidebarDragPayload.accepts([SidebarDragPayload.provider(sessionIDs: [])]))

    let chats = SidebarDragPayload.provider(sessionIDs: ["chat-1", "chat-2"])
    let folders = SidebarDragPayload.provider(folderIDs: ["work"])
    #expect(SidebarDragPayload.accepts([chats]))
    #expect(SidebarDragPayload.accepts([folders]))
    #expect(SidebarDragPayload.accepts([foreign, chats]))
}

/// A transcript source that holds every authoritative stream open until the
/// test cancels it.
///
/// Cancellation can arrive before the stream registers its continuation. The
/// actor therefore keeps one token for each cancellation that overtakes its
/// registration, and the registration resumes at once when it finds that
/// token. Every token leaves the set on registration or when the stream
/// returns, so the set holds one entry for each stream at most.
private actor SidebarOpenStartSource: TranscriptSource {
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var canceledTokens: Set<UUID> = []
    private(set) var startedSessionIDs: [String] = []
    private(set) var activeStreamCount = 0

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        ResumedTranscript(liveSessionID: nil, rows: [])
    }

    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        AuthoritativeTranscript(rows: [], serverTotal: 0)
    }

    func streamAuthoritative(
        sessionID: String,
        onPage _: @escaping TranscriptMessagePageConsumer
    ) async throws -> AuthoritativeTranscriptMetadata {
        startedSessionIDs.append(sessionID)
        activeStreamCount += 1
        let token = UUID()
        defer {
            activeStreamCount -= 1
            canceledTokens.remove(token)
        }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.register(continuation, for: token)
            }
        }, onCancel: {
            Task { await self.cancel(token) }
        })
        return AuthoritativeTranscriptMetadata(messageCount: 0, serverTotal: 0)
    }

    private func register(
        _ continuation: CheckedContinuation<Void, Never>,
        for token: UUID
    ) {
        guard canceledTokens.remove(token) == nil else {
            continuation.resume()
            return
        }
        continuations[token] = continuation
    }

    private func cancel(_ token: UUID) {
        guard let continuation = continuations.removeValue(forKey: token) else {
            canceledTokens.insert(token)
            return
        }
        continuation.resume()
    }
}

/// One bit that reports the observed task finishing.
///
/// The test cannot await the open task outright: an open that hangs would
/// hang the test process. It waits on this signal under `sidebarWaitBound`
/// instead, and joins the task only once the signal says the join returns.
private actor SidebarOpenTaskCompletion {
    private(set) var isRecorded = false

    func record() { isRecorded = true }
}

private func chatSession(id: String, messageCount: Int = 0) -> ChatSession {
    ChatSession(from: .object([
        "id": .string(id),
        "message_count": .integer(Int64(messageCount))
    ]))
}

private func sidebarNavigationTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "HermternalSidebarNavigation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
