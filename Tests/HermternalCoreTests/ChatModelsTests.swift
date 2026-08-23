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

private func chatSession(title: String, preview: String) -> ChatSession {
    ChatSession(from: .object([
        "title": .string(title),
        "preview": .string(preview)
    ]))
}
