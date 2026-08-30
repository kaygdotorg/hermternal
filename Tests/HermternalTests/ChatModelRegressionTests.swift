import Foundation
import HermternalCore
import Testing
@testable import Hermternal

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
