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
    let publishedTail: [ChatMessage]
    /// Stable chat identity for the painted surface. The paged route is nil
    /// on the selection turn, so this is what distinguishes two tails.
    let paintIdentity: String
    let onCopyCode: (String) -> Void
    let onPaint: (UInt64) -> Void

    init(
        store: (any TranscriptTurnPageLocating)?,
        route: TranscriptRoute?,
        summary: TranscriptSummary?,
        revision: UInt64,
        isReadOnly: Bool,
        isStreaming: Bool,
        findQuery: String,
        pendingMessageID: String?,
        findMessageID: String?,
        showsMetadata: Bool,
        publishedTail: [ChatMessage] = [],
        paintIdentity: String = "",
        onCopyCode: @escaping (String) -> Void,
        onPaint: @escaping (UInt64) -> Void
    ) {
        self.store = store
        self.route = route
        self.summary = summary
        self.revision = revision
        self.isReadOnly = isReadOnly
        self.isStreaming = isStreaming
        self.findQuery = findQuery
        self.pendingMessageID = pendingMessageID
        self.findMessageID = findMessageID
        self.showsMetadata = showsMetadata
        self.publishedTail = publishedTail
        self.paintIdentity = paintIdentity
        self.onCopyCode = onCopyCode
        self.onPaint = onPaint
    }
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
