import Foundation

public struct FindQuery: Codable, Hashable, Sendable {
    public let text: String
    public let caseSensitive: Bool
    public let role: String?

    public init(text: String, caseSensitive: Bool = false, role: String? = nil) {
        self.text = text
        self.caseSensitive = caseSensitive
        self.role = role
    }

}

public struct TranscriptFindMatch: Codable, Hashable, Sendable, Identifiable {
    public let descriptor: TranscriptRowDescriptor
    public let ranges: [StringSlice]

    public var id: String { descriptor.id }

    public init(descriptor: TranscriptRowDescriptor, ranges: [StringSlice]) {
        self.descriptor = descriptor
        self.ranges = ranges
    }
}

/// A resumable, disk-backed scan. It retains only its next ordinal and query.
public actor TranscriptFindCursor {
    private let store: PagedTranscriptStore
    private let query: FindQuery
    private var nextOrdinal: Int
    private var isFetching = false
    private var isCancelled = false

    internal init(store: PagedTranscriptStore, query: FindQuery, startOrdinal: Int) {
        self.store = store
        self.query = query
        self.nextOrdinal = max(0, startOrdinal)
    }

    public func next(maximumResults: Int = 64) async throws -> [TranscriptFindMatch] {
        let limit = min(maximumResults, 256)
        guard limit > 0, !isCancelled, !isFetching else { return [] }
        isFetching = true
        defer { isFetching = false }
        let result = try await store.findPage(query: query, startOrdinal: nextOrdinal, maximumResults: limit)
        guard !isCancelled else { return [] }
        nextOrdinal = result.nextOrdinal
        return result.matches
    }

    public func cancel() {
        isCancelled = true
        nextOrdinal = Int.max
    }
}

public typealias FindCursor = TranscriptFindCursor
