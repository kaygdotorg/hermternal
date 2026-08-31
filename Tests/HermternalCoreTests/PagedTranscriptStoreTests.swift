import Foundation
import XCTest
@testable import HermternalCore

final class PagedTranscriptStoreTests: XCTestCase {
    private func makeStore(
        _ fs: any TranscriptFileSystem = InMemoryTranscriptFileSystem()
    ) -> PagedTranscriptStore {
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


    func testPageDecodesAndMaterializesContiguousRecordOnceAcrossPages() async throws {
        let store = makeStore()
        try await store.append(WireMessageRecord(messageID: "long", text: String(repeating: "x", count: 1_000)))
        let before = await store.metrics()
        let first = try await store.page(TranscriptPageRequest(maximumBytes: 1_000, maximumRows: 2))
        let second = try await store.page(TranscriptPageRequest(
            startOrdinal: first.nextOrdinal,
            maximumBytes: 1_000,
            maximumRows: 2
        ))
        let after = await store.metrics()

        XCTAssertGreaterThan(first.rows.count + second.rows.count, 2)
        XCTAssertEqual(after.diskReads - before.diskReads, 1)
        XCTAssertEqual(after.byteMaterializations - before.byteMaterializations, 1)
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

    func testEqualRevisionSingleReplayDoesNotWriteOrInvalidateCache() async throws {
        let store = makeStore()
        let record = WireMessageRecord(messageID: "replayed", text: "persisted", revision: 1)
        _ = try await store.append(record)
        let request = TranscriptPageRequest(maximumBytes: 200, maximumRows: 1)
        _ = try await store.page(request)
        let route = try await store.currentRoute()
        let beforeReplay = await store.metrics()

        let replay = try await store.append(record)
        let afterReplay = await store.metrics()

        XCTAssertFalse(replay.applied)
        XCTAssertEqual(replay.generation, route.generation)
        XCTAssertEqual(replay.epoch, route.epoch)
        XCTAssertEqual(afterReplay.diskWrites, beforeReplay.diskWrites)

        _ = try await store.page(request)
        let afterCachedPage = await store.metrics()
        XCTAssertEqual(afterCachedPage.pageCacheHits - afterReplay.pageCacheHits, 1)

        let authoritative = record.withText("authoritative")
        let beforeAuthoritative = await store.metrics()
        let authoritativeResult = try await store.append(authoritative)
        let afterAuthoritative = await store.metrics()
        XCTAssertTrue(authoritativeResult.applied)
        XCTAssertEqual(afterAuthoritative.diskWrites - beforeAuthoritative.diskWrites, 3)
        let authoritativePage = try await store.page(request)
        XCTAssertEqual(authoritativePage.rows.first?.text, "authoritative")

        var newer = authoritative
        newer.text = "newer"
        newer.revision = 2
        let newerResult = try await store.append(newer)
        XCTAssertTrue(newerResult.applied)
        let newerPage = try await store.page(request)
        XCTAssertEqual(newerPage.rows.first?.text, "newer")
    }

    func testEqualRevisionBatchReplayDoesNotWriteOrInvalidateCache() async throws {
        let store = makeStore()
        let records = [
            WireMessageRecord(messageID: "one", text: "one", revision: 1),
            WireMessageRecord(messageID: "two", text: "two", revision: 1)
        ]
        _ = try await store.append(records)
        let request = TranscriptPageRequest(maximumBytes: 200, maximumRows: 2)
        _ = try await store.page(request)
        let route = try await store.currentRoute()
        let beforeReplay = await store.metrics()

        let replay = try await store.append(records)
        let afterReplay = await store.metrics()

        XCTAssertTrue(replay.appliedRecords.isEmpty)
        XCTAssertEqual(replay.generation, route.generation)
        XCTAssertEqual(afterReplay.diskReads - beforeReplay.diskReads, records.count)
        XCTAssertEqual(replay.epoch, route.epoch)
        XCTAssertEqual(afterReplay.diskWrites, beforeReplay.diskWrites)

        _ = try await store.page(request)
        let afterCachedPage = await store.metrics()
        XCTAssertEqual(afterCachedPage.pageCacheHits - afterReplay.pageCacheHits, 1)

        var newer = records[0]
        newer.text = "newer"
        newer.revision = 2
        let authoritative = records[1].withText("authoritative")
        let beforeAuthoritative = await store.metrics()
        let applied = try await store.append([newer, authoritative])
        let afterAuthoritative = await store.metrics()

        XCTAssertEqual(applied.appliedRecords, [newer, authoritative])
        XCTAssertEqual(afterAuthoritative.diskWrites - beforeAuthoritative.diskWrites, 4)
        let authoritativePage = try await store.page(request)
        XCTAssertEqual(authoritativePage.rows.map(\.text), ["newer", "authoritative"])
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

    func testFindCollectMarksACappedScanAsTruncated() async throws {
        let store = makeStore()
        for index in 0..<300 {
            try await store.append(WireMessageRecord(messageID: "c\(index)", text: "needle \(index)"))
        }
        let cursor = try await store.find(FindQuery(text: "needle"))
        let collection = try await cursor.collect(limit: 256, pageSize: 64)
        XCTAssertEqual(collection.matches.count, 256)
        XCTAssertTrue(collection.isTruncated)
    }

    func testFindCollectDoesNotMarkAnExactCapAsTruncated() async throws {
        let store = makeStore()
        for index in 0..<256 {
            try await store.append(WireMessageRecord(messageID: "e\(index)", text: "needle \(index)"))
        }
        let cursor = try await store.find(FindQuery(text: "needle"))
        let collection = try await cursor.collect(limit: 256, pageSize: 64)
        XCTAssertEqual(collection.matches.count, 256)
        XCTAssertFalse(collection.isTruncated)
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


    func testBatchRemovalRemovesOnlySelectedRowsInOneMutation() async throws {
        let store = makeStore()
        try await store.append(WireMessageRecord(messageID: "one", text: "one"))
        try await store.append(WireMessageRecord(messageID: "two", text: "two"))
        try await store.append(WireMessageRecord(messageID: "three", text: "three"))
        let route = try await store.currentRoute()

        let result = try await store.apply(
            .removeMany(messageIDs: ["one", "three"]),
            expectedGeneration: route.generation,
            expectedEpoch: route.epoch
        )

        let first = try await store.locate(messageID: "one")
        let second = try await store.locate(messageID: "two")
        let third = try await store.locate(messageID: "three")
        XCTAssertTrue(result.applied)
        XCTAssertEqual(result.epoch, route.epoch + 1)
        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertNil(third)
    }


    func testInterleavedAuthoritativeSourcesMergeIntoAnsweredTurnsWithoutDecodingTheNewSource() async throws {
        let fs = InMemoryTranscriptFileSystem()
        let store = makeStore(fs)
        var answerRecords: [WireMessageRecord] = []
        var auxiliaryRecords: [WireMessageRecord] = []
        answerRecords.reserveCapacity(220)
        auxiliaryRecords.reserveCapacity(1_021)
        let answerOffsets = Set((0..<220).map { $0 * 1_240 / 219 })
        var activeTurnID = ""
        var auxiliaryIndex = 0

        for offset in 0...1_240 {
            let messageID = String(34_983 + offset)
            if answerOffsets.contains(offset) {
                activeTurnID = "turn-\(messageID)"
                answerRecords.append(WireMessageRecord(
                    messageID: messageID,
                    text: "answer-\(messageID)",
                    timestamp: Date(timeIntervalSinceReferenceDate: Double(offset)),
                    turnID: activeTurnID
                ))
            } else {
                if auxiliaryIndex.isMultiple(of: 101) {
                    auxiliaryRecords.append(WireMessageRecord(
                        messageID: messageID,
                        text: "",
                        reasoning: "reasoning-\(messageID)",
                        timestamp: Date(timeIntervalSinceReferenceDate: Double(offset)),
                        turnID: activeTurnID
                    ))
                } else {
                    auxiliaryRecords.append(WireMessageRecord(
                        messageID: messageID,
                        role: "tool",
                        text: "",
                        timestamp: Date(timeIntervalSinceReferenceDate: Double(offset)),
                        displayKind: "tool_event",
                        toolCallID: "call-\(messageID)",
                        toolName: "shell",
                        toolStatus: "completed",
                        turnID: activeTurnID
                    ))
                }
                auxiliaryIndex += 1
            }
        }

        XCTAssertEqual(answerRecords.count, 220)
        XCTAssertEqual(auxiliaryRecords.count, 1_021)
        _ = try await store.append(answerRecords)
        let beforeAuxiliaryMerge = await store.metrics()
        let result = try await store.append(auxiliaryRecords)
        let afterAuxiliaryMerge = await store.metrics()

        let directory = URL(fileURLWithPath: "/transcript")
        let indexURL = directory.appendingPathComponent("index.json")
        let index = try JSONDecoder().decode(TranscriptDiskIndex.self, from: fs.data(at: indexURL))
        let staleOrder = answerRecords.map(\.messageID) + auxiliaryRecords.map(\.messageID)
        try fs.write(
            JSONEncoder().encode(TranscriptDiskIndex(
                entries: index.entries,
                descriptors: index.descriptors,
                modelSwitches: index.modelSwitches,
                orderedMessageIDs: staleOrder,
                turns: index.turns
            )),
            to: indexURL
        )
        let repaired = makeStore(fs)
        try await repaired.load()
        let afterRepair = await repaired.metrics()
        let repairedIndex = try JSONDecoder().decode(TranscriptDiskIndex.self, from: fs.data(at: indexURL))
        let page = try await repaired.turnPage(TranscriptTurnPageRequest(maximumRows: 256))

        XCTAssertEqual(result.appliedRecords.count, 1_021)
        XCTAssertEqual(afterAuxiliaryMerge.diskReads - beforeAuxiliaryMerge.diskReads, 220)
        XCTAssertEqual(afterRepair.diskReads, 1_241)
        XCTAssertEqual(repairedIndex.orderedMessageIDs ?? [], (34_983...36_223).map(String.init))
        XCTAssertEqual(page.totalTurnCount, 220)
        XCTAssertEqual(page.turns.map(\.answer), answerRecords.map(\.text))
        XCTAssertTrue(page.turns.allSatisfy { !$0.answer.isEmpty })
        XCTAssertNotNil(page.turns.first?.reasoning)
        XCTAssertGreaterThan(page.turns.first?.tools.count ?? 0, 0)
        XCTAssertGreaterThan(page.turns.filter { !$0.tools.isEmpty }.count, 1)
    }

    func testCancelledBatchOverwriteRestoresExistingRecordBeforeIndexCommit() async throws {
        let fs = CancellingTranscriptFileSystem()
        let store = makeStore(fs)
        let originalRecords = [
            WireMessageRecord(messageID: "1", text: "old answer"),
            WireMessageRecord(
                messageID: "2",
                text: "",
                displayKind: "model_switch",
                displayMetadata: ["model": .string("old-model")]
            ),
            WireMessageRecord(messageID: "3", text: "old second answer")
        ]
        _ = try await store.append(originalRecords)
        let route = try await store.currentRoute()
        let originalIndexMoves = fs.moveCount(toFileNamed: "index.json")
        let originalManifestMoves = fs.moveCount(toFileNamed: "manifest.json")
        let expectedSwitch = TranscriptModelSwitchMarker(
            id: "2",
            model: "old-model",
            ordinal: 1,
            renderedOrdinal: 1
        )

        let replacement = WireMessageRecord(
            messageID: "1",
            text: "new answer",
            revision: 2
        )
        fs.armCancellation(afterRecordMoves: 1)

        let cancelledAppend: Task<TranscriptBatchMutationResult, Error> = Task {
            try await store.append([replacement])
        }
        do {
            _ = try await cancelledAppend.value
            XCTFail("The overwrite must stop after its durable record move")
        } catch is CancellationError {
        }

        let rowsAfterCancellation = try await store.page(.head(maximumBytes: 200, maximumRows: 3))
        let turnsAfterCancellation = try await store.turnPage(TranscriptTurnPageRequest(maximumRows: 3))
        let switchesAfterCancellation = try await store.modelSwitches()
        let routeAfterCancellation = try await store.currentRoute()
        XCTAssertEqual(rowsAfterCancellation.rows.map(\.text), ["old answer", "old second answer"])
        XCTAssertEqual(turnsAfterCancellation.turns.map(\.answer), ["old answer", "old second answer"])
        XCTAssertEqual(turnsAfterCancellation.turns.map(\.model), [nil, "old-model"])
        XCTAssertEqual(switchesAfterCancellation, [expectedSwitch])
        XCTAssertEqual(routeAfterCancellation, route)
        XCTAssertEqual(fs.moveCount(toFileNamed: "index.json"), originalIndexMoves)
        XCTAssertEqual(fs.moveCount(toFileNamed: "manifest.json"), originalManifestMoves)

        let reopened = PagedTranscriptStore(
            route: route,
            directory: URL(fileURLWithPath: "/transcript"),
            fileSystem: fs
        )
        try await reopened.load()
        let reopenedRows = try await reopened.page(.head(maximumBytes: 200, maximumRows: 3))
        let reopenedTurns = try await reopened.turnPage(TranscriptTurnPageRequest(maximumRows: 3))
        let reopenedSwitches = try await reopened.modelSwitches()
        XCTAssertEqual(reopenedRows.rows.map(\.text), ["old answer", "old second answer"])
        XCTAssertEqual(reopenedTurns.turns.map(\.answer), ["old answer", "old second answer"])
        XCTAssertEqual(reopenedTurns.turns.map(\.model), [nil, "old-model"])
        XCTAssertEqual(reopenedSwitches, [expectedSwitch])

        let retry = try await store.append([replacement])
        let replay = try await store.append([replacement])
        let rowsAfterRetry = try await store.page(.head(maximumBytes: 200, maximumRows: 3))
        XCTAssertEqual(retry.appliedRecords, [replacement])
        XCTAssertTrue(replay.appliedRecords.isEmpty)
        XCTAssertEqual(rowsAfterRetry.rows.map(\.text), ["new answer", "old second answer"])
        XCTAssertEqual(fs.moveCount(toFileNamed: "index.json"), originalIndexMoves + 1)
        XCTAssertEqual(fs.moveCount(toFileNamed: "manifest.json"), originalManifestMoves + 1)
    }

    func testFailedManifestMoveRestoresRecordsAndMetadataBeforeRetry() async throws {
        let fs = CancellingTranscriptFileSystem()
        let store = makeStore(fs)
        let originalRecords = [
            WireMessageRecord(messageID: "1", text: "old answer"),
            WireMessageRecord(
                messageID: "2",
                text: "",
                displayKind: "model_switch",
                displayMetadata: ["model": .string("old-model")]
            ),
            WireMessageRecord(messageID: "3", text: "old second answer")
        ]
        _ = try await store.append(originalRecords)
        let directory = URL(fileURLWithPath: "/transcript")
        let indexURL = directory.appendingPathComponent("index.json")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let originalIndex = try fs.data(at: indexURL)
        let originalManifest = try fs.data(at: manifestURL)
        let expectedSwitch = TranscriptModelSwitchMarker(
            id: "2",
            model: "old-model",
            ordinal: 1,
            renderedOrdinal: 1
        )
        let replacement = WireMessageRecord(
            messageID: "1",
            text: "new answer",
            revision: 2
        )
        fs.failNextManifestMove()

        do {
            _ = try await store.append([replacement])
            XCTFail("The batch must fail after the index move")
        } catch is TranscriptFileSystemInjectionError {
        } catch {
            XCTFail("Unexpected manifest-move failure: \(error)")
        }

        XCTAssertEqual(try fs.data(at: indexURL), originalIndex)
        XCTAssertEqual(try fs.data(at: manifestURL), originalManifest)

        let reopened = makeStore(fs)
        try await reopened.load()
        let rows = try await reopened.page(.head(maximumBytes: 200, maximumRows: 3))
        let turns = try await reopened.turnPage(TranscriptTurnPageRequest(maximumRows: 3))
        let switches = try await reopened.modelSwitches()
        XCTAssertEqual(rows.rows.map(\.text), ["old answer", "old second answer"])
        XCTAssertEqual(turns.turns.map(\.answer), ["old answer", "old second answer"])
        XCTAssertEqual(turns.turns.map(\.model), [nil, "old-model"])
        XCTAssertEqual(switches, [expectedSwitch])

        let retry = try await store.append([replacement])
        let replay = try await store.append([replacement])
        let rowsAfterRetry = try await store.page(.head(maximumBytes: 200, maximumRows: 3))
        XCTAssertEqual(retry.appliedRecords, [replacement])
        XCTAssertTrue(replay.appliedRecords.isEmpty)
        XCTAssertEqual(rowsAfterRetry.rows.map(\.text), ["new answer", "old second answer"])
    }

    func testCancelledBatchRetryCommitsOneCoherentIndex() async throws {
        let fs = CancellingTranscriptFileSystem(cancelAfterRecordMoves: 1)
        let store = makeStore(fs)
        let records = [
            WireMessageRecord(
                messageID: "2",
                text: "",
                displayKind: "model_switch",
                displayMetadata: ["model": .string("retry-model")]
            ),
            WireMessageRecord(messageID: "1", text: "first"),
            WireMessageRecord(messageID: "3", text: "second")
        ]

        let cancelledAppend = Task { try await store.append(records) }
        do {
            _ = try await cancelledAppend.value
            XCTFail("The batch must stop after its durable partial write")
        } catch is CancellationError {
        }

        let afterCancellation = await store.metrics()
        let cancelledSummary = try await store.summary()
        let cancelledRoute = try await store.currentRoute()
        let cancelledSwitches = try await store.modelSwitches()
        XCTAssertEqual(afterCancellation.diskWrites, 1)
        XCTAssertEqual(cancelledSummary.rowCount, 0)
        XCTAssertEqual(cancelledSummary.messageCount, 0)
        XCTAssertEqual(cancelledRoute.epoch, 0)
        XCTAssertTrue(cancelledSwitches.isEmpty)
        XCTAssertEqual(fs.moveCount(toFileNamed: "index.json"), 0)
        XCTAssertEqual(fs.moveCount(toFileNamed: "manifest.json"), 0)

        let retry = try await store.append(records)
        let afterRetry = await store.metrics()
        let rows = try await store.page(.head(maximumBytes: 200, maximumRows: 3))
        let switches = try await store.modelSwitches()
        let turns = try await store.turnPage(TranscriptTurnPageRequest(maximumRows: 3))
        let index = try JSONDecoder().decode(
            TranscriptDiskIndex.self,
            from: fs.data(at: URL(fileURLWithPath: "/transcript/index.json"))
        )

        let expectedSwitch = TranscriptModelSwitchMarker(
            id: "2",
            model: "retry-model",
            ordinal: 1,
            renderedOrdinal: 1
        )
        XCTAssertEqual(retry.appliedRecords, records)
        XCTAssertEqual(afterRetry.diskWrites - afterCancellation.diskWrites, records.count + 2)
        XCTAssertEqual(rows.rows.map(\.message.messageID), ["1", "3"])
        XCTAssertEqual(rows.rows.map(\.text), ["first", "second"])
        XCTAssertEqual(switches, [expectedSwitch])
        XCTAssertEqual(turns.modelSwitches, [expectedSwitch])
        XCTAssertEqual(turns.turns.map(\.answer), ["first", "second"])
        XCTAssertEqual(turns.turns.map(\.model), [nil, "retry-model"])
        XCTAssertEqual(index.orderedMessageIDs ?? [], ["1", "2", "3"])
        XCTAssertEqual(index.descriptors.map(\.messageID), ["1", "3"])
        XCTAssertEqual(index.modelSwitches ?? [], [expectedSwitch])
        XCTAssertEqual(fs.moveCount(toFileNamed: "index.json"), 1)
        XCTAssertEqual(fs.moveCount(toFileNamed: "manifest.json"), 1)
    }

    func testVersionOneIndexRebuildsMissingModelMetadataInOnePass() async throws {
        let fs = InMemoryTranscriptFileSystem()
        let records = [
            WireMessageRecord(messageID: "1", text: "first"),
            WireMessageRecord(
                messageID: "2",
                text: "",
                displayKind: "model_switch",
                displayMetadata: ["model": .string("migrated-model")]
            ),
            WireMessageRecord(messageID: "3", text: "second")
        ]
        let seeded = makeStore(fs)
        _ = try await seeded.append(records)

        let directory = URL(fileURLWithPath: "/transcript")
        let indexURL = directory.appendingPathComponent("index.json")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let index = try JSONDecoder().decode(TranscriptDiskIndex.self, from: fs.data(at: indexURL))
        try fs.write(
            JSONEncoder().encode(TranscriptDiskIndex(
                entries: index.entries,
                descriptors: index.descriptors,
                modelSwitches: nil,
                orderedMessageIDs: index.orderedMessageIDs,
                turns: []
            )),
            to: indexURL
        )
        try fs.write(
            JSONEncoder().encode(TranscriptManifest(version: 1)),
            to: manifestURL
        )

        let migrated = makeStore(fs)
        try await migrated.load()
        let afterLoad = await migrated.metrics()
        let migratedSwitches = try await migrated.modelSwitches()
        let recoveredIndex = try JSONDecoder().decode(
            TranscriptDiskIndex.self,
            from: fs.data(at: indexURL)
        )
        let page = try await migrated.turnPage(TranscriptTurnPageRequest(maximumRows: 3))
        let expectedSwitch = TranscriptModelSwitchMarker(
            id: "2",
            model: "migrated-model",
            ordinal: 1,
            renderedOrdinal: 1
        )

        XCTAssertEqual(afterLoad.diskReads, records.count)
        XCTAssertEqual(recoveredIndex.modelSwitches ?? [], [expectedSwitch])
        XCTAssertEqual(recoveredIndex.turns?.count, 2)
        XCTAssertEqual(migratedSwitches, [expectedSwitch])
        XCTAssertEqual(page.turns.map(\.answer), ["first", "second"])
        XCTAssertEqual(page.turns.map(\.model), [nil, "migrated-model"])
        XCTAssertEqual(
            try JSONDecoder().decode(TranscriptManifest.self, from: fs.data(at: manifestURL)).version,
            TranscriptManifest.currentVersion
        )
    }

    func testResidentTurnPageReturnsDiskTurnsWithoutAnActorHop() async throws {
        let store = makeStore()
        try await store.append(WireMessageRecord(messageID: "one", text: "one"))
        try await store.append(WireMessageRecord(messageID: "two", text: "two"))
        let route = try await store.currentRoute()
        let page = store.residentTurnPage(
            TranscriptTurnPageRequest(
                startOrdinal: 0,
                maximumRows: 8,
                maximumBytes: 64 * 1024,
                expectedGeneration: route.generation,
                expectedEpoch: route.epoch
            )
        )
        XCTAssertEqual(page?.turns.map(\.answer), ["one", "two"])
        XCTAssertEqual(page?.totalTurnCount, 2)
    }

    func testResidentTurnPageReturnsNilWhenARecordFileIsMissing() async throws {
        let fs = InMemoryTranscriptFileSystem()
        let store = makeStore(fs)
        try await store.append(WireMessageRecord(messageID: "one", text: "one"))
        let url = TranscriptResidentPageSource.recordURL(
            directory: URL(fileURLWithPath: "/transcript"),
            messageID: "one"
        )
        try fs.remove(url)
        let route = try await store.currentRoute()
        let page = store.residentTurnPage(
            TranscriptTurnPageRequest(
                expectedGeneration: route.generation,
                expectedEpoch: route.epoch
            )
        )
        XCTAssertNil(page)
    }

    func testDurableMergePreservesEqualAndNonnumericSourceOrder() {
        XCTAssertEqual(
            TranscriptWireOrder.merged(
                existing: ["01", "2"],
                incoming: ["1", "02", "3"]
            ) ?? [],
            ["01", "1", "2", "02", "3"]
        )
        XCTAssertNil(
            TranscriptWireOrder.merged(
                existing: ["provisional-a", "provisional-b"],
                incoming: ["1", "2"]
            )
        )
    }
}

private enum TranscriptFileSystemInjectionError: Error {
    case manifestMove
}

private final class CancellingTranscriptFileSystem: TranscriptFileSystem, @unchecked Sendable {
    private let storage = InMemoryTranscriptFileSystem()
    private let lock = NSLock()
    private var movesByFileName: [String: Int] = [:]
    private var remainingRecordMovesBeforeCancellation: Int?
    private var failsNextManifestMove = false

    func failNextManifestMove() {
        lock.lock()
        failsNextManifestMove = true
        lock.unlock()
    }


    init(cancelAfterRecordMoves: Int? = nil) {
        self.remainingRecordMovesBeforeCancellation = cancelAfterRecordMoves
    }

    func armCancellation(afterRecordMoves: Int) {
        lock.lock()
        remainingRecordMovesBeforeCancellation = afterRecordMoves
        lock.unlock()
    }

    func data(at url: URL) throws -> Data {
        try storage.data(at: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try storage.write(data, to: url)
    }

    func remove(_ url: URL) throws {
        try storage.remove(url)
    }

    func move(_ source: URL, to destination: URL) throws {
        var cancelsCurrentTask = false
        var failsMove = false
        lock.lock()
        if destination.lastPathComponent == "manifest.json",
           failsNextManifestMove {
            failsNextManifestMove = false
            failsMove = true
        }
        lock.unlock()
        if failsMove { throw TranscriptFileSystemInjectionError.manifestMove }

        try storage.move(source, to: destination)
        lock.lock()
        movesByFileName[destination.lastPathComponent, default: 0] += 1
        if destination.lastPathComponent.hasPrefix("record-"),
           let remaining = remainingRecordMovesBeforeCancellation {
            if remaining == 1 {
                remainingRecordMovesBeforeCancellation = nil
                cancelsCurrentTask = true
            } else {
                remainingRecordMovesBeforeCancellation = remaining - 1
            }
        }
        lock.unlock()
        if cancelsCurrentTask {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func exists(_ url: URL) -> Bool {
        storage.exists(url)
    }

    func createDirectory(_ url: URL) throws {
        try storage.createDirectory(url)
    }

    func moveCount(toFileNamed fileName: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return movesByFileName[fileName, default: 0]
    }
}
