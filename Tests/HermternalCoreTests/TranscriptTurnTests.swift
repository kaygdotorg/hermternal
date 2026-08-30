import Foundation
import Testing
@testable import HermternalCore

private func turnRecord(
    _ id: String,
    role: String = "assistant",
    text: String = "",
    displayKind: String? = nil,
    metadata: [String: JSONValue]? = nil,
    toolCallID: String? = nil,
    toolName: String? = nil,
    toolStatus: String? = nil
) -> WireMessageRecord {
    WireMessageRecord(
        messageID: id,
        role: role,
        text: text,
        displayKind: displayKind,
        displayMetadata: metadata,
        toolCallID: toolCallID,
        toolName: toolName,
        toolStatus: toolStatus
    )
}

@Test("zero model markers use the session model")
func zeroModelMarkersUseFallback() {
    let turns = TranscriptTurnProjector.project(
        records: [turnRecord("m", text: "answer")],
        sessionModel: "session-model"
    )
    #expect(turns.first?.model == "session-model")
}

@Test("content before the first marker has no attribution")
func contentBeforeFirstMarkerHasNoModel() {
    let records = [
        turnRecord("before", text: "old"),
        turnRecord("switch", displayKind: "model_switch", metadata: ["model": .string("new")]),
        turnRecord("after", text: "new")
    ]
    let turns = TranscriptTurnProjector.project(records: records, sessionModel: "fallback")
    #expect(turns.map(\.model) == [nil, "new"])
}

@Test("multiple markers apply in full ordered input")
func multipleModelMarkersApplyInOrder() {
    let records = [
        turnRecord("a", text: "one"),
        turnRecord("switch-a", displayKind: "model_switch", metadata: ["model_id": .string("alpha")]),
        turnRecord("b", text: "two"),
        turnRecord("switch-b", displayKind: "model_switch", metadata: ["name": .string("beta")]),
        turnRecord("c", text: "three")
    ]
    let turns = TranscriptTurnProjector.project(records: records)
    #expect(turns.map(\.model) == [nil, "alpha", "beta"])
    #expect(TranscriptTurnProjector.modelSwitches(in: records).map(\.id) == ["switch-a", "switch-b"])
}

@Test("malformed marker remains metadata and does not activate fallback")
func malformedMarkerDoesNotGuessModel() {
    let records = [
        turnRecord("switch", displayKind: "model_switch", metadata: ["unexpected": .string("value")]),
        turnRecord("answer", text: "content")
    ]
    let turns = TranscriptTurnProjector.project(records: records, sessionModel: "session")
    #expect(turns.first?.model == nil)
    #expect(TranscriptTurnProjector.modelSwitches(in: records).count == 1)
}

@Test("reasoning without effort uses generic label")
func reasoningWithoutEffortUsesGenericLabel() {
    let turn = TranscriptTurnProjector.project(records: [
        WireMessageRecord(messageID: "r", text: "answer", reasoning: "private reasoning")
    ]).first
    #expect(turn?.reasoning?.label == "Reasoning")
}

@Test("tool lifecycle keeps one stable id and terminal state")
func toolLifecycleProjectsStableRun() {
    let records = [
        turnRecord("start", displayKind: "tool_event", toolCallID: "call-1", toolName: "shell", toolStatus: "running"),
        turnRecord("progress", displayKind: "tool_event", toolCallID: "call-1", toolName: "shell", toolStatus: "running"),
        turnRecord("complete", displayKind: "tool_event", toolCallID: "call-1", toolName: "shell", toolStatus: "completed")
    ]
    let first = TranscriptTurnProjector.project(records: records).first?.tools.first
    #expect(first?.id == "start:tool:call-1")
    #expect(first?.state == .completed)
}

@Test("tool errors are terminal and never create an empty disclosure")
func toolErrorProjectsErrorState() {
    let tool = TranscriptTurnProjector.project(records: [
        turnRecord("error", displayKind: "tool_event", toolCallID: "call-2", toolName: "shell", toolStatus: "error")
    ]).first?.tools.first
    #expect(tool?.state == .error)
    #expect(tool?.name == "shell")
}

@Test("paged store excludes model markers from rendered rows")
func pagedStoreExcludesMarkers() async throws {
    let fs = InMemoryTranscriptFileSystem()
    let store = PagedTranscriptStore(sessionID: "turns", directory: URL(fileURLWithPath: "/turns"), fileSystem: fs)
    try await store.append(turnRecord("switch", displayKind: "model_switch", metadata: ["model": .string("x")]))
    try await store.append(turnRecord("answer", text: "visible"))
    let page = try await store.page(.head(maximumBytes: 1000, maximumRows: 10))
    #expect(page.rows.map(\.id) == ["answer:0"])
    #expect((try await store.modelSwitches()).map(\.model) == ["x"])
}

@Test("cached wire metadata projects offline turns")
func cachedWireMetadataProjectsOfflineTurns() {
    let cached = CachedTranscript(
        version: HistoryCache.version,
        messages: [],
        snapshot: nil,
        records: [
            turnRecord("switch", displayKind: "model_switch", metadata: ["model": .string("offline")]),
            turnRecord("answer", text: "cached")
        ]
    )
    #expect(cached.turns.first?.model == "offline")
    #expect(cached.turns.first?.answer == "cached")
}

@Test("search documents reject markers and tools")
func searchDocumentsRejectMetadata() {
    let marker = SearchDocument(messageID: ServerMessageID(rawValue: 1), body: "secret", role: .system, displayKind: "model_switch")
    let tool = SearchDocument(messageID: ServerMessageID(rawValue: 2), body: "secret", role: .system, displayKind: "tool_event", isTool: true)
    let answer = SearchDocument(messageID: ServerMessageID(rawValue: 3), body: "visible", role: .assistant)
    #expect(!marker.isSearchable)
    #expect(!tool.isSearchable)
    #expect(answer.isSearchable)
}
 
@Test("paged store satisfies the composed turn locator interface")
func pagedStoreConformsToTurnLocatorInterface() {
    let store = PagedTranscriptStore(
        sessionID: "interface",
        directory: URL(fileURLWithPath: "/interface"),
        fileSystem: InMemoryTranscriptFileSystem()
    )
    let _: any TranscriptTurnPageLocating = store
}

@Test("legacy persisted rows produce turn pages without metadata")
func legacyRowsProduceTurns() async throws {
    let fs = InMemoryTranscriptFileSystem()
    let directory = URL(fileURLWithPath: "/legacy-turns")
    let record = WireMessageRecord(messageID: "legacy", role: "assistant", text: "cached answer")
    let encoded = try JSONEncoder().encode(record)
    var frame = Data()
    var length = UInt64(encoded.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(encoded)
    let encodedID = Data(record.messageID.utf8).base64EncodedString()
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "+", with: "-")
    try fs.createDirectory(directory)
    try fs.write(frame, to: directory.appendingPathComponent("record-\(encodedID).json"))
    let descriptor = TranscriptRowDescriptor(
        messageID: record.messageID,
        blockIndex: 0,
        ordinal: 0,
        slice: StringSlice(length: record.text.utf8.count),
        byteCount: record.text.utf8.count
    )
    let entry = TranscriptDiskIndex.Entry(
        messageID: record.messageID,
        recordOffset: 0,
        recordLength: UInt64(record.text.utf8.count),
        firstOrdinal: 0,
        rowCount: 1,
        revision: 0
    )
    let indexData = try JSONEncoder().encode(
        TranscriptDiskIndex(entries: [record.messageID: entry], descriptors: [descriptor])
    )
    try fs.write(indexData, to: directory.appendingPathComponent("index.json"))
    let manifestData = try JSONEncoder().encode(TranscriptManifest())
    try fs.write(manifestData, to: directory.appendingPathComponent("manifest.json"))
    let store = PagedTranscriptStore(sessionID: "legacy", directory: directory, fileSystem: fs)
    let page = try await store.turnPage(TranscriptTurnPageRequest())
    #expect(page.turns.first?.answer == "cached answer")
}

@Test("turn pages use contiguous turn ordinals across wire metadata")
func turnPagesRemainContiguous() async throws {
    let fs = InMemoryTranscriptFileSystem()
    let store = PagedTranscriptStore(
        sessionID: "paged-turns",
        directory: URL(fileURLWithPath: "/paged-turns"),
        fileSystem: fs
    )
    for index in 0..<64 {
        if index == 16 || index == 48 {
            try await store.append(turnRecord(
                "switch-\(index)",
                displayKind: "model_switch",
                metadata: ["model": .string("model-\(index)")]
            ))
        }
        try await store.append(turnRecord("\(index)", text: "answer-\(index)"))
        if index.isMultiple(of: 8) {
            try await store.append(turnRecord(
                "tool-\(index)",
                displayKind: "tool_event",
                toolCallID: "call-\(index)",
                toolName: "shell",
                toolStatus: "completed"
            ))
        }
    }
    let first = try await store.turnPage(TranscriptTurnPageRequest(maximumRows: 10))
    let second = try await store.turnPage(TranscriptTurnPageRequest(
        startOrdinal: first.nextOrdinal,
        maximumRows: 10
    ))
    #expect(first.startOrdinal == 0)
    #expect(first.nextOrdinal == 10)
    #expect(second.startOrdinal == 10)
    #expect(second.turns.map(\.id) == (10..<20).map(String.init))
    #expect(first.totalTurnCount == 64)
    #expect(second.totalTurnCount == 64)
    #expect((try await store.locateTurn(messageID: "48"))?.ordinal == 48)
}
