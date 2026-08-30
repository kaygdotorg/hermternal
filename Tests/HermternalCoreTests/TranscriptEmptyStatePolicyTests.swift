import HermternalCore
import Testing

@Test("a new chat shows the mark before any route exists")
func newChatShowsMark() {
    #expect(TranscriptEmptyStatePolicy.showsEmptyState(
        publishedMessageCount: 0,
        summary: nil,
        selectedSessionID: nil,
        archivedSessionID: nil
    ))
}

@Test("an installed route decides by its own row count")
func installedRouteDecidesByRows() {
    #expect(TranscriptEmptyStatePolicy.showsEmptyState(
        publishedMessageCount: 0,
        summary: TranscriptSummary(rowCount: 0, messageCount: 0),
        selectedSessionID: "s1",
        archivedSessionID: nil
    ))
    #expect(!TranscriptEmptyStatePolicy.showsEmptyState(
        publishedMessageCount: 0,
        summary: TranscriptSummary(rowCount: 12, messageCount: 6),
        selectedSessionID: "s1",
        archivedSessionID: nil
    ))
}

@Test("an archived chat with no rows shows the mark")
func archivedEmptyShowsMark() {
    #expect(TranscriptEmptyStatePolicy.showsEmptyState(
        publishedMessageCount: 0,
        summary: TranscriptSummary(rowCount: 0, messageCount: 0),
        selectedSessionID: "a1",
        archivedSessionID: "a1"
    ))
}

@Test("an open in flight draws nothing rather than flashing the mark")
func openInFlightHidesMark() {
    #expect(!TranscriptEmptyStatePolicy.showsEmptyState(
        publishedMessageCount: 0,
        summary: nil,
        selectedSessionID: "s1",
        archivedSessionID: nil
    ))
    #expect(!TranscriptEmptyStatePolicy.showsEmptyState(
        publishedMessageCount: 0,
        summary: nil,
        selectedSessionID: nil,
        archivedSessionID: "a1"
    ))
}

@Test("published messages hide the mark without any summary")
func publishedMessagesHideMark() {
    #expect(!TranscriptEmptyStatePolicy.showsEmptyState(
        publishedMessageCount: 1,
        summary: nil,
        selectedSessionID: nil,
        archivedSessionID: nil
    ))
    #expect(!TranscriptEmptyStatePolicy.showsEmptyState(
        publishedMessageCount: 2,
        summary: nil,
        selectedSessionID: nil,
        archivedSessionID: nil
    ))
}
