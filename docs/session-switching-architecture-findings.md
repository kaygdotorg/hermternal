# Transcript Architecture Research

Date: 2026-08-24

This note separates documented source facts from design inferences. The sources are primary documentation, source code, or benchmark papers.

## Executive finding

Use SQLite as the durable source of truth. Use a composite index for conversation order. Read a bounded window on a database worker. Use `List` or `LazyVStack` for viewport-limited view creation. Keep decoded and parsed data in a bounded memory cache. Treat layout height as a width- and style-dependent derived value.

Do not treat a synchronous database API as permission to block the UI actor. Do not persist one height value per message without the inputs that affect layout. Do not parse Markdown from every declarative view rebuild.

## Documented facts and implications

### SQLite index and last-N reads

**Documented fact.** SQLite says a multi-column index orders by the left-most column, then uses later columns to break ties. Source: [SQLite Query Planning, multi-column indices](https://www.sqlite.org/queryplanner.html).

**Documented fact.** SQLite can use an index for `ORDER BY`. It can search on an equality-constrained left-most column, scan the matching range in order, and scan in reverse for descending order. Source: [SQLite Query Planning, searching and sorting](https://www.sqlite.org/queryplanner.html).

**Inference.** A useful message query is:

```sql
SELECT id, conversation_id, timestamp, markdown_source
FROM message
WHERE conversation_id = ?
ORDER BY timestamp DESC, id DESC
LIMIT ?;
```

Use an index such as `(conversation_id, timestamp DESC, id DESC)`. The `id` tie-breaker makes equal timestamps deterministic. Confirm the selected plan with `EXPLAIN QUERY PLAN` on the target schema.

**Documented fact.** SQLite documents keyset scrolling as more efficient than `OFFSET`. `LIMIT x OFFSET y` computes `x+y` rows and discards the first `y`; a row-value predicate can seek from the previous key. Source: [SQLite Row Values, scrolling window queries](https://sqlite.org/rowvalue.html): “OFFSET requires time proportional to the offset value.” The example uses `WHERE (lastname,firstname) > (?1,?2) ... LIMIT 7` and says it is “much more efficiently than OFFSET” with an appropriate index.

**Documented fact.** A covering index can avoid table lookups. SQLite states that adding output columns to an index can “cut the number of binary searches for a query in half,” described as “roughly a doubling of the speed.” Source: [SQLite Query Planning, covering indexes](https://www.sqlite.org/queryplanner.html). This is a constant-factor example, not a promise for transcript workloads.

**Documented fact.** `sqlite3_step()` evaluates a prepared statement and returns `SQLITE_ROW` each time another row is ready. Source: [SQLite C API, sqlite3_step](https://www.sqlite.org/c3ref/step.html).

**Inference.** A synchronous last-N repository method is reasonable when it runs on a database actor or serial worker and has a bounded `LIMIT`. The method must not run on the main UI actor because SQLite work, page faults, lock waits, and decoding can still block.

**Documented fact.** SQLite WAL allows readers and a writer to run at the same time, but “there can only be one writer at a time.” SQLite also states that read performance deteriorates as the WAL grows. The default automatic checkpoint runs when the WAL exceeds 1000 pages. Source: [SQLite Write-Ahead Logging](https://www.sqlite.org/wal.html).

**Inference.** Batch transcript writes in one transaction. Monitor WAL growth and checkpoint behavior. Do not assume WAL removes write contention.

### Windowed and virtualized lists

**Documented fact.** SwiftUI `List` views “load rows as needed” and add scrolling when rows do not fit. Source: [Apple, displaying data in lists](https://developer.apple.com/documentation/swiftui/displaying-data-in-lists).

**Documented fact.** SwiftUI `LazyVStack` creates items only as needed and “doesn’t create items until it needs to render them onscreen.” Source: [Apple, LazyVStack](https://developer.apple.com/documentation/swiftui/lazyvstack).

**Documented fact.** TextKit 2 defines an active viewport. Apple says the viewport is usually the visible area plus an over-scroll region, and the framework lays out text fragments inside that active area. Source: [Apple, NSTextViewportLayoutController](https://developer.apple.com/documentation/uikit/nstextviewportlayoutcontroller).

**Documented fact.** A study of list virtualization describes these measured or claimed system effects: fewer active elements, reduced rendering work, fewer re-renders and reconciliation operations, faster initial load, and lower memory use. Source: [List Virtualization thesis, pages 13–14](https://umu.diva-portal.org/smash/get/diva2%3A1975265/FULLTEXT01.pdf), lines 298–308. This source studies web lists, not SwiftUI.

**Inference.** Window the data source and virtualize the row views independently. A database window limits decoded data. A lazy list limits active views. Neither mechanism alone guarantees low memory if the application retains every decoded transcript.

### Immutable declarative list rebuilds

**Documented fact.** SwiftUI reads a view’s computed `body` whenever it needs an update. Apple says this can happen repeatedly and “might involve reinitializing your entire view,” while SwiftUI manages the update. Source: [Apple, declaring a custom view](https://developer.apple.com/documentation/swiftui/declaring-a-custom-view).

**Documented fact.** SwiftUI requires unique list member identity. Apple says stable identifiers let SwiftUI generate animations for inserts, deletes, and moves. Source: [Apple, displaying data in lists](https://developer.apple.com/documentation/swiftui/displaying-data-in-lists).

**Documented fact.** SwiftUI creates a `StateObject` once for the lifetime of its declaring view container. Source: [Apple, StateObject](https://developer.apple.com/documentation/swiftui/stateobject).

**Inference.** Rebuilding an immutable row snapshot is compatible with SwiftUI. Stable message IDs must remain constant across snapshots. The snapshot rebuild must not perform Markdown parsing, syntax highlighting, image decoding, or text measurement in `body`.

**Inference.** A new value-tree description is not evidence that every native row is recreated or laid out. Apple documents framework-managed updates and lazy row loading, but it does not document the exact internal diff or reuse policy for every platform and OS release. Measure the target macOS release if row identity or layout cost matters.

### Synchronous reads and retaining decoded transcripts

**Documented fact.** SQLite's default threading mode is serialized. In serialized mode, SQLite can safely serialize access to a connection and its statements. Source: [SQLite threading modes](https://www.sqlite.org/threadsafe.html).

**Documented fact.** `NSCache` is intended for transient values that are expensive to create. It has automatic eviction policies and supports concurrent add, remove, and query operations without application locking. Source: [Apple, NSCache](https://developer.apple.com/documentation/foundation/nscache).

**Inference.** Retain decoded transcripts in a bounded cache keyed by conversation ID and content revision. Prefer `NSCache` or an equivalent bounded cache. Treat eviction as normal and make re-decoding correct. Do not retain every decoded transcript strongly for the process lifetime.

### Write-time rich-text parsing and height persistence

**Documented fact.** Foundation's `AttributedString(markdown:)` creates an attributed string by parsing Markdown. Source: [Apple, AttributedString](https://developer.apple.com/documentation/foundation/attributedstring) and [the Markdown initializer](https://developer.apple.com/documentation/foundation/attributedstring/init%28markdown%3Aincluding%3Aoptions%3Abaseurl%3A%29-4m51b).

**Documented fact.** AppKit `NSLayoutManager` maps characters to glyphs, lays glyphs into text containers, and provides bounding rectangles. Source: [Apple, NSLayoutManager](https://developer.apple.com/documentation/appkit/nslayoutmanager). SwiftUI custom layouts also provide an explicit cache associated with a layout instance. Source: [Apple, Layout](https://developer.apple.com/documentation/swiftui/layout).

**Inference.** Persist the Markdown source as the canonical value. Parse it once per content revision, then retain a derived parse result in memory. Write-time parsing is appropriate on a background import or persistence worker when the parser and renderer are stable. It is risky on the UI send path for large or adversarial input.

**Inference.** Persist height only as a derived cache record keyed by at least `(message_id, content_revision, width, dynamic_type_or_font_revision, display_scale, renderer_revision)`. A height value is invalid after a width, font, scale, style, parser, or layout-engine change. Keep a measured in-memory height cache for the active window and persist only stable, useful values.

**Documented fact.** Apple's TextKit viewport sample explains that text views normally discard and recreate attachment views when they leave the viewport. It provides reuse policies to preserve them across scrolling and edits. Source: [Apple, managing viewport layout and attachment reuse](https://developer.apple.com/documentation/uikit/managing-viewport-layout-and-attachment-reuse-in-a-text-view-subclass).

**Inference.** Treat decoded rich-text objects and layout objects as disposable derived state. Persist portable inputs and versioned results, not opaque framework objects, unless the serialization format and compatibility policy are explicit.

### Markdown reparsing and incremental derived state

**Documented fact.** The Swift Markdown source package describes its tree as “immutable/persistent, thread-safe, copy-on-write value types that only copy substructure that has changed.” Source: [swiftlang/swift-markdown README](https://github.com/swiftlang/swift-markdown).

**Documented fact.** Its source code documents `subtreeCount` as `O(1)`, `range` and `root` as `O(height)`, and `hasSameStructure` as `O(subtreeCount)`. Source: [swift-markdown Markup.swift](https://github.com/swiftlang/swift-markdown/blob/main/Sources/Markdown/Base/Markup.swift).

**Benchmark fact.** The cmark benchmark uses an 11 MB Markdown input, reports a median of ten runs, and reports cmark at 0.33 seconds on an “ancient Thinkpad” with a 2 GHz Core 2 Duo. Source: [swift-cmark benchmarks](https://fuchsia.googlesource.com/third_party/swift-cmark/%2Bshow/1193050109dee6be85c82bd29a1c817532dde912/benchmarks.md), lines 7–35. The result is old and parser-specific.

**Benchmark-paper fact.** Li, Liu, and Meng analyzed 49 known Markdown performance bugs and report 216 new performance bugs across real-world Markdown compilers and applications. They identify context-sensitive features and backtracking as dominant causes. Source: [Understanding and Detecting Performance Bugs in Markdown Compilers](https://www.cse.cuhk.edu.hk/~wei/papers/ase21_mdperffuzz.pdf), pages 1–2.

**Benchmark-paper fact.** The Typst incremental compilation thesis measured incremental parsing speedups of 3.72–19.73 times, layout-cache speedups of 4.80–83.96 times, and combined speedups of 4.56–80 times. Source: [Fast Typesetting with Incremental Compilation](https://doi.org/10.13140/RG.2.2.15606.88642), pages 73–74.

**Inference.** Do not reparse unchanged Markdown during every list rebuild or scroll event. Cache by source revision and parser configuration. Use incremental parsing only if profiling shows that message edits or streaming updates make full reparsing expensive; the cited Typst numbers are not direct measurements of Swift Markdown or SwiftUI.

## Recommended shape

1. Store canonical message source and immutable metadata in SQLite.
2. Index `(conversation_id, timestamp DESC, message_id DESC)`.
3. Use bounded last-N reads and keyset pagination for older messages.
4. Run synchronous repository calls on a database actor or serial worker.
5. Publish immutable transcript snapshots with stable message IDs.
6. Use `List` or `LazyVStack` for row virtualization.
7. Cache decoded transcripts with a bounded eviction policy.
8. Cache parsed Markdown by content revision and parser configuration.
9. Cache layout height by message, content revision, width, style, scale, and renderer revision.
10. Measure query plans, parse time, decode time, layout time, memory, and scroll frame rate on the target macOS release.

## Important limits

The sources do not prove that one exact schema or cache policy is optimal for this application. SQLite's planner is cost-based, SwiftUI's internal reuse behavior is not fully documented, and the benchmark results depend on hardware, OS, parser, input, and cache state.
