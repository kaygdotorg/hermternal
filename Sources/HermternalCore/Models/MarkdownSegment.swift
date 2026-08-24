import Foundation
/// Opt-in contention measurements for interactive transcript work.
///
/// The probe records lock and actor-entry wait only. It does not record work
/// duration. The app owns selection boundaries and emits one snapshot per
/// selection.
public enum ContentionTrace {
    public struct Aggregate: Sendable, Equatable {
        public let count: Int
        public let totalNanoseconds: UInt64
        public let maxNanoseconds: UInt64
        public let backgroundAtBeginTotal: UInt64
        public let backgroundAtBeginMax: Int

        public init(
            count: Int,
            totalNanoseconds: UInt64,
            maxNanoseconds: UInt64,
            backgroundAtBeginTotal: UInt64,
            backgroundAtBeginMax: Int
        ) {
            self.count = count
            self.totalNanoseconds = totalNanoseconds
            self.maxNanoseconds = maxNanoseconds
            self.backgroundAtBeginTotal = backgroundAtBeginTotal
            self.backgroundAtBeginMax = backgroundAtBeginMax
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public let resources: [String: Aggregate]
        public let backgroundWorkInFlight: Int

        public init(resources: [String: Aggregate], backgroundWorkInFlight: Int) {
            self.resources = resources
            self.backgroundWorkInFlight = backgroundWorkInFlight
        }
    }

    struct Request: Sendable {
        let resource: String
        let beganAt: UInt64
        let backgroundAtBegin: Int
        let generation: UInt64
        var waitTotal: UInt64 = 0
        var waitMax: UInt64 = 0
    }

    @inline(__always)
    private static func isEnabled() -> Bool {
        MeasurementGate.isEnabled(.resourceContention)
    }


    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var backgroundWorkInFlight = 0
        var aggregates: [String: Aggregate] = [:]
        var generation: UInt64 = 0
    }

    private static let state = State()

    /// Resets all measurements at the beginning of one selection.
    public static func reset() {
        TextWorkTrace.reset()
        guard isEnabled() else { return }
        state.lock.lock()
        state.aggregates.removeAll(keepingCapacity: true)
        state.generation &+= 1
        state.lock.unlock()
    }

    /// Returns and resets the current selection snapshot.
    ///
    /// The tagged lines use nanoseconds and contain only aggregate fields.
    @discardableResult
    public static func snapshotAndReset(phase: String = "selection") -> Snapshot {
        guard isEnabled() else {
            TextWorkTrace.emitAndReset(phase: phase)
            return Snapshot(resources: [:], backgroundWorkInFlight: 0)
        }
        state.lock.lock()
        let snapshot = Snapshot(
            resources: state.aggregates,
            backgroundWorkInFlight: state.backgroundWorkInFlight
        )
        state.aggregates.removeAll(keepingCapacity: true)
        state.generation &+= 1
        state.lock.unlock()
        emit(snapshot, phase: phase)
        TextWorkTrace.emitAndReset(phase: phase)
        return snapshot
    }

    /// Marks one background lane as active.
    public static func beginBackgroundWork() {
        guard isEnabled() else { return }
        state.lock.lock()
        state.backgroundWorkInFlight += 1
        state.lock.unlock()
    }

    /// Marks one background lane as inactive.
    public static func endBackgroundWork() {
        guard isEnabled() else { return }
        state.lock.lock()
        state.backgroundWorkInFlight = max(0, state.backgroundWorkInFlight - 1)
        state.lock.unlock()
    }

    private static func begin(
        resource: String,
        requireMainThread: Bool
    ) -> Request? {
        guard isEnabled() else { return nil }
        guard !requireMainThread || Thread.isMainThread else { return nil }
        state.lock.lock()
        let backgroundAtBegin = state.backgroundWorkInFlight
        let generation = state.generation
        state.lock.unlock()
        return Request(
            resource: resource,
            beganAt: DispatchTime.now().uptimeNanoseconds,
            backgroundAtBegin: backgroundAtBegin,
            generation: generation
        )
    }

    static func beginInteractive(resource: String) -> Request? {
        begin(resource: resource, requireMainThread: false)
    }

    static func beginMainInteractive(resource: String) -> Request? {
        begin(resource: resource, requireMainThread: true)
    }

    static func recordLockWait(
        _ request: inout Request?,
        startedAt: UInt64
    ) {
        guard isEnabled() else {
            request = nil
            return
        }
        guard var value = request else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
        value.waitTotal &+= elapsed
        value.waitMax = max(value.waitMax, elapsed)
        request = value
    }

    static func finishInteractive(_ request: inout Request?) {
        guard isEnabled() else {
            request = nil
            return
        }
        guard let value = request else { return }
        state.lock.lock()
        guard state.generation == value.generation else {
            state.lock.unlock()
            request = nil
            return
        }
        let current = state.aggregates[value.resource]
        state.aggregates[value.resource] = Aggregate(
            count: (current?.count ?? 0) + 1,
            totalNanoseconds: (current?.totalNanoseconds ?? 0) &+ value.waitTotal,
            maxNanoseconds: max(current?.maxNanoseconds ?? 0, value.waitMax),
            backgroundAtBeginTotal: (current?.backgroundAtBeginTotal ?? 0)
                &+ UInt64(value.backgroundAtBegin),
            backgroundAtBeginMax: max(
                current?.backgroundAtBeginMax ?? 0,
                value.backgroundAtBegin
            )
        )
        state.lock.unlock()
        request = nil
    }

    private static func emit(_ snapshot: Snapshot, phase: String) {
        guard !snapshot.resources.isEmpty else {
            let line = "[DEBUG-contention-7F3A] ns="
                + "\(DispatchTime.now().uptimeNanoseconds)"
                + " event=contention.aggregate"
                + " phase=\(phase)"
                + " resource=none"
                + " count=0 wait_total_ns=0 wait_max_ns=0"
                + " bg_at_begin_total=0 bg_at_begin_max=0"
                + " bg_inflight=\(snapshot.backgroundWorkInFlight)\n"
            FileHandle.standardError.write(Data(line.utf8))
            return
        }
        for resource in snapshot.resources.keys.sorted() {
            guard let aggregate = snapshot.resources[resource] else { continue }
            let line = "[DEBUG-contention-7F3A] ns="
                + "\(DispatchTime.now().uptimeNanoseconds)"
                + " event=contention.aggregate"
                + " phase=\(phase)"
                + " resource=\(resource)"
                + " count=\(aggregate.count)"
                + " wait_total_ns=\(aggregate.totalNanoseconds)"
                + " wait_max_ns=\(aggregate.maxNanoseconds)"
                + " bg_at_begin_total=\(aggregate.backgroundAtBeginTotal)"
                + " bg_at_begin_max=\(aggregate.backgroundAtBeginMax)"
                + " bg_inflight=\(snapshot.backgroundWorkInFlight)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
/// Opt-in aggregate accounting for text work performed while SwiftUI evaluates
/// transcript rows. This deliberately records only counters and monotonic
/// durations; it never retains or emits message contents.
public enum TextWorkTrace {
    public enum Category: String, CaseIterable, Hashable, Sendable {
        case markdownParseHit = "markdown.parse.hit"
        case markdownParseMiss = "markdown.parse.miss"
        case markdownParseSpans = "markdown.parse.spans"
        case attributedConstruction = "attributed.construction"
        case stringConversion = "string.conversion"
        case appLayout = "app.layout"
    }

    public struct Token: Sendable {
        fileprivate let startedAt: UInt64
        fileprivate let generation: UInt64
    }

    private struct Aggregate {
        var count = 0
        var characters = 0
        var totalNanoseconds: UInt64 = 0
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var generation: UInt64 = 0
        var aggregates: [Category: Aggregate] = [:]
        var largestRowCharacters = 0
    }

    @inline(__always)
    private static func isEnabled() -> Bool {
        MeasurementGate.isEnabled(.textLayoutAttribution)
    }
    private static let state = State()

    static func reset() {
        guard isEnabled() else { return }
        state.lock.lock()
        state.generation &+= 1
        state.aggregates.removeAll(keepingCapacity: true)
        state.largestRowCharacters = 0
        state.lock.unlock()
    }

    public static func begin() -> Token? {
        guard isEnabled() else { return nil }
        state.lock.lock()
        let generation = state.generation
        state.lock.unlock()
        return Token(
            startedAt: DispatchTime.now().uptimeNanoseconds,
            generation: generation
        )
    }

    public static func finish(
        _ token: Token?,
        category: Category,
        characters: Int
    ) {
        guard isEnabled(), let token else { return }
        finishMeasured(token, category: category, characters: characters)
    }

    private static func finishMeasured(
        _ token: Token,
        category: Category,
        characters: Int
    ) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- token.startedAt
        state.lock.lock()
        guard state.generation == token.generation else {
            state.lock.unlock()
            return
        }
        var aggregate = state.aggregates[category] ?? Aggregate()
        aggregate.count &+= 1
        aggregate.characters &+= max(0, characters)
        aggregate.totalNanoseconds &+= elapsed
        state.aggregates[category] = aggregate
        state.lock.unlock()
    }

    public static func finish(
        _ token: Token?,
        category: Category,
        text: String
    ) {
        guard isEnabled(), let token else { return }
        finishMeasured(
            token,
            category: category,
            characters: text.utf16.count
        )
    }


    public static func recordRow(text: String) {
        guard isEnabled() else { return }
        let characters = text.utf16.count
        state.lock.lock()
        state.largestRowCharacters = max(state.largestRowCharacters, characters)
        state.lock.unlock()
    }

    static func emitAndReset(phase: String) {
        guard isEnabled() else { return }
        state.lock.lock()
        let aggregates = state.aggregates
        let largestRowCharacters = state.largestRowCharacters
        state.aggregates.removeAll(keepingCapacity: true)
        state.largestRowCharacters = 0
        state.generation &+= 1
        state.lock.unlock()

        for category in Category.allCases {
            let aggregate = aggregates[category] ?? Aggregate()
            let line = "[DEBUG-contention-7F3A] ns="
                + "\(DispatchTime.now().uptimeNanoseconds)"
                + " event=text.aggregate"
                + " phase=\(phase)"
                + " category=\(category.rawValue)"
                + " count=\(aggregate.count)"
                + " chars_total=\(aggregate.characters)"
                + " total_ns=\(aggregate.totalNanoseconds)"
                + " largest_row_chars=\(largestRowCharacters)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}


fileprivate func tracedStringConversion(_ value: Substring) -> String {
    let token = TextWorkTrace.begin()
    let result = String(value)
    TextWorkTrace.finish(
        token,
        category: .stringConversion,
        text: result
    )
    return result
}

fileprivate func tracedStringConversion(_ value: Character) -> String {
    let token = TextWorkTrace.begin()
    let result = String(value)
    TextWorkTrace.finish(
        token,
        category: .stringConversion,
        text: result
    )
    return result
}

/// A message body split into inline-rendered blocks and fenced-code runs.
///
/// `parse(_:)` is synchronous because it is consumed directly by SwiftUI.
/// Parsed values are owned by a process-local, lock-protected byte-bounded
/// cache. The cache is intentionally not an actor: parsing must remain a
/// synchronous, platform-neutral Core seam.
public enum MarkdownSegment: Identifiable, Sendable, Equatable {
    case prose(id: Int, AttributedString)
    case heading(id: Int, level: Int, AttributedString)
    case bullet(id: Int, marker: String, depth: Int, AttributedString)
    case numbered(id: Int, marker: String, number: Int, depth: Int, AttributedString)
    case code(id: Int, language: String, body: String)

    /// The decoded payload budget for the process-local parse cache.
    ///
    /// This is deliberately finite so visiting more chats cannot retain an
    /// unbounded number of attributed Markdown values.
    public static let parseCacheByteBudget = MarkdownParseCache.byteBudget

    /// An inexpensive diagnostic for the cache's currently retained payload.
    public static var parseCacheRetainedBytes: Int {
        MarkdownParseCache.shared.retainedByteCount
    }

    public var id: Int {
        switch self {
        case .prose(let id, _),
             .heading(let id, _, _),
             .bullet(let id, _, _, _),
             .numbered(let id, _, _, _, _),
             .code(let id, _, _):
            return id
        }
    }

    /// Parses and caches the message's block and inline structure.
    public static func parse(_ text: String) -> [MarkdownSegment] {
        MarkdownParseCache.shared.value(for: text).segments
    }

    /// A descriptive alias for callers that want to make the cached seam
    /// explicit.
    public static func segments(for text: String) -> [MarkdownSegment] {
        parse(text)
    }

    /// UTF-16 source spans aligned with `parse(_:)`'s returned segments.
    /// `language` is the info-string span for a fenced-code segment.
    ///
    /// Spans are intentionally recomputed for this request and are not
    /// retained with the decoded attributed payload.
    public static func sourceSpans(for text: String) -> [
        (source: Range<Int>, language: Range<Int>?)
    ] {
        MarkdownParseCache.shared.sourceSpans(for: text)
    }

    fileprivate static func parseUncached(
        _ text: String,
        includeSegments: Bool = true,
        includeSourceSpans: Bool = false
    ) -> MarkdownParseResult {
        var segments: [MarkdownSegment] = []
        var sourceSpans: [(source: Range<Int>, language: Range<Int>?)] = []
        var proseBuffer: [Substring] = []
        var proseStart: Int?
        var proseEnd: Int?
        var codeBuffer: [Substring] = []
        var language = ""
        var languageRange: Range<Int>?
        var codeStart = 0
        var inFence = false
        var position = 0
        var offset = 0
        let textLength = text.utf16.count

        func flushProse(at end: Int) {
            guard !proseBuffer.isEmpty, let start = proseStart else {
                proseBuffer.removeAll(keepingCapacity: true)
                proseStart = nil
                proseEnd = nil
                return
            }
            let joinToken = includeSegments ? TextWorkTrace.begin() : nil
            let joined = includeSegments ? proseBuffer.joined(separator: "\n") : ""
            TextWorkTrace.finish(
                joinToken,
                category: .stringConversion,
                text: joined
            )
            proseBuffer.removeAll(keepingCapacity: true)
            proseStart = nil
            proseEnd = nil
            if includeSegments && !joined.isEmpty {
                let id = stableID(kind: "prose", position: position, content: joined)
                segments.append(.prose(id: id, attributed(from: joined)))
            }
            if includeSourceSpans {
                sourceSpans.append((start..<max(start, end), nil))
            }
            position += 1
        }

        func flushCode(at end: Int) {
            let joinToken = includeSegments ? TextWorkTrace.begin() : nil
            let body = includeSegments ? codeBuffer.joined(separator: "\n") : ""
            TextWorkTrace.finish(
                joinToken,
                category: .stringConversion,
                text: body
            )
            codeBuffer.removeAll(keepingCapacity: true)
            if includeSegments {
                let id = stableID(
                    kind: "code|\(language)",
                    position: position,
                    content: body
                )
                segments.append(.code(id: id, language: language, body: body))
            }
            if includeSourceSpans {
                sourceSpans.append((min(codeStart, end)..<min(end, offset), languageRange))
            }
            position += 1
            language = ""
            languageRange = nil
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStart = offset
            let lineEnd = lineStart + line.utf16.count

            if line.hasPrefix("```") {
                if inFence {
                    flushCode(at: lineStart)
                    inFence = false
                } else {
                    flushProse(at: lineStart)
                    language = tracedStringConversion(line.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                    languageRange = (lineStart + 3)..<lineEnd
                    codeStart = min(lineEnd + 1, textLength)
                    inFence = true
                }
                offset = lineEnd + 1
                continue
            }

            if inFence {
                codeBuffer.append(line)
                offset = lineEnd + 1
                continue
            }

            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushProse(at: lineStart)
                offset = lineEnd + 1
                continue
            }

            if let heading = heading(in: line) {
                flushProse(at: lineStart)
                if includeSegments {
                    let id = stableID(
                        kind: "heading|\(heading.level)",
                        position: position,
                        content: heading.content
                    )
                    segments.append(.heading(
                        id: id,
                        level: heading.level,
                        attributed(from: heading.content)
                    ))
                }
                if includeSourceSpans {
                    sourceSpans.append((lineStart..<lineEnd, nil))
                }
                position += 1
                offset = lineEnd + 1
                continue
            }

            if let bullet = bullet(in: line) {
                flushProse(at: lineStart)
                if includeSegments {
                    let id = stableID(
                        kind: "bullet|\(bullet.marker)|\(bullet.depth)",
                        position: position,
                        content: bullet.content
                    )
                    segments.append(.bullet(
                        id: id,
                        marker: bullet.marker,
                        depth: bullet.depth,
                        attributed(from: bullet.content)
                    ))
                }
                if includeSourceSpans {
                    sourceSpans.append((lineStart..<lineEnd, nil))
                }
                position += 1
                offset = lineEnd + 1
                continue
            }

            if let numbered = numbered(in: line) {
                flushProse(at: lineStart)
                if includeSegments {
                    let id = stableID(
                        kind: "numbered|\(numbered.marker)|\(numbered.number)|\(numbered.depth)",
                        position: position,
                        content: numbered.content
                    )
                    segments.append(.numbered(
                        id: id,
                        marker: numbered.marker,
                        number: numbered.number,
                        depth: numbered.depth,
                        attributed(from: numbered.content)
                    ))
                }
                if includeSourceSpans {
                    sourceSpans.append((lineStart..<lineEnd, nil))
                }
                position += 1
                offset = lineEnd + 1
                continue
            }

            proseBuffer.append(line)
            proseStart = proseStart ?? lineStart
            proseEnd = lineEnd
            offset = lineEnd + 1
        }

        if inFence {
            flushCode(at: textLength)
        } else {
            flushProse(at: proseEnd ?? textLength)
        }
        return MarkdownParseResult(segments: segments, sourceSpans: sourceSpans)
    }

    private static func heading(in line: Substring) -> (level: Int, content: String)? {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        guard indentation.count <= 3 else { return nil }
        let remainder = line.dropFirst(indentation.count)
        let hashes = remainder.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let afterHashes = remainder.dropFirst(hashes.count)
        guard afterHashes.isEmpty || afterHashes.first == " " || afterHashes.first == "\t" else {
            return nil
        }
        let content = afterHashes.drop { $0 == " " || $0 == "\t" }
        return (hashes.count, tracedStringConversion(content))
    }

    private static func bullet(in line: Substring) -> (marker: String, depth: Int, content: String)? {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        let remainder = line.dropFirst(indentation.count)
        guard let marker = remainder.first, "-*+".contains(marker) else { return nil }
        let afterMarker = remainder.dropFirst()
        guard afterMarker.first == " " || afterMarker.first == "\t" else { return nil }
        let content = afterMarker.drop { $0 == " " || $0 == "\t" }
        return (
            tracedStringConversion(marker),
            indentationDepth(indentation),
            tracedStringConversion(content)
        )
    }

    private static func numbered(in line: Substring) -> (
        marker: String,
        number: Int,
        depth: Int,
        content: String
    )? {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        let remainder = line.dropFirst(indentation.count)
        var digits = remainder.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let afterDigits = remainder.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else {
            return nil
        }
        let afterDelimiter = afterDigits.dropFirst()
        guard afterDelimiter.first == " " || afterDelimiter.first == "\t" else { return nil }
        guard let number = Int(digits) else { return nil }
        let content = afterDelimiter.drop { $0 == " " || $0 == "\t" }
        return (
            tracedStringConversion(digits) + tracedStringConversion(delimiter),
            number,
            indentationDepth(indentation),
            tracedStringConversion(content)
        )
    }

    private static func indentationDepth(_ indentation: Substring) -> Int {
        // Two spaces (or one tab) represent one nested list level. This
        // accepts the common Markdown indentation forms while keeping depth
        // deterministic for malformed or mixed indentation.
        let columns = indentation.reduce(into: 0) { columns, character in
            columns += character == "\t" ? 2 : 1
        }
        return columns / 2
    }

    private static func stableID(kind: String, position: Int, content: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let value = "\(kind)|\(position)|\(content)"
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(truncatingIfNeeded: hash)
    }

    private static func attributed(from markdown: String) -> AttributedString {
        let token = TextWorkTrace.begin()
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let result = (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
        TextWorkTrace.finish(
            token,
            category: .attributedConstruction,
            text: markdown
        )
        return result
    }
}
 
/// All inputs that can affect a rendered transcript row's measured height.
///
/// Width and display scale are stored as their exact bit patterns rather than
/// rounded values: a fractional backing-space change must never reuse a
/// measurement made for a different layout proposal. `revision` is supplied by
/// the renderer and changes whenever the message payload or rendering state
/// changes.
public struct RowHeightCacheKey: Hashable, Sendable {
    public let messageID: MessageIdentity
    public let revision: String
    public let availableWidthBits: UInt64
    public let textStyle: String
    public let displayScaleBits: UInt64
    public let rendererVersion: Int

    public init(
        messageID: MessageIdentity,
        revision: String,
        availableWidthBits: UInt64,
        textStyle: String,
        displayScaleBits: UInt64,
        rendererVersion: Int
    ) {
        self.messageID = messageID
        self.revision = revision
        self.availableWidthBits = availableWidthBits
        self.textStyle = textStyle
        self.displayScaleBits = displayScaleBits
        self.rendererVersion = rendererVersion
    }
}

/// Lock-protected byte-bounded LRU storage shared by decoded transcript
/// payloads and renderer measurements.
///
/// Eviction is deterministic: the least recently used entry is removed first,
/// and every access receives a monotonically increasing clock value. Entries
/// larger than the budget are returned to their caller but are not retained.
public final class ByteBoundedCache<Key: Hashable, Value>: @unchecked Sendable {
    private struct Entry {
        let value: Value
        let byteCost: Int
        let lastUsed: UInt64
    }

    public let byteBudget: Int
    private let lock = NSLock()
    private var values: [Key: Entry] = [:]
    private var accessClock: UInt64 = 0
    private var retainedBytes = 0

    public init(byteBudget: Int) {
        self.byteBudget = max(1, byteBudget)
    }

    public var retainedByteCount: Int {
        withLock { retainedBytes }
    }

    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    fileprivate func valueWithoutLock(for key: Key) -> Value? {
        guard let cached = values[key] else { return nil }
        accessClock &+= 1
        values[key] = Entry(
            value: cached.value,
            byteCost: cached.byteCost,
            lastUsed: accessClock
        )
        return cached.value
    }

    fileprivate func insertWithoutLock(
        _ value: Value,
        for key: Key,
        byteCost: Int
    ) {
        let cost = max(1, byteCost)
        guard cost <= byteBudget else { return }
        if let previous = values.removeValue(forKey: key) {
            retainedBytes -= previous.byteCost
        }
        while retainedBytes + cost > byteBudget,
              let victim = values.min(by: { lhs, rhs in
                  lhs.value.lastUsed < rhs.value.lastUsed
              }) {
            values.removeValue(forKey: victim.key)
            retainedBytes -= victim.value.byteCost
        }
        accessClock &+= 1
        values[key] = Entry(value: value, byteCost: cost, lastUsed: accessClock)
        retainedBytes += cost
    }

    public func value(for key: Key) -> Value? {
        withLock {
            valueWithoutLock(for: key)
        }
    }

    public func insert(_ value: Value, for key: Key, byteCost: Int) {
        withLock {
            insertWithoutLock(value, for: key, byteCost: byteCost)
        }
    }
}
fileprivate struct MarkdownParseResult {
    let segments: [MarkdownSegment]
    let sourceSpans: [(source: Range<Int>, language: Range<Int>?)]
}

/// Lock-protected storage with a byte budget and deterministic LRU eviction.
///
/// The 8 MiB budget is sized for a modest decoded transcript working set while
/// putting a hard ceiling on attributed-string residency. Costs are estimated
/// once at insertion: two bytes per key UTF-8 byte, four bytes per attributed
/// UTF-8 byte, two bytes per code-string UTF-8 byte, plus fixed segment/storage
/// overhead. The estimate is intentionally conservative; an entry larger than
/// the budget is returned to its caller but not retained.
private final class MarkdownParseCache: @unchecked Sendable {
    static let byteBudget = 8 * 1024 * 1024
    static let shared = MarkdownParseCache()

    private let storage = ByteBoundedCache<String, [MarkdownSegment]>(
        byteBudget: MarkdownParseCache.byteBudget
    )

    var retainedByteCount: Int {
        storage.retainedByteCount
    }

    func value(for key: String) -> MarkdownParseResult {
        lookupOrParse(key, includeSourceSpans: false, measureWait: true)
    }

    func sourceSpans(for key: String) -> [
        (source: Range<Int>, language: Range<Int>?)
    ] {
        let token = TextWorkTrace.begin()
        let result = lookupOrParse(key, includeSourceSpans: true, measureWait: false)
        TextWorkTrace.finish(
            token,
            category: .markdownParseSpans,
            text: key
        )
        return result.sourceSpans
    }

    private func lookupOrParse(
        _ key: String,
        includeSourceSpans: Bool,
        measureWait: Bool
    ) -> MarkdownParseResult {
        let textToken = includeSourceSpans ? nil : TextWorkTrace.begin()
        var contentionRequest = measureWait
            ? ContentionTrace.beginMainInteractive(resource: "markdown-parse")
            : nil
        var lockStartedAt: UInt64 = contentionRequest == nil
            ? 0
            : DispatchTime.now().uptimeNanoseconds
        let cached = storage.withLock {
            ContentionTrace.recordLockWait(&contentionRequest, startedAt: lockStartedAt)
            return storage.valueWithoutLock(for: key)
        }
        if let cached {
            ContentionTrace.finishInteractive(&contentionRequest)
            TextWorkTrace.finish(
                textToken,
                category: .markdownParseHit,
                characters: 0
            )
            if includeSourceSpans {
                return MarkdownParseResult(
                    segments: cached,
                    sourceSpans: MarkdownSegment.parseUncached(
                        key,
                        includeSegments: false,
                        includeSourceSpans: true
                    ).sourceSpans
                )
            }
            return MarkdownParseResult(segments: cached, sourceSpans: [])
        }

        // Parsing is deliberately outside the lock so a slow Markdown decode
        // cannot block unrelated rows or actors using this synchronous seam.
        let parsed = MarkdownSegment.parseUncached(
            key,
            includeSegments: true,
            includeSourceSpans: includeSourceSpans
        )
        let cost = estimateByteCost(for: key, segments: parsed.segments)

        lockStartedAt = contentionRequest == nil
            ? 0
            : DispatchTime.now().uptimeNanoseconds
        let raced: [MarkdownSegment]? = storage.withLock {
            ContentionTrace.recordLockWait(&contentionRequest, startedAt: lockStartedAt)
            if let cached = storage.valueWithoutLock(for: key) {
                return cached
            }
            storage.insertWithoutLock(
                parsed.segments,
                for: key,
                byteCost: cost
            )
            return nil
        }
        ContentionTrace.finishInteractive(&contentionRequest)
        TextWorkTrace.finish(
            textToken,
            category: .markdownParseMiss,
            text: key
        )
        if let raced {
            return MarkdownParseResult(
                segments: raced,
                sourceSpans: includeSourceSpans ? parsed.sourceSpans : []
            )
        }
        return parsed
    }


    private func estimateByteCost(
        for key: String,
        segments: [MarkdownSegment]
    ) -> Int {
        var estimate = key.utf8.count.multipliedReportingOverflow(by: 2).partialValue
        estimate += 128
        for segment in segments {
            estimate += 64
            switch segment {
            case .prose(_, let attributed),
                 .heading(_, _, let attributed),
                 .bullet(_, _, _, let attributed),
                 .numbered(_, _, _, _, let attributed):
                let token = TextWorkTrace.begin()
                let rendered = String(attributed.characters)
                TextWorkTrace.finish(
                    token,
                    category: .stringConversion,
                    text: rendered
                )
                let bytes = rendered.utf8.count
            case .code(_, let language, let body):
                estimate += language.utf8.count.multipliedReportingOverflow(by: 2).partialValue
                estimate += body.utf8.count.multipliedReportingOverflow(by: 2).partialValue
            }
        }
        return max(estimate, 1)
    }
}
