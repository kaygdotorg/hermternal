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
}
