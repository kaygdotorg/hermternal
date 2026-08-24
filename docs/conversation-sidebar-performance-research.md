# Conversation Sidebar Performance Research

Primary-source notes for the conversation-sidebar and message-pane question.

- Zed GPUI uses `uniform_list` for fixed-height rows and `list` for measured variable-height rows: https://github.com/zed-industries/zed/blob/main/crates/gpui/src/elements/uniform_list.rs and https://github.com/zed-industries/zed/blob/main/crates/gpui/src/elements/list.rs
- GPUI documents stateless window redraw and frame scheduling: https://zed.dev/blog/zed-weekly-23 and https://zed.dev/blog/120fps
- VS Code `ListView` renders only viewport elements, reuses rows through `RowCache`, and tracks estimated or measured heights: https://github.com/microsoft/vscode/blob/main/src/vs/base/browser/ui/list/listView.ts and https://github.com/microsoft/vscode/blob/main/src/vs/base/browser/ui/list/rowCache.ts
- VS Code reports `524 ms` versus `2.990 ms` for its 20,000-problem tree population case, with `48x` speedup for collapse-all: https://github.com/microsoft/vscode/wiki/Lists-And-Trees
- Apple documents that eager stacks load all child views, while lazy stacks load visible views on demand: https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks
- Qt documents `uniformItemSizes` as a large-list optimization: https://doc.qt.io/qt-6/qlistview.html
