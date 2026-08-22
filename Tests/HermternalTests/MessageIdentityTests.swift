import Foundation
import Testing
@testable import Hermternal

@Test("stable IDs are deterministic for the same history inputs")
func stableIDIsDeterministic() {
    let first = ChatMessage.stableID(
        sessionID: "session-a",
        role: .assistant,
        text: "hello",
        occurrence: 0
    )
    let second = ChatMessage.stableID(
        sessionID: "session-a",
        role: .assistant,
        text: "hello",
        occurrence: 0
    )

    #expect(first == second)
}

@Test("stable IDs change when any identity input changes")
func stableIDIncludesEveryInput() {
    let baseline = ChatMessage.stableID(
        sessionID: "session-a",
        role: .user,
        text: "hello",
        occurrence: 0
    )
    let differentSession = ChatMessage.stableID(
        sessionID: "session-b",
        role: .user,
        text: "hello",
        occurrence: 0
    )
    let differentRole = ChatMessage.stableID(
        sessionID: "session-a",
        role: .assistant,
        text: "hello",
        occurrence: 0
    )
    let differentText = ChatMessage.stableID(
        sessionID: "session-a",
        role: .user,
        text: "goodbye",
        occurrence: 0
    )
    let differentOccurrence = ChatMessage.stableID(
        sessionID: "session-a",
        role: .user,
        text: "hello",
        occurrence: 1
    )

    #expect(baseline != differentSession)
    #expect(baseline != differentRole)
    #expect(baseline != differentText)
    #expect(baseline != differentOccurrence)
}

@Test("identical ping messages use occurrence to get distinct IDs")
func identicalHistoryMessagesAreDistinct() throws {
    let first = try #require(
        ChatMessage(
            historyRow: historyRow(role: .user, text: "ping"),
            sessionID: "session-ping",
            occurrence: 0
        )
    )
    let second = try #require(
        ChatMessage(
            historyRow: historyRow(role: .user, text: "ping"),
            sessionID: "session-ping",
            occurrence: 1
        )
    )

    #expect(first.id != second.id)
}

@Test("projecting history twice produces the same ID sequence")
func historyProjectionIsRepeatable() throws {
    let rows = [
        historyRow(role: .user, text: "ping"),
        historyRow(role: .assistant, text: "pong"),
        historyRow(role: .user, text: "ping")
    ]
    let firstProjection = try project(rows, sessionID: "session-repeatable")
    let secondProjection = try project(rows, sessionID: "session-repeatable")

    #expect(firstProjection.map(\.id) == secondProjection.map(\.id))
}

@Test("storing an identical transcript does not rewrite its cache file")
func identicalCacheStoreIsIdempotent() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = HistoryCache(directory: directory)
    let sessionID = "cache-idempotence"
    let messages = [
        ChatMessage(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            role: .user,
            text: "cached"
        )
    ]

    _ = await cache.store(messages, for: sessionID)
    let target = try #require(try cacheFile(in: directory))
    let firstInode = try #require(try fileNumber(at: target))
    let firstDate = try #require(
        try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    )

    _ = await cache.store(messages, for: sessionID)
    let secondInode = try #require(try fileNumber(at: target))
    let secondDate = try #require(
        try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    )

    #expect(secondInode == firstInode)
    #expect(secondDate == firstDate)
}

@Test("a transcript written with an older cache version is rejected")
func olderCacheVersionIsRejected() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let sessionID = "legacy-version"
    let target = directory.appending(path: "\(sessionID).json")
    let payload: [String: Any] = [
        "version": 1,
        "messages": [[
            "id": "00000000-0000-4000-8000-000000000001",
            "role": "user",
            "text": "legacy",
            "isStreaming": false
        ]]
    ]
    try JSONSerialization.data(withJSONObject: payload).write(to: target)

    let cache = HistoryCache(directory: directory)
    let messages = await cache.messages(for: sessionID)

    #expect(messages == nil)
}

private func historyRow(role: Role, text: String) -> JSONValue {
    .object([
        "role": .string(role.rawValue),
        "text": .string(text)
    ])
}

private func project(_ rows: [JSONValue], sessionID: String) throws -> [ChatMessage] {
    try rows.enumerated().map { index, row in
        try #require(
            ChatMessage(historyRow: row, sessionID: sessionID, occurrence: index)
        )
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func cacheFile(in directory: URL) throws -> URL? {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ).first { $0.pathExtension == "json" }
}

private func fileNumber(at url: URL) throws -> Int64? {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.systemFileNumber] as? NSNumber)?.int64Value
}
