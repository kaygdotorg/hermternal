import Foundation
@testable import HermternalCore
import Testing
@Test("query compiler quotes every token and joins AND")
func searchCompilerIsLiteral() {
    #expect(SearchIndex.compile(query: "alpha OR beta") == "\"alpha\"* AND \"OR\"* AND \"beta\"*")
    #expect(SearchIndex.compile(query: "  ") == "")
    #expect(SearchIndex.compile(query: "a\"b") == "\"a\"\"b\"*")
}

@Test("FTS prefix, AND, case, and diacritics")
func ftsMatchingSemantics() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "", documents: [
        document(1, "The café has a cacao aroma."),
        document(2, "An unrelated apple sentence."),
        document(3, "cafe racer notes")
    ]))
    #expect((try await index.search("caf", limit: 10)).hits.map(\.messageID.rawValue).sorted() == [1, 3])
    #expect((try await index.search("café aroma", limit: 10)).hits.map(\.messageID.rawValue) == [1])
    #expect(try await index.search("aro", limit: 10).hits.count == 1)
    #expect(try await index.search("afé", limit: 10).hits.isEmpty)
}

@Test("title receives a stronger BM25 weight")
func titleOutranksRepeatedBody() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "", documents: [
        document(1, "needle needle needle needle needle"),
        document(2, "needle")
    ]))
    // Each document's title is indexed from the session snapshot. Replace the
    // second session to make the title-vs-body distinction explicit.
    try await index.replace(SearchSessionSnapshot(sessionID: "title", title: "needle", documents: [document(3, "ordinary body")]))
    let hits = try await index.search("needle", limit: 10).hits
    #expect(hits.first?.messageID.rawValue == 3)
}

@Test("snippets retain UI highlighting delimiters")
func snippetsHaveDelimiters() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "", documents: [document(1, "a distinctive zebra phrase")]))
    let hit = try #require(try await index.search("zebra", limit: 10).hits.first)
    #expect(hit.excerpt.contains("⟦"))
    #expect(hit.excerpt.contains("⟧"))
}

@Test("replace is digest-aware and title-only changes invalidate rows")
func replaceAndTitleChange() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let docs = [document(1, "body")]
    let first = SearchSessionSnapshot(sessionID: "s", title: "old title", documents: docs)
    try await index.replace(first)
    let digest = try await index.storedDigest(for: "s")
    try await index.replace(first)
    #expect(try await index.storedDigest(for: "s") == digest)
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "new title", documents: docs))
    #expect(try await index.search("new", limit: 10).hits.first?.sessionTitle == "new title")
    #expect(try await index.search("old", limit: 10).hits.isEmpty)
}

@Test("remove, clear, disable, and recreate")
func lifecycleOperations() async throws {
    let index = try makeIndex()
    let url = index.url
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "title", documents: [document(1, "body")], truncated: true))
    #expect(try await index.pendingIndexingSessionCount() == 0)
    #expect(try await index.truncatedSessionCount() == 1)
    try await index.remove(sessionID: "s")
    #expect(try await index.pendingIndexingSessionCount() == 0)
    #expect(try await index.truncatedSessionCount() == 0)
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "title", documents: [document(1, "body")]))
    try await index.clear()
    #expect(try await index.indexedMessageCount() == 0)
    try await index.disable()
    #expect(await index.isDisabled())
    let recreated = try SearchIndex(url: url)
    #expect(try await recreated.indexedMessageCount() == 0)
    try await recreated.disable()
    removeIndex(url)
}

@Test("schema mismatch deterministically rebuilds")
func schemaVersionRebuild() async throws {
    let url: URL
    do {
        let index = try makeIndex()
        url = index.url
        try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "title", documents: [document(1, "body")]))
        try await index._setSchemaVersionForTesting(999)
    }
    // Deinitialization closes the connection but deliberately does not delete
    // the database, so reopening observes and rebuilds the wrong metadata.
    let recreated = try SearchIndex(url: url)
    #expect(try await recreated.indexedMessageCount() == 0)
    try await recreated.disable()
    removeIndex(url)
}

@Test("truncated sessions are reported independently of row limit")
func truncationMetadata() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.replace(SearchSessionSnapshot(sessionID: "short", title: "", documents: [document(1, "needle")], truncated: true))
    try await index.replace(SearchSessionSnapshot(sessionID: "complete", title: "", documents: [document(2, "needle")]))
    let results = try await index.search("needle", limit: 1)
    #expect(results.hits.count == 1)
    #expect(results.pendingIndexingSessions == 0)
    #expect(results.truncatedSessions == 1)
}

@Test("unwarmed sessions are reported as pending indexing")
func unwarmedSessionsArePendingIndexing() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.replace(SearchSessionSnapshot(
        sessionID: "warmed",
        title: "",
        documents: [document(1, "needle")]
    ))
    try await index.markUnwarmed(sessionIDs: ["cold"])

    let results = try await index.search("needle", limit: 10)
    #expect(results.pendingIndexingSessions == 1)
    #expect(results.truncatedSessions == 0)
}

@Test("rapid queries are latest-wins and recover after cancellation")
func latestWinsQueries() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let documents = (0..<500).map { document(Int64($0), String(repeating: "common ", count: 8) + " rare\($0)") }
    try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "", documents: documents))

    let gate = QueryStartGate()
    await index._setQueryStartHook { gate.queryStarted() }
    let old = Task { try? await index.search("common", limit: 100) }
    await gate.waitUntilStarted()
    await index._setQueryStartHook(nil)

    let newestTask = Task { try? await index.search("rare499", limit: 10) }
    gate.release()
    let newest = try #require(await newestTask.value)
    #expect(newest.hits.first?.messageID.rawValue == 499)
    _ = await old.value
    let recovered = try await index.search("rare1", limit: 10)
    #expect(recovered.hits.first?.messageID.rawValue == 1)
}

@Test("rapid search, replace, disable, and recreate keeps lifecycle serialized")
func lifecycleRaceStress() async throws {
    for iteration in 0..<20 {
        let index = try makeIndex()
        let url = index.url
        try await index.replace(SearchSessionSnapshot(sessionID: "s", title: "old", documents: [document(1, "common old")]))
        let gate = QueryStartGate()
        await index._setQueryStartHook { gate.queryStarted() }
        let query = Task { try? await index.search("common", limit: 10) }
        await gate.waitUntilStarted()
        await index._setQueryStartHook(nil)
        let replacement = Task {
            try? await index.replace(SearchSessionSnapshot(sessionID: "s", title: "replacement", documents: [document(3, "replacement")]))
        }
        let disable = Task { try? await index.disable() }
        gate.release()
        _ = await query.value
        _ = await replacement.value
        _ = await disable.value

        let recreated = try SearchIndex(url: url)
        try await recreated.replace(SearchSessionSnapshot(sessionID: "s", title: "new-\(iteration)", documents: [document(2, "fresh")]))
        let result = try await recreated.search("fresh", limit: 10)
        #expect(result.hits.first?.messageID.rawValue == 2)
        try await recreated.disable()
        removeIndex(url)
    }
}

@Test("warm benchmark reports timing without a brittle assertion")
func warmBenchmarkReport() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let documents = (0..<900).map { document(Int64($0), "benchmark common text row \($0)") }
    try await index.replace(SearchSessionSnapshot(sessionID: "bench", title: "", documents: documents))
    _ = try await index.search("common", limit: 100)
    let start = ContinuousClock.now
    _ = try await index.search("common", limit: 100)
    let elapsed = start.duration(to: .now)
    print("SearchIndex warm benchmark: \(elapsed)")
}

@Test("paged replacement skips a second pass for an unchanged digest")
func pagedReplacementIngestsPages() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let invocations = PageFactoryInvocations()
    let pages: @Sendable () -> AsyncThrowingStream<SearchDocumentPage, Error> = {
        invocations.record()
        return AsyncThrowingStream { continuation in
            continuation.yield(SearchDocumentPage(documents: [document(1, "first needle")]))
            continuation.yield(SearchDocumentPage(documents: [document(2, "second needle")]))
            continuation.finish()
        }
    }
    try await index.replacePaged(sessionID: "paged", title: "Paged", truncated: false, pages: pages)
    #expect(try await index.indexedMessageCount(sessionID: "paged") == 2)
    #expect(try await index.search("needle", limit: 10).hits.count == 2)
    let firstDigest = try await index.storedDigest(for: "paged")
    let firstPasses = invocations.value
    try await index._resetPersistentMutationCount()

    try await index.replacePaged(
        sessionID: "paged",
        title: "Paged",
        truncated: false,
        pages: pages
    )

    #expect(try await index.storedDigest(for: "paged") == firstDigest)
    #expect(invocations.value == firstPasses + 1)
    #expect(try await index._persistentMutationCount() == 0)
}


@Test("changed replay rolls back without publishing mixed index state")
func changedReplayDoesNotPublishMixedIndexState() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.replace(SearchSessionSnapshot(
        sessionID: "replay",
        title: "Replay",
        documents: [document(1, "stable")]
    ))
    let originalDigest = try await index.storedDigest(for: "replay")
    let invocations = PageFactoryInvocations()
    let pages: @Sendable () -> AsyncThrowingStream<SearchDocumentPage, Error> = {
        let pass = invocations.record()
        return AsyncThrowingStream { continuation in
            continuation.yield(SearchDocumentPage(documents: [
                document(1, pass == 1 ? "first pass" : "second pass")
            ]))
            continuation.finish()
        }
    }

    do {
        try await index.replacePaged(
            sessionID: "replay",
            title: "Replay",
            truncated: false,
            pages: pages
        )
        Issue.record("Changed replay unexpectedly committed")
    } catch let error as SearchIndexError {
        guard case .replayChanged = error else {
            Issue.record("Changed replay threw the wrong index error: \(error)")
            return
        }
    } catch {
        Issue.record("Changed replay threw the wrong error: \(error)")
    }

    #expect(try await index.storedDigest(for: "replay") == originalDigest)
    #expect(try await index.search("stable", limit: 10).hits.first?.messageID.rawValue == 1)
    #expect(try await index.search("second", limit: 10).hits.isEmpty)
}
@Test("append refreshes status and replaces changed message identity")
func appendRefreshesStatusAndRemovesStaleRows() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.append(
        SearchDocumentPage(documents: [SearchDocument(
            messageID: ServerMessageID(rawValue: 1),
            body: "stale phrase",
            role: .user,
            timestamp: Date(timeIntervalSince1970: 1)
        )]),
        sessionID: "append",
        title: "Append"
    )
    try await index.append(
        SearchDocumentPage(documents: [SearchDocument(
            messageID: ServerMessageID(rawValue: 1),
            body: "fresh phrase",
            role: .user,
            timestamp: Date(timeIntervalSince1970: 2)
        )]),
        sessionID: "append",
        title: "Append",
        truncated: true
    )

    #expect(try await index.search("stale", limit: 10).hits.isEmpty)
    #expect(try await index.search("fresh", limit: 10).hits.first?.messageID.rawValue == 1)
    #expect(try await index.truncatedSessionCount() == 1)
}


@Test("append and replacement deduplicate repeated message IDs")
func duplicateMessageIDsDoNotLeaveOrphanedRows() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let duplicates = [document(7, "alpha stale"), document(7, "zeta winner")]

    try await index.replace(SearchSessionSnapshot(sessionID: "duplicates", title: "Duplicates", documents: duplicates))
    #expect(try await index.search("alpha", limit: 10).hits.isEmpty)
    #expect(try await index.search("zeta", limit: 10).hits.first?.messageID.rawValue == 7)
    #expect(try await index.indexedMessageCount(sessionID: "duplicates") == 1)

    try await index.append(
        SearchDocumentPage(documents: [document(7, "alpha later"), document(7, "zulu appended")]),
        sessionID: "duplicates",
        title: "Duplicates"
    )
    #expect(try await index.search("zeta", limit: 10).hits.isEmpty)
    #expect(try await index.search("alpha", limit: 10).hits.isEmpty)
    #expect(try await index.search("zulu", limit: 10).hits.first?.messageID.rawValue == 7)
    #expect(try await index.indexedMessageCount(sessionID: "duplicates") == 1)

    try await index.replace(SearchSessionSnapshot(
        sessionID: "duplicates",
        title: "Duplicates",
        documents: [document(8, "authoritative")]
    ))
    #expect(try await index.search("zulu", limit: 10).hits.isEmpty)
    #expect(try await index.search("authoritative", limit: 10).hits.first?.messageID.rawValue == 8)
    try await index.clear()
    #expect(try await index.indexedMessageCount() == 0)
}

@Test("large duplicate replay uses one keyed identity lookup per message")
func largeDuplicateReplayUsesKeyedIdentityLookup() async throws {

    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let documents = (0..<512).flatMap { id in
        [document(Int64(id), "older \(id)"), document(Int64(id), "winner \(id)")]
    }
    try await index.append(
        SearchDocumentPage(documents: documents),
        sessionID: "large",
        title: "Large"
    )
    try await index._resetIdentityLookupCount()
    try await index._resetPersistentMutationCount()
    try await index.append(
        SearchDocumentPage(documents: documents),
        sessionID: "large",
        title: "Large"
    )

    #expect(try await index._identityLookupCount() == 512)
    #expect(try await index._persistentMutationCount() == 0)
}
@Test("paged replacement chooses a boundary-independent duplicate winner")
func pagedReplacementCanonicalizesDuplicateIDsAcrossPages() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let lower = document(7, "alpha stale")
    let winner = document(7, "zeta winner")
    let onePage: @Sendable () -> AsyncThrowingStream<SearchDocumentPage, Error> = {
        AsyncThrowingStream { continuation in
            continuation.yield(SearchDocumentPage(documents: [lower, winner]))
            continuation.finish()
        }
    }
    let reversedPages: @Sendable () -> AsyncThrowingStream<SearchDocumentPage, Error> = {
        AsyncThrowingStream { continuation in
            continuation.yield(SearchDocumentPage(documents: [winner]))
            continuation.yield(SearchDocumentPage(documents: [lower]))
            continuation.finish()
        }
    }

    try await index.replacePaged(sessionID: "canonical", title: "Canonical", truncated: false, pages: onePage)
    let digest = try await index.storedDigest(for: "canonical")
    try await index._resetPersistentMutationCount()
    try await index.replacePaged(sessionID: "canonical", title: "Canonical", truncated: false, pages: reversedPages)

    #expect(try await index.storedDigest(for: "canonical") == digest)
    #expect(try await index.search("alpha", limit: 10).hits.isEmpty)
    #expect(try await index.search("zeta", limit: 10).hits.first?.messageID.rawValue == 7)
    #expect(try await index._persistentMutationCount() == 0)
}
@Test("cancelled mutation waiters do not reach SQLite")
func cancelledMutationWaitersDoNotReachSQLite() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }

    let invocations = PageFactoryInvocations()
    let replacementGate = ReplacementPassGate()
    let pages: @Sendable () -> AsyncThrowingStream<SearchDocumentPage, Error> = {
        let invocation = invocations.record()
        return AsyncThrowingStream { continuation in
            let producer = Task {
                if invocation == 2 {
                    await replacementGate.secondPassStarted()
                    await replacementGate.waitForRelease()
                }
                continuation.yield(SearchDocumentPage(documents: [document(0, "replacement holder")]))
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    try await index._resetPersistentMutationCount()

    let replacement = Task {
        try await index.replacePaged(
            sessionID: "holder",
            title: "Holder",
            truncated: false,
            pages: pages
        )
    }
    await replacementGate.waitUntilSecondPass()

    let cancelledCount = 112
    let liveCount = 16
    let liveMutations: [Task<Void, Error>] = (0..<liveCount).map { id in
        Task {
            try await index.append(
                SearchDocumentPage(documents: [document(Int64(id + 1), "live mutation \(id)")]),
                sessionID: "live-\(id)",
                title: "Live"
            )
        }
    }
    await index._waitForMutationGateWaiters(atLeast: liveCount)

    let cancelledMutations: [Task<Void, Error>] = (0..<cancelledCount).map { id in
        Task {
            try await index.append(
                SearchDocumentPage(documents: [document(Int64(liveCount + id + 1), "cancelled mutation \(id)")]),
                sessionID: "cancelled-\(id)",
                title: "Cancelled"
            )
        }
    }
    await index._waitForMutationGateWaiters(atLeast: 64)
    for mutation in cancelledMutations {
        mutation.cancel()
    }

    await replacementGate.release()
    try await replacement.value

    var observedCancellationCount = 0
    for mutation in cancelledMutations {
        do {
            try await mutation.value
        } catch is CancellationError {
            observedCancellationCount += 1
        }
    }
    for mutation in liveMutations {
        try await mutation.value
    }

    #expect(observedCancellationCount == cancelledCount)
    #expect(await index._mutationGateWaiterCount() == 0)
    #expect(try await index._persistentMutationCount() == 5 + 3 * liveCount)
    #expect(try await index.indexedMessageCount() == liveCount + 1)
}

@Test("held replacement serializes reentrant search database callers")
func heldReplacementDoesNotBlockReentrantDatabaseAccess() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let invocations = PageFactoryInvocations()
    let replacementGate = ReplacementPassGate()
    defer {
        Task { await replacementGate.release() }
    }
    let pages: @Sendable () -> AsyncThrowingStream<SearchDocumentPage, Error> = {
        let invocation = invocations.record()
        return AsyncThrowingStream { continuation in
            let producer = Task {
                if invocation == 2 {
                    await replacementGate.secondPassStarted()
                    await replacementGate.waitForRelease()
                }
                continuation.yield(SearchDocumentPage(documents: [document(1, "held replacement")]))
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    let replacement = Task {
        try await index.replacePaged(
            sessionID: "held",
            title: "Held",
            truncated: false,
            pages: pages
        )
    }
    try await completesWithin {
        await replacementGate.waitUntilSecondPass()
    }

    let indexedIDs = Task { try await index.indexedSessionIDs() }
    try await completesWithin {
        await index._waitForMutationGateWaiters(atLeast: 1)
    }
    let markUnwarmed = Task { try await index.markUnwarmed(sessionIDs: ["cold"]) }
    try await completesWithin {
        await index._waitForMutationGateWaiters(atLeast: 2)
    }
    let search = Task { try await index.search("replacement", limit: 10) }
    try await completesWithin {
        await index._waitForMutationGateWaiters(atLeast: 3)
    }

    await replacementGate.release()
    try await completesWithin {
        try await replacement.value
    }
    let ids = try await completesWithin {
        try await indexedIDs.value
    }
    try await completesWithin {
        try await markUnwarmed.value
    }
    let results = try await completesWithin {
        try await search.value
    }

    #expect(ids == ["held"])
    #expect(results.hits.first?.messageID.rawValue == 1)
    #expect(try await index.pendingIndexingSessionCount() == 1)
}

@Test("search publishes its lease before releasing the mutation gate")
func searchLeaseCannotBlockAGrantedMutation() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.replace(SearchSessionSnapshot(
        sessionID: "race",
        title: "Race",
        documents: [document(1, "old result")]
    ))

    let gate = QueryGateReleaseGate()
    await index._setQueryGateReleaseHook {
        await gate.queryGateReleased()
        await gate.waitForRelease()
    }
    defer {
        Task {
            await gate.finish()
            await index._setQueryGateReleaseHook(nil)
        }
    }

    let search = Task { try await index.search("old", limit: 10) }
    try await completesWithin {
        await gate.waitUntilQueryGateReleased()
    }

    let replacement = Task {
        try await index.replace(SearchSessionSnapshot(
            sessionID: "race",
            title: "Race",
            documents: [document(2, "replacement result")]
        ))
    }
    try await completesWithin {
        try await replacement.value
    }

    await gate.release()
    await index._setQueryGateReleaseHook(nil)
    do {
        _ = try await completesWithin {
            try await search.value
        }
        Issue.record("Search completed after its generation was replaced")
    } catch is CancellationError {
    }
    #expect(try await index.search("replacement", limit: 10).hits.first?.messageID.rawValue == 2)
}

@Test("cancellation after a gate grant starts no query or mutation")
func cancellationAfterMutationGateGrantDoesNotReachSQLite() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let invocations = PageFactoryInvocations()
    let replacementGate = ReplacementPassGate()
    let pages: @Sendable () -> AsyncThrowingStream<SearchDocumentPage, Error> = {
        let invocation = invocations.record()
        return AsyncThrowingStream { continuation in
            let producer = Task {
                if invocation == 2 {
                    await replacementGate.secondPassStarted()
                    await replacementGate.waitForRelease()
                }
                continuation.yield(SearchDocumentPage(documents: [document(1, "holder")]))
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    let queryStarts = QueryStartCounter()
    await index._setQueryStartHook { queryStarts.record() }
    try await index._resetPersistentMutationCount()
    let replacement = Task {
        try await index.replacePaged(
            sessionID: "holder",
            title: "Holder",
            truncated: false,
            pages: pages
        )
    }
    await replacementGate.waitUntilSecondPass()

    let grantGate = MutationGateGrantHook()
    await index._setMutationGateGrantHook {
        await grantGate.granted()
        await grantGate.waitForRelease()
    }
    let append = Task {
        try await index.append(
            SearchDocumentPage(documents: [document(2, "cancelled append")]),
            sessionID: "append",
            title: "Append"
        )
    }
    await index._waitForMutationGateWaiters(atLeast: 1)
    let search = Task { try await index.search("holder", limit: 10) }
    await index._waitForMutationGateWaiters(atLeast: 2)

    await replacementGate.release()
    await grantGate.waitUntilGranted(1)
    append.cancel()
    await grantGate.release()
    await grantGate.waitUntilGranted(2)
    search.cancel()
    await grantGate.release()
    await index._setMutationGateGrantHook(nil)
    try await replacement.value

    do {
        try await append.value
        Issue.record("Cancelled append reached the index")
    } catch is CancellationError {
    } catch {
        Issue.record("Cancelled append failed with \(error)")
    }
    do {
        _ = try await search.value
        Issue.record("Cancelled search reached SQLite")
    } catch is CancellationError {
    } catch {
        Issue.record("Cancelled search failed with \(error)")
    }

    #expect(queryStarts.value == 0)
    #expect(try await index._persistentMutationCount() == 5)
    #expect(try await index.indexedMessageCount() == 1)
}

@Test("accepted append follows an in-flight terminal replacement")
func appendFollowsTerminalReplacement() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    try await index.replace(SearchSessionSnapshot(
        sessionID: "race",
        title: "Race",
        documents: [document(1, "old")]
    ))

    let invocations = PageFactoryInvocations()
    let gate = ReplacementPassGate()
    let pages: @Sendable () -> AsyncThrowingStream<SearchDocumentPage, Error> = {
        let invocation = invocations.record()
        return AsyncThrowingStream { continuation in
            let producer = Task {
                if invocation == 2 {
                    await gate.secondPassStarted()
                    await gate.waitForRelease()
                }
                continuation.yield(SearchDocumentPage(documents: [document(1, "replacement")]))
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    let replacement = Task {
        try await index.replacePaged(
            sessionID: "race",
            title: "Race",
            truncated: false,
            pages: pages
        )
    }
    await gate.waitUntilSecondPass()
    let append = Task {
        try await index.append(
            SearchDocumentPage(documents: [document(2, "accepted append")]),
            sessionID: "race",
            title: "Race"
        )
    }
    await gate.release()
    try await replacement.value
    try await append.value

    #expect(try await index.search("replacement", limit: 10).hits.first?.messageID.rawValue == 1)
    #expect(try await index.search("accepted", limit: 10).hits.first?.messageID.rawValue == 2)
}

@Test("title-only append preserves the terminal replacement digest")
func titleOnlyAppendDoesNotForceTerminalRewrite() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let documents = [document(3, "stable body")]
    try await index.replace(SearchSessionSnapshot(sessionID: "title", title: "Old", documents: documents))
    try await index.append(SearchDocumentPage(documents: documents), sessionID: "title", title: "New")
    try await index._resetPersistentMutationCount()
    try await index.replace(SearchSessionSnapshot(sessionID: "title", title: "New", documents: documents))

    #expect(try await index._persistentMutationCount() == 0)
}

@Test("title-only append preserves a duplicate-aware terminal digest")
func titleOnlyAppendPreservesDuplicateAwareDigest() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let duplicates = [document(3, "alpha duplicate"), document(3, "zeta duplicate")]

    try await index.replace(SearchSessionSnapshot(sessionID: "title-duplicates", title: "Old", documents: duplicates))
    try await index._resetPersistentMutationCount()
    try await index.append(
        SearchDocumentPage(documents: duplicates),
        sessionID: "title-duplicates",
        title: "New"
    )
    #expect(try await index._persistentMutationCount() == 2)

    try await index._resetPersistentMutationCount()
    try await index.replace(SearchSessionSnapshot(sessionID: "title-duplicates", title: "New", documents: duplicates))

    #expect(try await index._persistentMutationCount() == 0)
    #expect(try await index.search("zeta", limit: 10).hits.first?.messageID.rawValue == 3)
}

@Test("append and replacement share timestamp, role, and body duplicate rank")
func duplicateRankIsStableAcrossAppendAndReplacement() async throws {
    let index = try makeIndex()
    defer { removeIndex(index.url) }
    let timestamp = Date(timeIntervalSince1970: 2)
    let assistant = SearchDocument(
        messageID: ServerMessageID(rawValue: 9),
        body: "assistant duplicate",
        role: .assistant,
        timestamp: timestamp
    )
    let userAlpha = SearchDocument(
        messageID: ServerMessageID(rawValue: 9),
        body: "alpha duplicate",
        role: .user,
        timestamp: timestamp
    )
    let userZeta = SearchDocument(
        messageID: ServerMessageID(rawValue: 9),
        body: "zeta duplicate",
        role: .user,
        timestamp: timestamp
    )

    try await index.append(
        SearchDocumentPage(documents: [assistant, userAlpha, userZeta]),
        sessionID: "append-rank",
        title: "Append rank"
    )
    try await index._resetPersistentMutationCount()
    try await index.append(
        SearchDocumentPage(documents: [assistant, userAlpha]),
        sessionID: "append-rank",
        title: "Append rank"
    )
    #expect(try await index._persistentMutationCount() == 0)

    try await index.replace(SearchSessionSnapshot(
        sessionID: "replacement-rank",
        title: "Replacement rank",
        documents: [userZeta, assistant, userAlpha]
    ))

    #expect(try await index.search("assistant", limit: 10).hits.isEmpty)
    #expect(try await index.search("alpha", limit: 10).hits.isEmpty)
    #expect(Set(try await index.search("zeta", limit: 10).hits.map(\.sessionID)) == [
        "append-rank",
        "replacement-rank"
    ])
}


private func document(_ id: Int64, _ body: String, role: Role = .user) -> SearchDocument {
    SearchDocument(messageID: ServerMessageID(rawValue: id), body: body, role: role)
}

private func makeIndex() throws -> SearchIndex {
    let url = FileManager.default.temporaryDirectory.appending(path: "HermternalSearch-\(UUID().uuidString).sqlite")
    return try SearchIndex(url: url)
}

private func removeIndex(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
}


private final class PageFactoryInvocations: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func record() -> Int {
        lock.lock()
        count += 1
        let value = count
        lock.unlock()
        return value
    }

    var value: Int {
        lock.lock()
        let value = count
        lock.unlock()
        return value
    }
}

private actor ReplacementPassGate {
    private var secondPassDidStart = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func secondPassStarted() {
        secondPassDidStart = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func waitUntilSecondPass() async {
        guard !secondPassDidStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}

private actor MutationGateGrantHook {
    private var grantCount = 0
    private var grantWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releasePermits = 0
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func granted() {
        grantCount += 1
        let ready = grantWaiters.filter { $0.0 <= grantCount }
        grantWaiters.removeAll { $0.0 <= grantCount }
        ready.forEach { $0.1.resume() }
    }

    func waitUntilGranted(_ count: Int) async {
        guard grantCount < count else { return }
        await withCheckedContinuation { grantWaiters.append((count, $0)) }
    }

    func waitForRelease() async {
        if releasePermits > 0 {
            releasePermits -= 1
            return
        }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func release() {
        if let releaseWaiter {
            self.releaseWaiter = nil
            releaseWaiter.resume()
        } else {
            releasePermits += 1
        }
    }
}

private final class QueryStartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        let value = count
        lock.unlock()
        return value
    }
}
private final class QueryStartGate: @unchecked Sendable {
    private let state = NSLock()
    private var didStart = false
    private var waiter: CheckedContinuation<Void, Never>?
    private let releaseGate = DispatchSemaphore(value: 0)

    func queryStarted() {
        state.lock()
        didStart = true
        let waiter = self.waiter
        self.waiter = nil
        state.unlock()
        waiter?.resume()
        releaseGate.wait()
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.lock()
            if didStart {
                state.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                state.unlock()
            }
        }
    }

    func release() {
        releaseGate.signal()
    }
}

private enum SearchIndexTestTimeout: Error {
    case elapsed
}

private actor SearchIndexTaskCompletion<Value: Sendable> {
    private var result: Result<Value, Error>?
    private var waiter: CheckedContinuation<Result<Value, Error>, Never>?

    func finish(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume(returning: result)
    }

    func value() async throws -> Value {
        if let result { return try result.get() }
        return try await withTaskCancellationHandler(operation: {
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Value, Error>, Never>) in
                if let storedResult = self.result {
                    continuation.resume(returning: storedResult)
                } else {
                    self.waiter = continuation
                }
            }
            return try result.get()
        }, onCancel: {
            Task { await self.cancelWaiter() }
        })
    }

    private func cancelWaiter() {
        guard result == nil, let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: .failure(CancellationError()))
    }
}

private func completesWithin<Value: Sendable>(
    _ duration: Duration = .seconds(2),
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let completion = SearchIndexTaskCompletion<Value>()
    let worker = Task {
        do {
            await completion.finish(.success(try await operation()))
        } catch {
            await completion.finish(.failure(error))
        }
    }
    defer { worker.cancel() }

    return try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await completion.value()
        }
        group.addTask {
            try await Task.sleep(for: duration)
            throw SearchIndexTestTimeout.elapsed
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            throw SearchIndexTestTimeout.elapsed
        }
        return value
    }
}

private actor QueryGateReleaseGate {
    private var didReleaseQueryGate = false
    private var released = false
    private var queryGateWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func queryGateReleased() {
        didReleaseQueryGate = true
        let waiters = queryGateWaiters
        queryGateWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func waitUntilQueryGateReleased() async {
        guard !didReleaseQueryGate else { return }
        await withCheckedContinuation { queryGateWaiters.append($0) }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func finish() {
        release()
        let waiters = queryGateWaiters
        queryGateWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}

