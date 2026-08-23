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

@Test("DateParser preserves fractional and whole-second ISO8601 timestamps")
func dateParserParsesISO8601Forms() {
    let fractional = DateParser.date(
        from: .string("2023-11-14T22:13:20.125Z")
    )
    let wholeSecond = DateParser.date(
        from: .string("2023-11-14T22:13:20Z")
    )

    #expect(fractional == Date(timeIntervalSince1970: 1_700_000_000.125))
    #expect(wholeSecond == Date(timeIntervalSince1970: 1_700_000_000))
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
        "archived": .bool(true),
        "source": .string("api_server")
    ]))

    #expect(session.lastActive == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(session.pinned)
    #expect(session.archived)
    #expect(session.source == "api_server")
}

@Test("ChatSession defaults absent dashboard properties")
func chatSessionDefaultsAbsentDashboardProperties() {
    let session = ChatSession(from: .object(["id": .string("session-2")]))

    #expect(session.lastActive == nil)
    #expect(!session.pinned)
    #expect(!session.archived)
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
        "archived": .bool(true),
        "source": .string("api_server"),
        "profile": .string("work"),
        "message_count": .integer(7)
    ]))

    let pinned = session.withPinned(true)

    #expect(!session.pinned)
    #expect(pinned.pinned)
    #expect(session.archived)
    #expect(pinned.archived)
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

@Test("withArchived preserves every ChatSession field")
func chatSessionWithArchivedPreservesFields() {
    let session = ChatSession(from: .object([
        "id": .string("session-archived"),
        "title": .string("A saved chat"),
        "preview": .string("A preview"),
        "started_at": .integer(1_700_000_000),
        "last_active": .integer(1_700_000_600),
        "pinned": .bool(true),
        "archived": .bool(false),
        "source": .string("api_server"),
        "profile": .string("work"),
        "message_count": .integer(7)
    ]))

    let archived = session.withArchived(true)

    #expect(!session.archived)
    #expect(archived.archived)
    #expect(archived.pinned == session.pinned)
    #expect(archived.id == session.id)
    #expect(archived.title == session.title)
    #expect(archived.preview == session.preview)
    #expect(archived.startedAt == session.startedAt)
    #expect(archived.lastActive == session.lastActive)
    #expect(archived.source == session.source)
    #expect(archived.profile == session.profile)
    #expect(archived.messageCount == session.messageCount)
    #expect(archived.displayTitle == session.displayTitle)
}

@Test("withArchived can round-trip the archive state")
func chatSessionWithArchivedRoundTrips() {
    let session = chatSession(title: "A chat", preview: "A preview")

    let roundTripped = session.withArchived(true).withArchived(false)

    #expect(roundTripped == session)
}

@Test("withPinned and withArchived compose in either order")
func chatSessionCopiesCompose() {
    let session = chatSession(title: "A chat", preview: "A preview")

    let pinnedThenArchived = session.withPinned(true).withArchived(true)
    let archivedThenPinned = session.withArchived(true).withPinned(true)

    #expect(pinnedThenArchived.pinned)
    #expect(pinnedThenArchived.archived)
    #expect(archivedThenPinned.pinned)
    #expect(archivedThenPinned.archived)
    #expect(pinnedThenArchived == archivedThenPinned)
}

@Test("withPinned preserves the New Chat fallback title")
func chatSessionWithPinnedPreservesFallbackDisplayTitle() {
    let session = chatSession(title: "", preview: "### Generate a title")

    #expect(session.withPinned(true).displayTitle == "New Chat")
    #expect(session.withPinned(false).displayTitle == "New Chat")
}

@Test("withTitle sets the title and recomputes the display title")
func chatSessionWithTitleRecomputesDisplayTitle() {
    let session = chatSession(title: "", preview: "Old preview")
    let renamed = session.withTitle("Renamed chat")

    #expect(renamed.title == "Renamed chat")
    #expect(renamed.displayTitle == "Renamed chat")
    #expect(session.displayTitle == "Old preview")
}

@Test("withTitle replaces a New Chat fallback")
func chatSessionWithTitleReplacesNewChatFallback() {
    let session = chatSession(title: "", preview: "### Task: something")

    #expect(session.displayTitle == "New Chat")
    #expect(session.withTitle("Renamed chat").displayTitle == "Renamed chat")
}

@Test("An explicit heading title is honored verbatim")
func chatSessionWithTitleHonorsHeadingText() {
    let session = chatSession(title: "", preview: "A preview")
    let renamed = session.withTitle("### Task: something")

    #expect(renamed.title == "### Task: something")
    #expect(renamed.displayTitle == "### Task: something")
}

@Test("withTitle preserves every other ChatSession field")
func chatSessionWithTitlePreservesEveryOtherField() {
    let session = ChatSession(from: .object([
        "id": .string("session-renamed"),
        "title": .string("Old title"),
        "preview": .string("A preview"),
        "started_at": .integer(1_700_000_000),
        "last_active": .integer(1_700_000_600),
        "pinned": .bool(true),
        "archived": .bool(true),
        "source": .string("api_server"),
        "profile": .string("work"),
        "message_count": .integer(7)
    ]))
    let renamed = session.withTitle("New title")

    #expect(renamed.id == session.id)
    #expect(renamed.title == "New title")
    #expect(renamed.preview == session.preview)
    #expect(renamed.startedAt == session.startedAt)
    #expect(renamed.lastActive == session.lastActive)
    #expect(renamed.pinned == session.pinned)
    #expect(renamed.archived == session.archived)
    #expect(renamed.source == session.source)
    #expect(renamed.profile == session.profile)
    #expect(renamed.messageCount == session.messageCount)
}

private func chatSession(title: String, preview: String) -> ChatSession {
    ChatSession(from: .object([
        "title": .string(title),
        "preview": .string(preview)
    ]))
}
