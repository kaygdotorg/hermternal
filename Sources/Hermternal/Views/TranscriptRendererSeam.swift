import Foundation
import HermternalCore

/// The narrow, bounded seam shared by transcript rendering adapters.
///
/// A renderer never receives the transcript corpus. It receives the route that
/// identifies the publication, its indexed summary, and the actor that owns
/// page reads. Rows and prepared layouts are fetched only for the viewport.
struct TranscriptRendererInput {
    let store: (any TranscriptTurnPageLocating)?
    let route: TranscriptRoute?
    let summary: TranscriptSummary?
    let revision: UInt64
    let isReadOnly: Bool
    let isStreaming: Bool
    let findQuery: String
    let pendingMessageID: String?
    let findMessageID: String?
    let showsMetadata: Bool
    let publishedTail: [ChatMessage]
    /// Stable chat identity for the painted surface. The paged route is nil
    /// on the selection turn, so this is what distinguishes two tails.
    let paintIdentity: String
    let onCopyCode: (String) -> Void
    let onPaint: (UInt64) -> Void

    init(
        store: (any TranscriptTurnPageLocating)?,
        route: TranscriptRoute?,
        summary: TranscriptSummary?,
        revision: UInt64,
        isReadOnly: Bool,
        isStreaming: Bool,
        findQuery: String,
        pendingMessageID: String?,
        findMessageID: String?,
        showsMetadata: Bool,
        publishedTail: [ChatMessage] = [],
        paintIdentity: String = "",
        onCopyCode: @escaping (String) -> Void,
        onPaint: @escaping (UInt64) -> Void
    ) {
        self.store = store
        self.route = route
        self.summary = summary
        self.revision = revision
        self.isReadOnly = isReadOnly
        self.isStreaming = isStreaming
        self.findQuery = findQuery
        self.pendingMessageID = pendingMessageID
        self.findMessageID = findMessageID
        self.showsMetadata = showsMetadata
        self.publishedTail = publishedTail
        self.paintIdentity = paintIdentity
        self.onCopyCode = onCopyCode
        self.onPaint = onPaint
    }
}

extension TranscriptRendererInput {
    /// Compatibility projections for instrumentation. They are derived from
    /// the immutable route rather than maintained as a second identity source.
    var routeIdentity: String {
        route?.sessionID ?? "none"
    }

    var generation: Int {
        Int(route?.generation ?? 0)
    }
}

/// Stable identity for the painted transcript surface.
///
/// New chat uses the live session id before a sidebar row exists. Adopt-live
/// of that same session is then not a switch.
enum TranscriptPaintIdentity {
    static func make(
        archivedSessionID: String?,
        selectedSessionID: String?,
        liveSessionID: String?
    ) -> String {
        if let archivedSessionID {
            return "archived:\(archivedSessionID)"
        }
        if let selectedSessionID {
            return "live:\(selectedSessionID)"
        }
        if let liveSessionID {
            return "live:\(liveSessionID)"
        }
        return "live:none"
    }
}

/// Per-switch counters for the publish-to-draw path.
///
/// The coordinator resets this on a route change. The paint callback prints
/// one line. Visit memory is bounded so a long sidebar walk cannot grow it.
@MainActor
enum TranscriptPaintAttribution {
    static let visitMemoryBound = 128

    struct Snapshot {
        var visit = 0
        var creates = 0
        var reuses = 0
        var configured = 0
        var loading = 0
        var configureNs: UInt64 = 0
        var attributedNs: UInt64 = 0
        var hugNs: UInt64 = 0
        var documentHits = 0
        var documentMisses = 0
        var answerChars = 0
        var codeBlocks = 0
        var tableBlocks = 0
        var storeNil = false
        var tailCount = 0
        var loadedCount = 0
        var attrCacheHits = 0
        var attrCacheMisses = 0
    }

    private static var visits: [String: Int] = [:]
    private static var visitOrder: [String] = []
    static var current = Snapshot()

    static func beginSwitch(
        identity: String,
        storeNil: Bool,
        tailCount: Int,
        loadedCount: Int
    ) {
        let visit = (visits[identity] ?? 0) + 1
        visits[identity] = visit
        visitOrder.append(identity)
        while visitOrder.count > visitMemoryBound {
            let evicted = visitOrder.removeFirst()
            if evicted != identity {
                visits.removeValue(forKey: evicted)
            }
        }
        current = Snapshot(
            visit: visit,
            storeNil: storeNil,
            tailCount: tailCount,
            loadedCount: loadedCount
        )
    }

    static func noteRow(created: Bool) {
        if created { current.creates += 1 } else { current.reuses += 1 }
    }

    static func noteLoading() {
        current.loading += 1
    }

    static func noteConfigured(
        documentHit: Bool,
        answerChars: Int,
        codeBlocks: Int,
        tableBlocks: Int,
        configureNs: UInt64,
        hugNs: UInt64
    ) {
        current.configured += 1
        if documentHit { current.documentHits += 1 } else { current.documentMisses += 1 }
        current.answerChars += answerChars
        current.codeBlocks += codeBlocks
        current.tableBlocks += tableBlocks
        current.configureNs &+= configureNs
        current.hugNs &+= hugNs
    }

    static func noteAttributed(nanoseconds: UInt64, cacheHit: Bool) {
        current.attributedNs &+= nanoseconds
        if cacheHit { current.attrCacheHits += 1 } else { current.attrCacheMisses += 1 }
    }

    static func line() -> String {
        let snapshot = current
        func ms(_ ns: UInt64) -> String {
            String(format: "%.3f", Double(ns) / 1_000_000)
        }
        return "visit=\(snapshot.visit) creates=\(snapshot.creates) reuses=\(snapshot.reuses) configured=\(snapshot.configured) loading=\(snapshot.loading) cfgMs=\(ms(snapshot.configureNs)) attrMs=\(ms(snapshot.attributedNs)) hugMs=\(ms(snapshot.hugNs)) docHit=\(snapshot.documentHits) docMiss=\(snapshot.documentMisses) attrHit=\(snapshot.attrCacheHits) attrMiss=\(snapshot.attrCacheMisses) chars=\(snapshot.answerChars) code=\(snapshot.codeBlocks) tables=\(snapshot.tableBlocks) storeNil=\(snapshot.storeNil) tail=\(snapshot.tailCount) loaded=\(snapshot.loadedCount)"
    }
}
