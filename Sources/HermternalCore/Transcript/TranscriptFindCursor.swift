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

/// A bounded Find scan and whether more matches exist past the cap.
public struct TranscriptFindCollection: Sendable {
    public let matches: [TranscriptFindMatch]
    public let isTruncated: Bool

    public init(matches: [TranscriptFindMatch], isTruncated: Bool) {
        self.matches = matches
        self.isTruncated = isTruncated
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

    public static let matchCap = 256
    public static let pageSize = 64

    public func next(maximumResults: Int = 64) async throws -> [TranscriptFindMatch] {
        let limit = min(maximumResults, Self.matchCap)
        guard limit > 0, !isCancelled, !isFetching else { return [] }
        isFetching = true
        defer { isFetching = false }
        let result = try await store.findPage(query: query, startOrdinal: nextOrdinal, maximumResults: limit)
        guard !isCancelled else { return [] }
        nextOrdinal = result.nextOrdinal
        return result.matches
    }

    /// Collects matches up to `limit` and reports whether the cap hid more.
    public func collect(
        limit: Int = TranscriptFindCursor.matchCap,
        pageSize: Int = TranscriptFindCursor.pageSize
    ) async throws -> TranscriptFindCollection {
        let cap = max(limit, 0)
        var matches: [TranscriptFindMatch] = []
        matches.reserveCapacity(min(cap, Self.pageSize))
        var isTruncated = false
        while !Task.isCancelled {
            if matches.count >= cap {
                let peek = try await next(maximumResults: 1)
                isTruncated = !peek.isEmpty
                break
            }
            let pageLimit = min(pageSize, cap - matches.count)
            let page = try await next(maximumResults: pageLimit)
            if page.isEmpty { break }
            matches.append(contentsOf: page)
        }
        if matches.count > cap {
            isTruncated = true
            matches = Array(matches.prefix(cap))
        }
        return TranscriptFindCollection(matches: matches, isTruncated: isTruncated)
    }

    public func cancel() {
        isCancelled = true
        nextOrdinal = Int.max
    }
}

public typealias FindCursor = TranscriptFindCursor
