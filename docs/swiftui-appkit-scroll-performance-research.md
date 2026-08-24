# SwiftUI and AppKit scrolling performance research

## Scope

This note compares SwiftUI `ScrollView` with `LazyVStack` or `List` against AppKit `NSTableView` and `NSOutlineView` for two macOS workloads:

1. A 50–1000-row chat transcript with variable-height rich text or Markdown, whole-dataset replacement, and initial bottom position.
2. A hierarchical sidebar with folders, multiple selection, drag and drop, and context menus.

## Documented facts

- Apple documents that lazy stacks delay loading contained views until they approach visibility. Apple does not document their backing view type or promise row recycling. [WWDC25, “What’s new in SwiftUI”](https://developer.apple.com/videos/play/wwdc2025/256/)
- Apple documents that an `NSTableView` obtains data from a data source as needed. View-based tables should call `makeView(withIdentifier:owner:)` to reuse an invisible view. [NSTableView](https://developer.apple.com/documentation/appkit/nstableview), [tableView(_:viewFor:row:)](https://developer.apple.com/documentation/appkit/nstableviewdelegate/tableview(_:viewfor:row:))
- AppKit supports automatic row heights through Auto Layout and supports per-row height delegates. Changed heights require invalidation. [usesAutomaticRowHeights](https://developer.apple.com/documentation/appkit/nstableview/usesautomaticrowheights), [NSTableViewDelegate](https://developer.apple.com/documentation/appkit/nstableviewdelegate)
- `reloadData()` requests a full data reload. Outline views also provide item-level reload and insert, remove, and move operations. [NSOutlineView](https://developer.apple.com/documentation/appkit/nsoutlineview)
- Apple documents diffable snapshots as a state representation that can add, delete, move, and reload identified items. Do not assume that every `NSOutlineView` API is diffable; use the outline view’s documented item operations unless a tested adapter exists. [NSDiffableDataSourceSnapshot](https://developer.apple.com/documentation/appkit/nsdiffabledatasourcesnapshot-swift.struct)
- AppKit also documents `NSTableViewDiffableDataSource`. Its snapshot application is a table data-source operation, not an `NSOutlineView` guarantee. [NSTableViewDiffableDataSource](https://developer.apple.com/documentation/appkit/nstableviewdiffabledatasource-c5gl)
- `NSOutlineView` retrieves only data needed for display, preserves expansion state through stable item identity, and provides native disclosure and selection behavior. [NSOutlineView](https://developer.apple.com/documentation/appkit/nsoutlineview), [Navigating Hierarchical Data Using Outline and Split Views](https://developer.apple.com/documentation/appkit/navigating-hierarchical-data-using-outline-and-split-views)
- AppKit exposes table and outline accessibility roles, rows, selected rows, visible rows, disclosure state, and hierarchy level. SwiftUI provides built-in accessibility for common controls, but custom AppKit bridges require explicit accessibility exposure. [NSAccessibilityTable](https://developer.apple.com/documentation/appkit/nsaccessibilitytable), [SwiftUI Accessibility Fundamentals](https://developer.apple.com/documentation/swiftui/accessibility-fundamentals)
- Apple’s AppKit integration guidance says recycled cells should keep one hosting view and update its root SwiftUI view. Hosting views participate in Auto Layout sizing. [WWDC22, “Use SwiftUI with AppKit”](https://developer.apple.com/videos/play/wwdc2022/10075/)
- Apple documents `UIHostingConfiguration` for UIKit cells. Apple does not document an AppKit `NSHostingConfiguration` type. Treat that name as a project or third-party abstraction unless the SDK being used proves otherwise. [UIHostingConfiguration](https://developer.apple.com/documentation/swiftui/uihostingconfiguration), [AppKit integration](https://developer.apple.com/documentation/swiftui/appkit-integration)

## Evidence quality

Apple documents mechanisms, not a ranking between these implementations. A third-party Instruments study measured `VStack`, `LazyVStack`, and `List` with 1,000 complex cells, but it is not an AppKit macOS comparison. [Mobile Vitals, “SwiftUI Scroll Performance”](https://mobile-vitals.com/article/2337-individual-author-swiftui-scroll-performance-the-120fps-challenge)

Other code-backed reports show why results cannot transfer directly: an iPhone 15 Pro test reported 5.53 seconds for `List` and 52.3 seconds for `LazyVStack` to reach 1,000 image-heavy rows, while a macOS report found large debug-build costs for simple 10,000-row lists that largely disappeared in Release. [STRV](https://www.strv.com/blog/swiftui-list-vs-lazyvstack), [TrozWare](https://troz.net/post/2025/swiftui-mac-2025/). Neither compares against `NSTableView`.

Apple’s release notes document estimated variable row heights for view-based `NSTableView` and `NSOutlineView`; AppKit measures rows near the viewport and replaces estimates during scrolling. [macOS 13 AppKit release notes](https://developer.apple.com/documentation/macos-release-notes/appkit-release-notes-for-macos-13). This is documented behavior, not proof that AppKit wins for rich text.

Open-source experiments provide runnable code, but their results are workload- and platform-specific. [Raph Levien’s virtual scrolling comparison](https://gist.github.com/raphlinus/4e4b1937c9ca16edd6a19aac9ba24a30), [SwiftUI macOS List/LazyVStack experiment](https://gist.github.com/xmollv/7ecc97d8118c100e85698c5ff09a20dc). Reports of macOS stutter are anecdotal unless they include the fixture, OS, hardware, build, and Instruments trace.

Therefore, the following are inferences, not guarantees: native AppKit rows can reduce framework work through explicit reuse; one root `NSHostingView` should cost less than one host per row; and dynamic-height Markdown can dominate either container’s cost.

## Recommendation

For the transcript, keep SwiftUI first if 50–1000 rows meet the frame and interaction budgets. Use one root hosting view, stable row identity, cached Markdown results, cached heights keyed by message revision, width, and text size, and bottom anchoring that changes only while the user is already pinned to the bottom. Move to AppKit rows only after profiling shows a failed budget. A per-row hosting view is not the default optimization.

For the sidebar, prefer `NSOutlineView` when the hierarchy is large or native multi-selection, drag and drop, context menus, keyboard navigation, and accessibility are central. Use SwiftUI `List` when the hierarchy is small and cross-platform reuse has higher value. Keep sidebar rows fixed-height where possible.

## Prototype acceptance criteria

Measure Release builds on the oldest supported Mac with 50, 250, 1000 transcript rows and production plus 5× sidebar fixtures. Compare SwiftUI, native AppKit, and AppKit with one reused hosting view per visible row.

- P95 initial visible content: ≤250 ms.
- P95 dataset switch, selection, expansion, and jump-to-bottom action: ≤100 ms.
- No main-thread block over 100 ms.
- No sustained frame interval over 16.7 ms at 60 Hz during scripted scroll and resize.
- Height error ≤1 point, with no clipping, overlap, or layout warnings.
- Updating one streaming message remeasures no unrelated message.
- Off-screen rows create no hosts; host count stays bounded by visible rows plus a fixed buffer.
- Bottom insertion moves the viewport only when pinned.
- VoiceOver reaches every row and reports selection, expansion, hierarchy, and actions correctly.

Instrument host creation, view updates, Markdown parsing, height measurement, row invalidation, dataset replacement, and scroll anchoring. Accept AppKit only when it materially improves these measured criteria without unacceptable accessibility or bridge complexity.
