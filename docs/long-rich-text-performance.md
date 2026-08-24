# Long rich-text performance for desktop chat

Research date: 2026-08-24

## 1. Scope and performance constraints

- [Inference] The production fixture contains 12–40 message rows and one 25,000-character Markdown message.
- [Fact] Apple sets less than 100 ms for discrete interaction work and less than one refresh interval for continuous interaction. [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Fact] Apple reports common refresh intervals of 8.3 ms at 120 Hz and 16.7 ms at 60 Hz. [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Fact] Apple says main-thread screen work below 5 ms is usually ready for the next update. [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Inference] These values are measurement thresholds, not a universal 16 ms compliance claim.
- [Measured] cmark parsed an 11 MB Markdown file in 0.29 seconds on a 2 GHz Core 2 Duo. [cmark `benchmarks.md`](https://github.com/swiftlang/swift-cmark/blob/gfm/benchmarks.md)
- [Inference] The cmark result excludes Swift conversion, styling, text layout, view creation, and drawing.
- [Measured] WezTerm reported `render_screen_line` p50 6.50 µs and p95 38.40 µs. [WezTerm discussion 3664](https://github.com/wezterm/wezterm/discussions/3664)
- [Measured] WezTerm reported `shape.harfbuzz` p50 4.10 µs and p95 19.97 µs. [WezTerm discussion 3664](https://github.com/wezterm/wezterm/discussions/3664)
- [Measured] A GPUI profile attributed 5.8% of wheel scrolling and 34% of drag scrolling to `layout_wrapped_line`. [Zed discussion 24260](https://github.com/zed-industries/zed/discussions/24260)

## 2. Block splitting and viewport work

- [Fact] CommonMark parses complete block structure before inline structure because reference definitions need the complete first pass. [CommonMark `Blocks and inlines`](https://github.com/commonmark/commonmark-spec/blob/master/spec.txt#L3410-L3462)
- [Fact] CommonMark permits independent inline parsing after the complete block pass. [CommonMark `Blocks and inlines`](https://github.com/commonmark/commonmark-spec/blob/master/spec.txt#L3449-L3462)
- [Fact] `swift-markdown` uses `cmark-gfm` and exposes immutable, thread-safe, copy-on-write markup values through `Document(parsing:)`. [swift-markdown](https://github.com/swiftlang/swift-markdown)
- [Inference] Parse the complete Markdown message once, then split its top-level parsed blocks.
- [Inference] Keep lists, block quotes, tables, and fenced code blocks intact during block splitting.
- [Inference] Do not parse arbitrary character chunks because references, fences, and containers can cross chunk boundaries.
- [Inference] Treat one oversized code block as a separate failure case because top-level splitting cannot reduce it.
- [Fact] `LazyVStack` creates children only when rendering needs them. [SwiftUI `LazyVStack`](https://developer.apple.com/documentation/swiftui/lazyvstack)
- [Fact] TextKit 2 uses viewport-based, noncontiguous layout through `NSTextViewportLayoutController.viewportBounds`, `viewportRange`, and `layoutViewport()`. [Apple `NSTextViewportLayoutController`](https://developer.apple.com/documentation/appkit/nstextviewportlayoutcontroller)
- [Fact] Apple reports interactive TextKit 2 scrolling for documents containing hundreds of megabytes. [WWDC21 `Meet TextKit 2`](https://developer.apple.com/videos/play/wwdc2021/10061/)
- [Fact] `CTFramesetterCreateFrame` creates a frame, and `CTFrameGetVisibleStringRange` identifies the text that fits. [Apple `CTFrame`](https://developer.apple.com/documentation/coretext/ctframe)
- [Fact] `CTTypesetterSuggestLineBreak` and `CTTypesetterCreateLine` support explicit, incremental line layout. [Apple `CTTypesetter`](https://developer.apple.com/documentation/coretext/cttypesetter)
- [Fact] Chromium represents inline content with `InlineItem`. [Blink `inline_items_builder.h`](https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/core/layout/inline/inline_items_builder.h)
- [Fact] Chromium resumes fragmented child layout through `BlockBreakToken::ChildBreakTokens()`. [Blink block fragmentation tutorial](https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/core/layout/block_fragmentation_tutorial.md)
- [Fact] LayoutNG caches measure and layout passes to reduce the documented example from exponential work to O(n). [LayoutNG deep dive](https://developer.chrome.com/docs/chromium/layoutng)
- [Fact] Chromium identifies a 50–100 ms incremental layout as a likely exponential-layout clue. [LayoutNG deep dive](https://developer.chrome.com/docs/chromium/layoutng)
- [Fact] Qt recommends smaller paragraphs because `QTextDocument` handles them better. [Qt large-file guidance](https://doc.qt.io/qt-6/richtext-advanced-processing.html)
- [Fact] Qt advances lazy layout with `QTextDocumentLayoutPrivate::layoutStep`, `lazyLayoutStepSize`, and `ensureLayoutedByPosition`. [Qt `qtextdocumentlayout.cpp`](https://codebrowser.dev/qt6/qtbase/src/gui/text/qtextdocumentlayout.cpp.html)
- [Fact] Telegram Desktop limits enumeration to visible bounds in `HistoryInner::enumerateItemsInHistory`. [Telegram `history_inner_widget.cpp`](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/history/history_inner_widget.cpp)
- [Fact] Earlier Telegram `ListWidget::enumerateItems` code uses visible item bounds and `kMinimalIdsLimit` is 24. [Telegram source search](https://github.com/telegramdesktop/tdesktop/search?q=kMinimalIdsLimit&type=code)

## 3. Skeleton or plain-text first paint

- [Fact] Apple says to show content or placeholder content as soon as possible. [Human Interface Guidelines `Loading`](https://developer.apple.com/design/human-interface-guidelines/loading)
- [Fact] `RedactionReasons.placeholder` masks supplied content while preserving its size and shape. [SwiftUI `RedactionReasons.placeholder`](https://developer.apple.com/documentation/swiftui/redactionreasons/placeholder)
- [Inference] Show message metadata and plain text before rich-text preparation completes.
- [Inference] Prefer plain text when the source is available because it provides useful content immediately.
- [Inference] Use a skeleton only while actual preparation remains in flight.
- [Inference] Replace the first paint without animation when changed text metrics could move the scroll position.
- [Inference] Preserve the visible message and block anchor during rich-text replacement.

## 4. Safe background preparation and UI handoff

- [Fact] Apple limits the main thread to UI work and directs other work to concurrency facilities. [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Fact] A `Task` created from SwiftUI can inherit `MainActor` and still block UI work. [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Fact] Apple recommends a `nonisolated` asynchronous function or `Task.detached` for synchronous work that must leave `MainActor`. [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Fact] Foundation `AttributedString` conforms to `Sendable`. [Foundation `AttributedString`](https://developer.apple.com/documentation/foundation/attributedstring)
- [Fact] `MainActor.run` executes its closure on the main actor. [Swift `MainActor`](https://developer.apple.com/documentation/swift/mainactor)
- [Fact] `Task.cancel()` uses cooperative cancellation and does not stop arbitrary functions automatically. [Swift `Task.cancel()`](https://developer.apple.com/documentation/swift/task/cancel())
- [Fact] Android documents `PrecomputedText.create` as expensive work suitable for a background thread before UI presentation. [Android `PrecomputedText.create`](https://developer.android.com/reference/android/text/PrecomputedText#create(java.lang.CharSequence,%20android.text.PrecomputedText.Params))
- [Fact] `PrecomputedText.Params.checkResultUsable` returns reuse, recompute, or unusable decisions for changed layout parameters. [AOSP `PrecomputedText.java`](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/text/PrecomputedText.java)
- [Measured] AOSP changed selectable precomputed layout from 17,379,765 to 1,700,146 time units, a 90.2% reduction. [AOSP commit `80ed5a35`](https://android.googlesource.com/platform/frameworks/base/+/80ed5a35a90b62b8070d861b9755e230bd679951)
- [Measured] The same AOSP change made non-selectable precomputed layout 2.5 times slower, while remaining about 10 times faster than no precomputation. [AOSP commit `80ed5a35`](https://android.googlesource.com/platform/frameworks/base/+/80ed5a35a90b62b8070d861b9755e230bd679951)
- [Inference] Return a `Sendable` prepared model containing the message revision and parsed block values.
- [Inference] Check cancellation between parsing, block conversion, and styling stages.
- [Inference] Use `MainActor.run` for one revision-checked state commit and AppKit view updates.
- [Inference] Reject any result whose revision differs from the current message revision.
- [Inference] Bound preparation concurrency instead of creating one unbounded task for every block.

## 5. Cache keys and reusable work

- [Fact] `NSCache` supports concurrent access and can evict transient values when resources become low. [Foundation `NSCache`](https://developer.apple.com/documentation/foundation/nscache)
- [Fact] `NSCache.totalCostLimit` is advisory, and its eviction order is not guaranteed. [Foundation `NSCache.totalCostLimit`](https://developer.apple.com/documentation/foundation/nscache/totalcostlimit)
- [Fact] Swift `Hasher` uses a per-execution seed and must not provide persistent cache keys. [Swift `Hasher`](https://developer.apple.com/documentation/swift/hasher)
- [Fact] `SHA256.hash(data:)` computes a stable content digest. [CryptoKit `SHA256`](https://developer.apple.com/documentation/cryptokit/sha256)
- [Fact] Flutter `Paragraph.layout(ParagraphConstraints)` computes glyph positions for a specified width. [Flutter `Paragraph.layout`](https://api.flutter.dev/flutter/dart-ui/Paragraph/layout.html)
- [Fact] Flutter `TextPainter.layout` reuses `_layoutCache` when `_resizeToFit` accepts the new width bounds. [Flutter `TextPainter.layout`](https://api.flutter.dev/flutter/painting/TextPainter/layout.html)
- [Fact] Zed `LineLayoutCache` keeps current and previous frame generations for line and wrapped-line layouts. [Zed `line_layout.rs`](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/text_system/line_layout.rs)
- [Fact] Zed `layout_wrapped_line` keys include text, font size, runs, wrap width, and maximum lines. [Zed `line_layout.rs`](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/text_system/line_layout.rs)
- [Fact] HarfBuzz `hb_shape_plan_create_cached2` keys shaping work with face, segment properties, features, coordinates, and shaper list. [HarfBuzz `hb-shape.cc`](https://github.com/harfbuzz/harfbuzz/blob/main/src/hb-shape.cc)
- [Fact] WezTerm names `glyph_cache`, `line_quad_cache`, `line_state_cache`, `line_to_ele_shape_cache`, and `shape_cache`. [WezTerm discussion 3664](https://github.com/wezterm/wezterm/discussions/3664)
- [Fact] WezTerm documents larger cache limits as a speed and memory tradeoff. [WezTerm discussion 3664](https://github.com/wezterm/wezterm/discussions/3664)
- [Fact] Alacritty `GlyphCache` supplies glyphs while `TextRenderer::draw_cells` batches visible `RenderableCell` values. [Alacritty `renderer/text/mod.rs`](https://github.com/alacritty/alacritty/blob/master/alacritty/src/renderer/text/mod.rs)
- [Inference] Key the parsed document by source digest, parser dialect, parser options, and renderer version.
- [Inference] Key each prepared block by message revision, block identity, font configuration, scale, appearance, locale, and renderer version.
- [Inference] Add exact width and display scale only to layout-dependent cache keys.
- [Inference] Keep width and appearance out of syntax-tree keys because they do not change Markdown structure.
- [Inference] Keep a bounded document cache and a bounded prepared-block cache with measured cost estimates.

## 6. Failure modes and correctness constraints

- [Fact] `AttributedString.MarkdownParsingOptions.failurePolicy` selects Markdown failure handling. [Foundation `MarkdownParsingOptions`](https://developer.apple.com/documentation/foundation/attributedstring/markdownparsingoptions)
- [Fact] Android rejects `PrecomputedText` reuse when target parameters differ and recomputes layout. [Android `PrecomputedText`](https://developer.android.com/reference/android/text/PrecomputedText)
- [Fact] Qt `QTextDocument.setLayoutEnabled(false)` defers repeated layout during multiple changes. [Qt `QTextDocument`](https://doc.qt.io/qt-6/qtextdocument.html)
- [Fact] Qt `QTextDocument.setMaximumBlockCount` removes old blocks and disables undo history. [Qt `QTextDocument`](https://doc.qt.io/qt-6/qtextdocument.html)
- [Fact] TextKit 2 estimates offscreen geometry, and forcing outside-viewport layout can be expensive. [WWDC21 `Meet TextKit 2`](https://developer.apple.com/videos/play/wwdc2021/10061/)
- [Inference] On parse or style failure, keep plain text and remove any loading placeholder.
- [Inference] Treat cache eviction as a normal miss and retain a complete recomputation path.
- [Inference] Prevent stale background completion with revision checks at the UI handoff.
- [Inference] Prevent width-stale layouts after window resizing by including width in layout keys.
- [Inference] Prevent appearance-stale colors by including appearance or using dynamic system colors.
- [Inference] Prevent scroll jumps by anchoring the visible block before replacing estimated heights.
- [Inference] Prevent a large fenced block from blocking UI work with viewport text layout or bounded line fragments.
- [Inference] Load remote images separately, reserve known dimensions, and cancel work for invisible or revised blocks.

## 7. Memory tradeoffs, production architecture, and validation

- [Fact] Swift `String` uses copy-on-write storage, while mutation can require O(n) time and space. [Swift `String`](https://developer.apple.com/documentation/swift/string)
- [Fact] Core Text `CTRun` exposes glyph, position, advance, and string-index arrays through pointer and copy APIs. [Apple `CTRun`](https://developer.apple.com/documentation/coretext/ctrun)
- [Fact] Skia `ParagraphImpl` retains `fRuns`, `fClusters`, `fLines`, and `fPicture`. [Skia `ParagraphImpl.h`](https://github.com/google/skia/blob/main/modules/skparagraph/src/ParagraphImpl.h)
- [Fact] Skia uses `SkTextBlob` for grouped glyph drawing and checks it in `ParagraphImpl::containsColorFontOrBitmap`. [Skia `ParagraphImpl.h`](https://github.com/google/skia/blob/main/modules/skparagraph/src/ParagraphImpl.h)
- [Inference] Raw source, syntax trees, attributed blocks, line data, and drawing caches can retain overlapping content.
- [Inference] Store source ranges in block descriptors and avoid unnecessary independent block strings.
- [Inference] Cache only recent or visible prepared blocks because the transcript contains few rows but one pathological row.
- [Inference] Prefer one TextKit 2 `NSTextView` when the message needs continuous selection and mostly standard rich text.
- [Inference] Prefer top-level SwiftUI or AppKit block views when code blocks, tables, attachments, or controls need separate interaction.
- [Inference] Start with plain text in the existing message row and schedule one bounded preparation task for the long message.
- [Inference] Parse the complete Markdown source, produce stable top-level block identities, and prepare visible blocks first.
- [Inference] Commit a revision-matched prepared model on `MainActor`, then preserve the visible block anchor.
- [Inference] Keep plain text as the permanent fallback for parsing, cancellation, memory pressure, and unsupported markup.
- [Inference] Measure parse time, preparation time, main-actor commit time, first content time, retained memory, and scroll hitches.
- [Inference] Use the exact 12–40-row and 25,000-character fixture on the minimum supported Mac.
- [Inference] Require first useful content below 100 ms and target main-actor commits below 5 ms.
- [Inference] Record refresh rate and hitch data instead of claiming universal 16 ms compliance.
