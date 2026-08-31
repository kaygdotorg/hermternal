import Foundation
import Testing
@testable import Hermternal
@testable import HermternalCore

@Test("Terminal reconciliation removes only provisional rows with the durable turn identity")
@MainActor
func terminalReconciliationRemovesMatchingProvisionalRows() async throws {
    let directory = try chatModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = TranscriptFixtureSource(rows: [
        transcriptRow(id: 101, text: "Existing", turnID: "turn-existing"),
        transcriptRow(id: 102, text: "Durable answer", turnID: "turn-complete")
    ])
    let model = AppModel(cache: HistoryCache(directory: directory), transcriptSource: source)
    let session = chatSession(id: "chat", messageCount: 2)
    model.sessions = [session]
    model.cacheEnabled = true
    #expect(await model.open(session))

    let matchedID = UUID()
    let unrelatedID = UUID()
    model.messages = [
        ChatMessage(
            id: .provisional(matchedID),
            role: .assistant,
            text: "Streaming answer",
            turnID: "turn-complete"
        )
    ]
    await model.persistTranscriptTail(model.messages)
    model.messages.append(
        ChatMessage(
            id: .provisional(unrelatedID),
            role: .assistant,
            text: "Different turn",
            turnID: "turn-unrelated"
        )
    )
    await model.persistTranscriptTail(model.messages)

    await model.reconcileTerminal(.complete)

    let store = try #require(model.activeTranscriptStore)
    #expect(try await store.locate(messageID: matchedID.uuidString) == nil)
    #expect(try await store.locate(messageID: "102") != nil)
    #expect(try await store.locate(messageID: unrelatedID.uuidString) != nil)
}

@Test("Older deep link remains pending when the paged store contains it")
@MainActor
func olderDeepLinkUsesPagedStoreInsteadOfVisibleTail() async throws {
    let directory = try chatModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let rows = (1...13).map { transcriptRow(id: Int64($0), text: "Message \($0)", turnID: "turn-\($0)") }
    let source = TranscriptFixtureSource(rows: rows)
    let model = AppModel(cache: HistoryCache(directory: directory), transcriptSource: source)
    let session = chatSession(id: "chat", messageCount: rows.count)
    let target = MessageLocation(sessionID: session.id, messageID: ServerMessageID(rawValue: 1))
    model.sessions = [session]
    model.cacheEnabled = true

    await model.open(at: target)

    #expect(!model.messages.contains { $0.id == .server(target.messageID) })
    #expect(model.pendingMessageLocation == target)
}

@Test("Browsing a chat does not prepare a live session")
@MainActor
func browsingChatDoesNotPrepareLiveSession() async throws {
    let directory = try chatModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = BrowseOnlyTranscriptSource(rows: [transcriptRow(
        id: 1,
        text: "Existing",
        turnID: "turn-existing"
    )])
    let model = AppModel(cache: HistoryCache(directory: directory), transcriptSource: source)
    let session = chatSession(id: "chat", messageCount: 1)
    model.sessions = [session]
    model.cacheEnabled = true

    #expect(await model.open(session))
    #expect(await source.resumeCalls == 0)
}

@Test("Gateway error event posts one title-detail toast")
@MainActor
func gatewayErrorEventPostsOneTitleDetailToast() async throws {
    let toastPresenter = ToastPresenter()
    let model = AppModel(toastPresenter: toastPresenter)

    await model.handle(GatewayEvent(
        type: "error",
        sessionID: nil,
        payload: .object(["message": .string("Agent initialization failed.")])
    ))

    let entry = try #require(toastPresenter.entries.first)
    #expect(toastPresenter.entries.count == 1)
    #expect(entry.message.title == "The gateway reported an error")
    #expect(entry.message.detail == "Agent initialization failed.")
}

private actor BrowseOnlyTranscriptSource: TranscriptSource {
    let rows: [JSONValue]
    private(set) var resumeCalls = 0

    init(rows: [JSONValue]) {
        self.rows = rows
    }

    func fetchAuthoritative(sessionID: String) async throws -> AuthoritativeTranscript {
        AuthoritativeTranscript(rows: rows, serverTotal: rows.count)
    }

    func resume(sessionID: String) async throws -> ResumedTranscript {
        resumeCalls += 1
        return ResumedTranscript(liveSessionID: nil, rows: [])
    }

    func streamAuthoritative(
        sessionID: String,
        onPage: @escaping TranscriptMessagePageConsumer
    ) async throws -> AuthoritativeTranscriptMetadata {
        try await onPage(TranscriptMessagePage(
            messages: rows,
            offset: 0,
            serverTotal: rows.count
        ))
        return AuthoritativeTranscriptMetadata(messageCount: rows.count, serverTotal: rows.count)
    }
}

private struct TranscriptFixtureSource: TranscriptSource {
    let rows: [JSONValue]

    func fetchAuthoritative(sessionID: String) async throws -> AuthoritativeTranscript {
        AuthoritativeTranscript(rows: rows, serverTotal: rows.count)
    }

    func resume(sessionID: String) async throws -> ResumedTranscript {
        ResumedTranscript(liveSessionID: nil, rows: [])
    }

    func streamAuthoritative(
        sessionID: String,
        onPage: @escaping TranscriptMessagePageConsumer
    ) async throws -> AuthoritativeTranscriptMetadata {
        try await onPage(TranscriptMessagePage(
            messages: rows,
            offset: 0,
            serverTotal: rows.count
        ))
        return AuthoritativeTranscriptMetadata(messageCount: rows.count, serverTotal: rows.count)
    }
}

private func transcriptRow(id: Int64, text: String, turnID: String) -> JSONValue {
    .object([
        "id": .integer(id),
        "role": .string("assistant"),
        "text": .string(text),
        "turn_id": .string(turnID)
    ])
}

private func chatSession(id: String, messageCount: Int) -> ChatSession {
    ChatSession(from: .object([
        "id": .string(id),
        "message_count": .integer(Int64(messageCount))
    ]))
}

private func chatModelTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalChatModel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}


@Test("Empty terminal reconciliation retains the live transcript")
@MainActor
func emptyTerminalReconciliationRetainsLiveRows() async throws {
    let directory = try chatModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = AppModel(
        cache: HistoryCache(directory: directory),
        transcriptSource: TranscriptFixtureSource(rows: [])
    )
    let session = chatSession(id: "chat", messageCount: 0)
    model.sessions = [session]
    model.cacheEnabled = true
    #expect(await model.open(session))
    model.messages = [ChatMessage(role: .assistant, text: "Live answer")]

    await model.reconcileTerminal(.complete)

    #expect(model.messages.map(\.text) == ["Live answer"])
}

@Test("New-chat persist writes the optimistic turn without a durable selection")
@MainActor
func newChatPersistWritesWithoutDurableSelection() async throws {
    let directory = try chatModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = AppModel(
        cache: HistoryCache(directory: directory),
        transcriptSource: TranscriptFixtureSource(rows: [])
    )
    let session = chatSession(id: "chat", messageCount: 0)
    model.sessions = [session]
    model.cacheEnabled = true
    #expect(await model.open(session))

    model.selectedSessionID = nil
    let messageID = UUID()
    model.messages = [
        ChatMessage(
            id: .provisional(messageID),
            role: .user,
            text: "First prompt"
        )
    ]
    await model.persistTranscriptTail(model.messages)

    let store = try #require(model.activeTranscriptStore)
    #expect(try await store.locate(messageID: messageID.uuidString) != nil)
    #expect((model.transcriptSummary?.rowCount ?? 0) > 0)
}

@Test("Gateway stream events for another session do not reduce the open chat")
@MainActor
func foreignSessionEventsDoNotReduceOpenChat() async throws {
    let directory = try chatModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = AppModel(
        cache: HistoryCache(directory: directory),
        transcriptSource: TranscriptFixtureSource(rows: [])
    )
    let session = chatSession(id: "chat", messageCount: 0)
    model.sessions = [session]
    model.cacheEnabled = true
    #expect(await model.open(session))
    model.messages = [ChatMessage(role: .user, text: "Keep")]

    await model.handle(GatewayEvent(
        type: "message.start",
        sessionID: "other",
        payload: .object(["text": .string("")])
    ))

    #expect(model.messages.map(\.text) == ["Keep"])
}


@Test("Gateway stream events without a session id do not reduce the open chat")
@MainActor
func unnamedSessionEventsDoNotReduceOpenChat() async throws {
    let directory = try chatModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = AppModel(
        cache: HistoryCache(directory: directory),
        transcriptSource: TranscriptFixtureSource(rows: [])
    )
    let session = chatSession(id: "chat", messageCount: 0)
    model.phase = .ready
    model.sessions = [session]
    model.cacheEnabled = true
    #expect(await model.open(session))
    model.messages = [ChatMessage(role: .user, text: "Keep")]

    await model.handle(GatewayEvent(
        type: "message.start",
        sessionID: nil,
        payload: .object(["text": .string("")])
    ))
    await model.handle(GatewayEvent(
        type: "message.delta",
        sessionID: nil,
        payload: .object(["text": .string("unnamed")])
    ))
    await model.handle(GatewayEvent(
        type: "message.delta",
        sessionID: "",
        payload: .object(["text": .string("empty-id")])
    ))

    #expect(model.messages.map(\.text) == ["Keep"])
    #expect(!model.messages.contains { $0.text.contains("unnamed") })
}

@Test("requestOpen of the displayed session keeps the in-flight stream")
@MainActor
@Test("requestOpen publishes the cache tail before paged store install")
@MainActor
func requestOpenPublishesCacheTailBeforePagedStoreInstall() async throws {
    let directory = try chatModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let messages = (0..<500).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "cached transcript row \(index)"
        )
    }
    let session = chatSession(id: "five-hundred", messageCount: 500)
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: session.id,
        serverTotal: 500,
        fetchedRows: 500,
        projectedMessages: 500,
        truncated: false,
        fetchedAt: Date(timeIntervalSince1970: 0)
    )
    let cache = HistoryCache(directory: directory)
    _ = await cache.store(messages, snapshot: snapshot, for: session.id)
    let model = AppModel(
        cache: cache,
        transcriptSource: TranscriptFixtureSource(rows: []),
        warmStore: TranscriptWarmStore()
    )
    model.sessions = [session]
    model.cacheEnabled = true

    let task = model.requestOpen(session)
    #expect(model.transcriptRouteIdentity == "live:\(session.id)")
    #expect(model.messages.count == TranscriptPublicationPolicy.initialMessageCount)
    #expect(model.messages.map(\.text) == Array(messages.suffix(12).map(\.text)))
    #expect(await cache.existingPagedStore(for: session.id) == nil)
    model.cancelOpenPreparation()
    _ = task
}

@Test("requestOpen keeps live reductions when the paged store installs")
@MainActor
func requestOpenKeepsLiveReductionsAcrossPagedStoreInstall() async throws {
    let directory = try chatModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let messages = (0..<20).map { index in
        ChatMessage(
            id: .server(ServerMessageID(rawValue: Int64(index))),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "cached transcript row \(index)"
        )
    }
    let session = chatSession(id: "live-swap", messageCount: 20)
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: session.id,
        serverTotal: 20,
        fetchedRows: 20,
        projectedMessages: 20,
        truncated: false,
        fetchedAt: Date(timeIntervalSince1970: 0)
    )
    let cache = HistoryCache(directory: directory)
    _ = await cache.store(messages, snapshot: snapshot, for: session.id)
    let model = AppModel(
        cache: cache,
        transcriptSource: TranscriptFixtureSource(rows: []),
        warmStore: TranscriptWarmStore()
    )
    model.sessions = [session]
    model.cacheEnabled = true

    let task = model.requestOpen(session)
    let painted = await chatOpenWait(
        until: "first paint publishes the cached tail",
        holds: { model.messages.count == TranscriptPublicationPolicy.initialMessageCount }
    )
    #expect(painted)
    let gateReleased = await chatOpenWait(
        until: "first paint releases the open event gate",
        holds: { !model.isPreparingTranscriptOpen }
    )
    #expect(gateReleased)

    await model.handle(GatewayEvent(
        type: "message.start",
        sessionID: session.id,
        payload: .object(["id": .integer(9_001), "text": .string("")])
    ))
    await model.handle(GatewayEvent(
        type: "message.delta",
        sessionID: session.id,
        payload: .object(["id": .integer(9_001), "text": .string("live tail")])
    ))
    #expect(model.messages.contains { $0.text == "live tail" })


    let installed = await chatOpenWait(
        until: "paged store install completes",
        holds: { model.activeTranscriptStore != nil }
    )
    #expect(installed)
    #expect(model.messages.contains { $0.text == "live tail" })
    model.cancelOpenPreparation()
    _ = task
}

private let chatOpenWaitBound = Duration.seconds(15)

@MainActor
private func chatOpenWait(
    until condition: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    holds: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + chatOpenWaitBound
    while true {
        if await holds() { return true }
        guard ContinuousClock.now < deadline else {
            Issue.record(
                "The wait ended after \(chatOpenWaitBound). The condition did not occur: \(condition).",
                sourceLocation: sourceLocation
            )
            return false
        }
        await Task.yield()
    }
}

