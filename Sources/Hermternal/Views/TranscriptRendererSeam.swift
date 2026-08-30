import HermternalCore

/// The narrow, bounded seam shared by transcript rendering adapters.
///
/// A renderer never receives the transcript corpus. It receives the route that
/// identifies the publication, its indexed summary, and the actor that owns
/// page reads. Rows and prepared layouts are fetched only for the viewport.
struct TranscriptRendererInput {
    let store: (any TranscriptTurnPageLocating)?
    let route: TranscriptRoute?
    let summary: TranscriptSummary?
    let revision: UInt64
    let isReadOnly: Bool
    let isStreaming: Bool
    let findQuery: String
    let pendingMessageID: String?
    let findMessageID: String?
    let showsMetadata: Bool
    let onCopyCode: (String) -> Void
    let onPaint: (UInt64) -> Void
}

extension TranscriptRendererInput {
    /// Compatibility projections for instrumentation. They are derived from
    /// the immutable route rather than maintained as a second identity source.
    var routeIdentity: String {
        route?.sessionID ?? "none"
    }

    var generation: Int {
        Int(route?.generation ?? 0)
    }
}
