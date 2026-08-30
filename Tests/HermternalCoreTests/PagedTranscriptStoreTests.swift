import Foundation
import XCTest
@testable import HermternalCore

final class PagedTranscriptStoreTests: XCTestCase {
    private func makeStore(_ fs: InMemoryTranscriptFileSystem = InMemoryTranscriptFileSystem()) -> PagedTranscriptStore {
        PagedTranscriptStore(sessionID: "test", directory: URL(fileURLWithPath: "/transcript"), fileSystem: fs)
    }

    func testPagesAreBoundedAndGiantMessagesContinue() async throws {
        let store = makeStore()
        try await store.load()
        try await store.append(WireMessageRecord(messageID: "a", text: String(repeating: "x", count: 10_000)))
        let summary = try await store.summary()
        XCTAssertGreaterThan(summary.rowCount, 2)
        let page = try await store.page(TranscriptPageRequest(maximumBytes: 500, maximumRows: 2))
        XCTAssertLessThanOrEqual(page.rows.count, 2)
        XCTAssertLessThanOrEqual(page.payload.byteCount, 500)
        XCTAssertTrue(page.rows.allSatisfy { $0.descriptor.id.hasPrefix("a:") })
    }

    func testArbitraryPagesLocateAndStreamingRevision() async throws {
        let store = makeStore()
        try await store.append(WireMessageRecord(messageID: "one", text: "one"))
        try await store.append(WireMessageRecord(messageID: "two", text: "two"))
        let location = try await store.locate(messageID: "two")
        XCTAssertEqual(location?.ordinal, 1)
        let middle = try await store.page(TranscriptPageRequest(startOrdinal: 1, maximumBytes: 200, maximumRows: 1))
        XCTAssertEqual(middle.rows.first?.text, "two")
        try await store.append(WireMessageRecord(messageID: "two", text: "two updated", revision: 2))
        let updated = try await store.page(TranscriptPageRequest(startOrdinal: 1, maximumBytes: 200, maximumRows: 1))
        XCTAssertEqual(updated.rows.first?.text, "two updated")
        let tail = try await store.page(.tail(maximumBytes: 200, maximumRows: 1))
        XCTAssertEqual(tail.rows.first?.message.messageID, "two")
    }

    func testStaleGenerationAndDiskRecovery() async throws {
        let fs = InMemoryTranscriptFileSystem()
        let first = makeStore(fs)
        try await first.append(WireMessageRecord(messageID: "a", text: "persisted"))
        let route = try await first.beginGeneration()
        let second = PagedTranscriptStore(route: route, directory: URL(fileURLWithPath: "/transcript"), fileSystem: fs)
        try await second.load()
        let recoveredPage = try await second.page(.head(maximumBytes: 200, maximumRows: 1))
        XCTAssertEqual(recoveredPage.rows.first?.text, "persisted")
        do {
            _ = try await second.append(WireMessageRecord(messageID: "b", text: "stale"), expectedGeneration: route.generation - 1)
            XCTFail("A stale generation must be rejected")
        } catch TranscriptStoreError.staleGeneration {
        }
    }

    func testFindCursorIsPaged() async throws {
        let store = makeStore()
        for index in 0..<100 {
            try await store.append(WireMessageRecord(messageID: "m\(index)", text: index.isMultiple(of: 2) ? "needle" : "other"))
        }
        let cursor = try await store.find(FindQuery(text: "needle"))
        let matches = try await cursor.next(maximumResults: 3)
        XCTAssertEqual(matches.count, 3)
        XCTAssertLessThanOrEqual(matches.count, 3)
    }
    func testPageCacheEvictsAndCancellationStopsRead() async throws {
        let store = makeStore()
        for index in 0..<10 {
            try await store.append(WireMessageRecord(messageID: "p\(index)", text: "value"))
        }
        for index in 0..<10 {
            _ = try await store.page(TranscriptPageRequest(startOrdinal: index, maximumBytes: 200, maximumRows: 1))
        }
        let metrics = await store.metrics()
        XCTAssertGreaterThan(metrics.pageCacheEvictions, 0)

        let task = Task { try await store.page(TranscriptPageRequest(maximumBytes: 200, maximumRows: 1)) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled page read must stop")
        } catch is CancellationError {
        }
    }
}
