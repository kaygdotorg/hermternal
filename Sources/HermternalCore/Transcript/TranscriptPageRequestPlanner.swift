import Foundation

/// Pure page-alignment policy shared by paged transcript renderers.
///
/// A viewport may span many rows, but each aligned page is requested once. This
/// prevents synchronous row-height callbacks from producing one overlapping
/// network/disk read per ordinal.
public enum TranscriptPageRequestPlanner {
    public static let pageSize = 64

    public static func alignedStarts(
        for range: Range<Int>,
        totalRows: Int,
        pageSize size: Int = Self.pageSize
    ) -> [Int] {
        guard size > 0, totalRows > 0, !range.isEmpty else { return [] }
        let lower = max(0, range.lowerBound)
        let upper = min(totalRows, max(lower, range.upperBound))
        guard lower < upper else { return [] }
        let first = (lower / size) * size
        let last = ((upper - 1) / size) * size
        return stride(from: first, through: last, by: size).filter { $0 < totalRows }
    }
}
