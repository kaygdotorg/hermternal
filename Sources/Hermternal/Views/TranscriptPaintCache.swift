import AppKit
import HermternalCore

/// Process-wide paint cache for sidebar traversal.
///
/// The table coordinator drops its per-route measurement map on every
/// selection change. This cache keeps parsed documents, measured layouts, and
/// attributed strings across those changes, keyed by turn identity. The bound
/// is 256 turns, which is 21 published tails of 12 rows, and 8 MiB of
/// attributed-string payload. LRU eviction keeps both ceilings.
@MainActor
enum TranscriptPaintCache {
    static let maxEntries = 256
    static let maxAttributedBytes = 8 * 1024 * 1024
    static let adjacentPrewarmRadius = 2

    struct LayoutKey: Hashable {
        let turnID: String
        let widthBucket: Int
        let reasoningExpanded: Bool
        let toolsExpanded: Bool
    }

    struct AttrKey: Hashable {
        let turnID: String
        let findQuery: String
        let isUniform: Bool
    }

    private struct Entry {
        var turn: TranscriptTurn
        var document: MarkdownDocument?
        var layouts: [LayoutKey: TranscriptTurnLayout] = [:]
        var attributed: [AttrKey: NSAttributedString] = [:]
        var attributedBytes = 0
    }

    private static var order: [String] = []
    private static var entries: [String: Entry] = [:]
    private static var attributedBytes = 0
    private static var prewarmTask: Task<Void, Never>?
    private(set) static var documentHits = 0
    private(set) static var documentMisses = 0
    private(set) static var layoutHits = 0
    private(set) static var layoutMisses = 0
    private(set) static var attributedHits = 0
    private(set) static var attributedMisses = 0

    static var entryCount: Int { entries.count }

    static func resetForTesting() {
        prewarmTask?.cancel()
        prewarmTask = nil
        order.removeAll(keepingCapacity: true)
        entries.removeAll(keepingCapacity: true)
        attributedBytes = 0
        documentHits = 0
        documentMisses = 0
        layoutHits = 0
        layoutMisses = 0
        attributedHits = 0
        attributedMisses = 0
    }

    static func widthBucket(_ width: CGFloat) -> Int {
        Int((width / BlockTranscriptView.Coordinator.MeasuredDocumentCache.widthTolerance).rounded())
    }

    static func document(for turn: TranscriptTurn) -> MarkdownDocument? {
        guard let entry = entries[turn.id], entry.turn == turn else {
            documentMisses += 1
            return nil
        }
        documentHits += 1
        touch(turn.id)
        return entry.document
    }

    static func layout(
        for turn: TranscriptTurn,
        width: CGFloat,
        reasoningExpanded: Bool,
        toolsExpanded: Bool
    ) -> TranscriptTurnLayout? {
        let key = LayoutKey(
            turnID: turn.id,
            widthBucket: widthBucket(width),
            reasoningExpanded: reasoningExpanded,
            toolsExpanded: toolsExpanded
        )
        guard let entry = entries[turn.id],
              entry.turn == turn,
              let layout = entry.layouts[key]
        else {
            layoutMisses += 1
            return nil
        }
        layoutHits += 1
        touch(turn.id)
        return layout
    }

    static func attributedString(
        for turn: TranscriptTurn,
        findQuery: String,
        isUniform: Bool
    ) -> NSAttributedString? {
        let key = AttrKey(turnID: turn.id, findQuery: findQuery, isUniform: isUniform)
        guard let entry = entries[turn.id],
              entry.turn == turn,
              let value = entry.attributed[key]
        else {
            attributedMisses += 1
            return nil
        }
        attributedHits += 1
        touch(turn.id)
        return value
    }

    static func store(document: MarkdownDocument, for turn: TranscriptTurn) {
        var entry = entries[turn.id] ?? Entry(turn: turn)
        if entry.turn != turn {
            attributedBytes -= entry.attributedBytes
            entry = Entry(turn: turn)
        }
        entry.document = document
        entries[turn.id] = entry
        touch(turn.id)
        evictIfNeeded()
    }

    static func store(
        layout: TranscriptTurnLayout,
        for turn: TranscriptTurn,
        width: CGFloat,
        reasoningExpanded: Bool,
        toolsExpanded: Bool
    ) {
        var entry = entries[turn.id] ?? Entry(turn: turn)
        if entry.turn != turn {
            attributedBytes -= entry.attributedBytes
            entry = Entry(turn: turn)
        }
        let key = LayoutKey(
            turnID: turn.id,
            widthBucket: widthBucket(width),
            reasoningExpanded: reasoningExpanded,
            toolsExpanded: toolsExpanded
        )
        entry.layouts[key] = layout
        entries[turn.id] = entry
        touch(turn.id)
        evictIfNeeded()
    }

    static func store(
        attributed: NSAttributedString,
        for turn: TranscriptTurn,
        findQuery: String,
        isUniform: Bool
    ) {
        var entry = entries[turn.id] ?? Entry(turn: turn)
        if entry.turn != turn {
            attributedBytes -= entry.attributedBytes
            entry = Entry(turn: turn)
        }
        let key = AttrKey(turnID: turn.id, findQuery: findQuery, isUniform: isUniform)
        let bytes = attributed.length * 2
        if let previous = entry.attributed[key] {
            entry.attributedBytes -= previous.length * 2
            attributedBytes -= previous.length * 2
        }
        entry.attributed[key] = attributed
        entry.attributedBytes += bytes
        attributedBytes += bytes
        entries[turn.id] = entry
        touch(turn.id)
        evictIfNeeded()
    }

    /// Parses, measures, and styles a published tail during idle.
    ///
    /// Callers pass adjacent sidebar sessions. The work is bounded by the
    /// published tail, not the full transcript.
    static func scheduleAdjacentPrewarm(
        selectedID: String,
        sessions: [ChatSession],
        width: CGFloat,
        tails: (String) -> [ChatMessage]
    ) {
        prewarmTask?.cancel()
        let neighbors = adjacentIDs(selectedID: selectedID, sessions: sessions)
        let payloads = neighbors.map { id in (id, tails(id)) }
        let capWidth = max(1, width)
        prewarmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            for payload in payloads {
                guard !Task.isCancelled else { return }
                await prewarm(messages: payload.1, width: capWidth)
            }
        }
    }

    static func prewarm(messages: [ChatMessage], width: CGFloat) async {
        let turns = CachedTranscript(
            version: HistoryCache.version,
            messages: messages,
            snapshot: nil
        ).turns
        let missing = turns.filter { turn in
            entries[turn.id]?.turn != turn || entries[turn.id]?.document == nil
        }
        guard !missing.isEmpty else { return }
        let widths: [(TranscriptTurn, CGFloat)] = missing.map { turn in
            (
                turn,
                TranscriptRendererTestSeam.effectiveWidth(for: turn, availableWidth: width)
            )
        }
        let prepared = await Task.detached(priority: .utility) {
            widths.map { turn, effective -> (TranscriptTurn, MarkdownDocument, TranscriptTurnLayout, CGFloat) in
                let document = MarkdownDocument.parse(turn.answer).document
                let layout = TranscriptRendererTestSeam.measuredLayout(
                    for: turn,
                    document: document,
                    width: effective,
                    reasoningExpanded: false,
                    toolsExpanded: false
                )
                return (turn, document, layout, effective)
            }
        }.value
        guard !Task.isCancelled else { return }
        for item in prepared {
            let (turn, document, layout, effective) = item
            store(document: document, for: turn)
            store(
                layout: layout,
                for: turn,
                width: effective,
                reasoningExpanded: false,
                toolsExpanded: false
            )
            guard turn.speaker != TranscriptSpeaker.me else { continue }
            let styled = TranscriptRendererTestSeam.attributedAnswer(document)
            store(
                attributed: styled,
                for: turn,
                findQuery: "",
                isUniform: false
            )
        }
    }

    private static func adjacentIDs(selectedID: String, sessions: [ChatSession]) -> [String] {
        guard let index = sessions.firstIndex(where: { $0.id == selectedID }) else {
            return Array(sessions.prefix(adjacentPrewarmRadius).map(\.id))
        }
        var ids: [String] = []
        for offset in 1...adjacentPrewarmRadius {
            let lower = index - offset
            if lower >= 0 { ids.append(sessions[lower].id) }
            let upper = index + offset
            if upper < sessions.count { ids.append(sessions[upper].id) }
        }
        return ids
    }

    private static func touch(_ id: String) {
        if let existing = order.firstIndex(of: id) {
            order.remove(at: existing)
        }
        order.append(id)
    }

    private static func evictIfNeeded() {
        while order.count > maxEntries || attributedBytes > maxAttributedBytes {
            guard let oldest = order.first else { break }
            order.removeFirst()
            if let entry = entries.removeValue(forKey: oldest) {
                attributedBytes -= entry.attributedBytes
            }
        }
        if attributedBytes < 0 { attributedBytes = 0 }
    }
}
