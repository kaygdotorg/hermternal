/// Whether a transcript surface has nothing to draw, and therefore shows the
/// product mark in place of rows.
///
/// The rule lives here because it reads only transcript state, and because a
/// renderer change already broke it once. A paged renderer counts rows through
/// a summary, but a summary exists only after a route is installed. A new chat
/// has no route: `session.create` persists no row until the first prompt.
/// A missing summary is therefore not a summary of zero rows, and a rule that
/// reads the summary alone leaves a new chat blank.
public enum TranscriptEmptyStatePolicy {
    /// - Parameters:
    ///   - publishedMessageCount: The count of the bounded transcript the app
    ///     publishes. It is the only record of a new chat, which streams its
    ///     first turn before any store exists.
    ///   - summary: The installed route's summary, or `nil` when no route is
    ///     installed.
    ///   - selectedSessionID: The selected live chat, or `nil`.
    ///   - archivedSessionID: The archived chat on display, or `nil`.
    /// - Returns: `true` when the surface must show the product mark.
    public static func showsEmptyState(
        publishedMessageCount: Int,
        summary: TranscriptSummary?,
        selectedSessionID: String?,
        archivedSessionID: String?
    ) -> Bool {
        // Published messages are content, whichever route they came from.
        guard publishedMessageCount == 0 else { return false }
        // An installed route counts its own rows. A stored chat with no rows
        // is empty, whether it is live or archived.
        if let summary { return summary.rowCount == 0 }
        // No route and no messages. A selection means an open is in flight and
        // its rows are about to arrive, so that window draws nothing rather
        // than flashing the mark under the incoming transcript. No selection
        // means a new chat, or no chat, which is the empty state.
        return selectedSessionID == nil && archivedSessionID == nil
    }
}
