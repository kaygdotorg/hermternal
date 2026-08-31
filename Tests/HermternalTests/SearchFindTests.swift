import AppKit
import Foundation
import HermternalCore
import Testing
@testable import Hermternal

@Test("Find count names a capped total")
@MainActor
func findCountLabelMarksTruncation() {
    #expect(
        FindBar.countLabel(
            query: "alpha",
            matchCount: 256,
            selectedMatchNumber: 1,
            isTruncated: true
        ) == "1 of 256+"
    )
    #expect(
        FindBar.countLabel(
            query: "alpha",
            matchCount: 12,
            selectedMatchNumber: 4,
            isTruncated: false
        ) == "4 of 12"
    )
    #expect(
        FindBar.countLabel(
            query: "alpha",
            matchCount: 0,
            selectedMatchNumber: nil,
            isTruncated: false
        ) == "0 matches"
    )
}

@Test("Find request generation advances only when ready")
@MainActor
func findRequestGenerationAdvancesWhenReady() throws {
    let directory = try searchFindTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(cache: HistoryCache(directory: directory))
    model.requestFind()
    #expect(model.findRequestGeneration == 0)
    model.phase = .ready
    model.requestFind()
    #expect(model.findRequestGeneration == 1)
    model.requestFind()
    #expect(model.findRequestGeneration == 2)
}

@Test("Search activation dismisses before open and ignores a second call")
@MainActor
func searchActivationDismissesBeforeOpen() async throws {
    let directory = try searchFindTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(cache: HistoryCache(directory: directory))
    let session = ChatSession(from: .object([
        "id": .string("chat"),
        "message_count": .integer(1)
    ]))
    model.sessions = [session]
    model.cacheEnabled = true
    model.phase = .ready
    model.isSearchPresented = true
    let location = MessageLocation(sessionID: session.id, messageID: ServerMessageID(rawValue: 1))

    model.activateSearchResult(location)
    #expect(!model.isSearchPresented)

    model.activateSearchResult(location)
    #expect(!model.isSearchPresented)
}

@Test("Search selection identity follows the hit location")
@MainActor
func searchSelectionTracksHitLocation() async {
    let hits = (0..<4).map { index in
        SearchHit(
            location: MessageLocation(
                sessionID: "session-\(index)",
                messageID: ServerMessageID(rawValue: Int64(index + 1))
            ),
            sessionTitle: "Chat \(index)",
            excerpt: AttributedString("hit \(index)"),
            role: .user,
            timestamp: nil
        )
    }
    let model = SearchPanelModel(
        querying: FixedSearchQuerying(
            results: SearchResults(hits: hits, pendingIndexingSessions: 0, truncatedSessions: 0)
        )
    )
    model.updateQuery("hit")
    var found = false
    for _ in 0..<200 {
        if case .results = model.state {
            found = true
            break
        }
        await Task.yield()
    }
    #expect(found)
    #expect(model.selectedLocation() == hits[0].location)
    model.moveSelection(.down)
    #expect(model.selectedLocation() == hits[1].location)
    model.moveSelection(.down)
    #expect(model.selectedLocation() == hits[2].location)
}

@Test("Settings window occlusion does not pause main-window toasts")
@MainActor
func settingsWindowOcclusionDoesNotPauseMainToasts() {
    _ = NSApplication.shared
    let main = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    let settings = NSWindow(
        contentRect: NSRect(x: 40, y: 40, width: 320, height: 240),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    main.isReleasedWhenClosed = false
    settings.isReleasedWhenClosed = false
    defer {
        main.close()
        settings.close()
    }
    settings.orderFront(nil)
    main.orderFront(nil)

    let presenter = ToastPresenter()
    presenter.observeOcclusion(of: main)
    presenter.setWindowVisible(false)

    NotificationCenter.default.post(
        name: NSWindow.didChangeOcclusionStateNotification,
        object: settings
    )
    #expect(!presenter.isWindowVisible)

    NotificationCenter.default.post(
        name: NSWindow.didChangeOcclusionStateNotification,
        object: main
    )
    #expect(presenter.isWindowVisible == main.occlusionState.contains(.visible))
}

private struct FixedSearchQuerying: SearchQuerying {
    let results: SearchResults

    func search(_ query: String, limit: Int) async throws -> SearchResults {
        results
    }
}

private func searchFindTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalSearchFind-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
