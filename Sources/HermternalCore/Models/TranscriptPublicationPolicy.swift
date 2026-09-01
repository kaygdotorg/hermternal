/// Bounds for the amount of transcript data published synchronously when a
/// selection changes. This is deliberately separate from AppKit's lazy row
/// virtualization: it keeps selection and held-arrow navigation cheap without
/// limiting the rows available to the renderer after publication.
public enum TranscriptPublicationPolicy {
    /// The tail copied before the first await on the selection path.
    public static let initialMessageCount = 12
    /// Wall-clock budget for publishing that tail from cache or a warm projection.
    public static let firstPaintBudgetMilliseconds = 100
    /// Wall-clock budget for publishing a warm or sidecar tail on the selection turn.
    public static let keypressPaintBudgetMilliseconds = 16
    /// p95 wall from cached-tail publish to first on-screen draw on a held-arrow walk.
    public static let publishToDrawBudgetMilliseconds = 16
    /// Delay before installing the paged store after a selection. Held-arrow
    /// traversal cancels the previous opener, so only the settled chat pays
    /// for page install.
    public static let storeAttachSettleNanoseconds: UInt64 = 50_000_000
}
