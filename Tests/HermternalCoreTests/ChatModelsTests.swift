import Foundation
import HermternalCore
import Testing

@Test("A non-empty title wins over its preview")
func chatSessionTitleWinsOverPreview() {
    let session = chatSession(title: "Server title", preview: "A normal preview")

    #expect(session.displayTitle == "Server title")
}

@Test("A title-generation prompt preview is hidden")
func chatSessionHidesTitleGenerationPromptPreview() {
    let session = chatSession(title: "", preview: "### Task: Generate a concise title")

    #expect(session.displayTitle == "New Chat")
}

@Test("A multiline preview is hidden")
func chatSessionHidesMultilinePreview() {
    let session = chatSession(title: "", preview: "First line\nSecond line")

    #expect(session.displayTitle == "New Chat")
}

@Test("A preview of only heading markers is hidden")
func chatSessionHidesMarkerOnlyPreview() {
    #expect(chatSession(title: "", preview: "###").displayTitle == "New Chat")
    #expect(chatSession(title: "", preview: "####").displayTitle == "New Chat")
    #expect(chatSession(title: "", preview: "###   ").displayTitle == "New Chat")
}

@Test("A preview that merely contains a hash is kept")
func chatSessionKeepsPreviewContainingHash() {
    #expect(chatSession(title: "", preview: "C# notes").displayTitle == "C# notes")
    #expect(chatSession(title: "", preview: "#hashtag").displayTitle == "#hashtag")
    #expect(chatSession(title: "", preview: "Fix ### later").displayTitle == "Fix ### later")
}

@Test("A fractional last_active parses")
func chatSessionParsesFractionalLastActive() {
    let session = ChatSession(from: .object([
        "id": .string("session-3"),
        "last_active": .number(1_700_000_000.25)
    ]))

    #expect(session.lastActive == Date(timeIntervalSince1970: 1_700_000_000.25))
}

@Test("A normal preview is capped at 60 characters")
func chatSessionCapsNormalPreview() {
    let preview = String(repeating: "x", count: 80)
    let session = chatSession(title: "", preview: preview)

    #expect(session.displayTitle == String(preview.prefix(60)))
}

@Test("An empty title and preview use the new chat label")
func chatSessionUsesNewChatForEmptyFields() {
    let session = chatSession(title: "", preview: "")

    #expect(session.displayTitle == "New Chat")
}

@Test("ChatSession parses dashboard contract properties")
func chatSessionParsesDashboardProperties() {
    let session = ChatSession(from: .object([
        "id": .string("session-1"),
        "last_active": .integer(1_700_000_000),
        "pinned": .bool(true),
        "source": .string("api_server")
    ]))

    #expect(session.lastActive == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(session.pinned)
    #expect(session.source == "api_server")
}

@Test("ChatSession defaults absent dashboard properties")
func chatSessionDefaultsAbsentDashboardProperties() {
    let session = ChatSession(from: .object(["id": .string("session-2")]))

    #expect(session.lastActive == nil)
    #expect(!session.pinned)
    #expect(session.source.isEmpty)
}

@Test("withPinned preserves every ChatSession field")
func chatSessionWithPinnedPreservesFields() {
    let session = ChatSession(from: .object([
        "id": .string("session-pinned"),
        "title": .string("A saved chat"),
        "preview": .string("A preview"),
        "started_at": .integer(1_700_000_000),
        "last_active": .integer(1_700_000_600),
        "pinned": .bool(false),
        "source": .string("api_server"),
        "profile": .string("work"),
        "message_count": .integer(7)
    ]))

    let pinned = session.withPinned(true)

    #expect(!session.pinned)
    #expect(pinned.pinned)
    #expect(pinned.id == session.id)
    #expect(pinned.title == session.title)
    #expect(pinned.preview == session.preview)
    #expect(pinned.startedAt == session.startedAt)
    #expect(pinned.lastActive == session.lastActive)
    #expect(pinned.source == session.source)
    #expect(pinned.profile == session.profile)
    #expect(pinned.messageCount == session.messageCount)
    #expect(pinned.displayTitle == session.displayTitle)
}

@Test("withPinned can round-trip the pin state")
func chatSessionWithPinnedRoundTrips() {
    let session = chatSession(title: "A chat", preview: "A preview")

    let roundTripped = session.withPinned(true).withPinned(false)

    #expect(roundTripped == session)
    #expect(roundTripped.displayTitle == session.displayTitle)
}

@Test("withPinned preserves the New Chat fallback title")
func chatSessionWithPinnedPreservesFallbackDisplayTitle() {
    let session = chatSession(title: "", preview: "### Generate a title")

    #expect(session.withPinned(true).displayTitle == "New Chat")
    #expect(session.withPinned(false).displayTitle == "New Chat")
}

private func chatSession(title: String, preview: String) -> ChatSession {
    ChatSession(from: .object([
        "title": .string(title),
        "preview": .string(preview)
    ]))
}
