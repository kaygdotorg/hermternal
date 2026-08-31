import Foundation
@testable import Hermternal
@testable import HermternalCore
import Testing
import os

@Test("An empty cache launches signed out")
@MainActor
func emptyCacheLaunchPresentsSignIn() throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(cache: HistoryCache(directory: directory))

    #expect(model.phase == .signedOut)
    #expect(model.sessions.isEmpty)
    #expect(!model.sessionExpiredBanner)
}

@Test("A warm session list restores the last selected chat")
@MainActor
func warmSessionListRestoresLastSelection() throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let older = ChatSession(
        id: "older",
        title: "Older",
        lastActive: Date(timeIntervalSince1970: 100),
        messageCount: 1
    )
    let newer = ChatSession(
        id: "newer",
        title: "Newer",
        lastActive: Date(timeIntervalSince1970: 200),
        messageCount: 1
    )
    let list = SessionListCache(directory: directory)
    #expect(list.saveSessions([older, newer]))
    #expect(list.saveSelectedSessionID("older"))

    let model = AppModel(cache: HistoryCache(directory: directory))

    #expect(model.phase == .restoring)
    #expect(model.sessions.map(\.id) == ["newer", "older"])
    #expect(model.selectedSessionID == "older")
}

@Test("A missing selection falls back to the most recently active chat")
@MainActor
func missingSelectionFallsBackToMostRecentActivity() throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let older = ChatSession(
        id: "older",
        title: "Older",
        lastActive: Date(timeIntervalSince1970: 100),
        messageCount: 1
    )
    let newer = ChatSession(
        id: "newer",
        title: "Newer",
        lastActive: Date(timeIntervalSince1970: 200),
        messageCount: 1
    )
    let list = SessionListCache(directory: directory)
    #expect(list.saveSessions([older, newer]))

    let model = AppModel(cache: HistoryCache(directory: directory))

    #expect(model.phase == .restoring)
    #expect(model.selectedSessionID == "newer")
}

@Test("A refresh rejection keeps the cached workspace and raises the banner")
@MainActor
func refreshRejectionKeepsCachedWorkspace() throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let list = SessionListCache(directory: directory)
    #expect(list.saveSessions([ChatSession(id: "chat-1", title: "Cached")]))
    let model = AppModel(cache: HistoryCache(directory: directory))
    #expect(model.phase == .restoring)

    model.handleConnectionFailure(AuthError.sessionExpired)

    #expect(model.phase == .restoring)
    #expect(model.sessionExpiredBanner)
}

@Test("Restore without credentials presents the sign-in screen")
@MainActor
func restoreWithoutCredentialsPresentsSignIn() async throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentialsDirectory = directory.appending(
        path: "credentials",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: credentialsDirectory, withIntermediateDirectories: true)
    let model = AppModel(
        cache: HistoryCache(directory: directory),
        credentialStore: FileCredentialStore(directory: credentialsDirectory)
    )
    model.serverText = "https://launch-restore-test.example"

    await model.restoreOrPromptSignIn()

    #expect(model.phase == .signedOut)
    #expect(!model.sessionExpiredBanner)
}

@Test("A warm transcript cache paints a static restored chat without network")
@MainActor
func warmTranscriptCachePaintsWithoutNetwork() async throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = ChatSession(
        id: "restored-chat",
        title: "Restored",
        lastActive: Date(timeIntervalSince1970: 1_700_000_000),
        messageCount: 4
    )
    let messages = [
        ChatMessage(id: .server(ServerMessageID(rawValue: 1)), role: .user, text: "Hello"),
        ChatMessage(id: .server(ServerMessageID(rawValue: 2)), role: .assistant, text: "Hi", isStreaming: true)
    ]
    let snapshot = AuthoritativeTranscriptSnapshot(
        sessionID: session.id,
        serverTotal: 2,
        fetchedRows: 2,
        projectedMessages: 2,
        truncated: false,
        fetchedAt: Date(timeIntervalSince1970: 0)
    )
    let history = HistoryCache(directory: directory)
    _ = await history.store(messages, snapshot: snapshot, for: session.id)
    let list = SessionListCache(directory: directory)
    #expect(list.saveSessions([session]))
    #expect(list.saveSelectedSessionID(session.id))
    let source = LaunchRestoreProbeSource()
        let model = AppModel(
            cache: history,
            transcriptSource: source,
            warmStore: TranscriptWarmStore()
        )
        model.cacheEnabled = true

        model.publishRestoredTranscript()

    #expect(model.phase == .restoring)
    #expect(model.messages.map(\.text) == ["Hello", "Hi"])
    #expect(model.messages.allSatisfy { !$0.isStreaming })
    #expect(!model.isAwaitingReply)
    #expect(source.touchCount == 0)
    model.cancelOpenPreparation()
}

@Test("Selecting a chat persists the id for the next launch")
@MainActor
func selectingAChatPersistsForNextLaunch() async throws {
    let directory = try launchRestoreTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = ChatSession(id: "first", title: "First", lastActive: Date(timeIntervalSince1970: 1))
    let second = ChatSession(id: "second", title: "Second", lastActive: Date(timeIntervalSince1970: 2))
    let list = SessionListCache(directory: directory)
    #expect(list.saveSessions([first, second]))
    let model = AppModel(
        cache: HistoryCache(directory: directory),
        transcriptSource: LaunchRestoreSilentSource()
    )
    model.phase = .ready
    _ = model.requestOpen(second)
    #expect(SessionListCache(directory: directory).loadSelectedSessionID() == "second")

    let relaunched = AppModel(cache: HistoryCache(directory: directory))
    #expect(relaunched.selectedSessionID == "second")
}

private struct LaunchRestoreSilentSource: TranscriptSource {
    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        AuthoritativeTranscript(rows: [], serverTotal: 0)
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        ResumedTranscript(liveSessionID: nil, rows: [])
    }
}

private final class LaunchRestoreProbeSource: TranscriptSource, @unchecked Sendable {
    private let touches = OSAllocatedUnfairLock(initialState: 0)

    var touchCount: Int {
        touches.withLock { $0 }
    }

    func fetchAuthoritative(sessionID _: String) async throws -> AuthoritativeTranscript {
        touches.withLock { $0 += 1 }
        return AuthoritativeTranscript(rows: [], serverTotal: 0)
    }

    func resume(sessionID _: String) async throws -> ResumedTranscript {
        touches.withLock { $0 += 1 }
        return ResumedTranscript(liveSessionID: nil, rows: [])
    }
}

private func launchRestoreTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalLaunchRestore-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
