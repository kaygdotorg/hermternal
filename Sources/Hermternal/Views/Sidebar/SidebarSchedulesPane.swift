import SwiftUI
import HermternalCore

/// Schedules, floating above the chat list and directly over the account row.
///
/// A section inside the chat List cannot own an independent scroll region,
/// and nesting a scroll view inside that List would fight its scrolling, so
/// the schedules rows leave the List and render here instead. The rows still
/// come from `sidebarRows`, which keeps the partition of cron runs from
/// chats in the model where it belongs.
///
/// The pane draws no surface of its own. The chat rows that pass beneath it
/// are dissolved by the list's own content mask, so there is nothing left
/// for a plate to hide.
struct SidebarSchedulesPane: View {
    static let title = "Schedules"

    let rows: [SidebarRow]
    let folders: [Folder]
    let rowMenuDerivations: SidebarRowMenuDerivations
    @Binding var selection: Set<SidebarSelectionID>
    let onOpen: (ChatSession) -> Void
    let onPin: ([ChatSession], Bool) -> Void
    let onArchive: ([ChatSession]) -> Void
    let onRename: (ChatSession) -> Void
    let onCopyDeepLinks: ([ChatSession]) -> Void
    let onPurge: ([String], [String], SessionPurgeActionMode) -> Void
    let purgeAvailable: Bool
    let purgeUnavailableReason: String
    let onMove: ([ChatSession], String?) -> Void

    /// Height of the pane list's own scrollable content, reported by the
    /// scroll geometry. It is the real height of every row plus the list's
    /// own insets, so the pane's height follows the row height instead of
    /// assuming it. Content height does not depend on the frame we derive
    /// from it, so there is no feedback between the two.
    @State private var contentHeight: CGFloat?
    var body: some View {
        return VStack(alignment: .leading, spacing: 0) {
            // The divider that separates the pane from the chat list is
            // owned by the column layout, so the pane draws none of its own.
            HStack(spacing: 4) {
                Text(Self.title)
                // The trailing slot exists already, so opening a full
                // schedules view later needs no relayout here.
                Spacer(minLength: 4)
            }
            .sidebarSectionHeader(topGap: SidebarMetrics.paneHeaderGap)
            .padding(.leading, SidebarMetrics.headerLeadingInset)
            .padding(.trailing, SidebarMetrics.headerTrailingInset)
            List(selection: $selection) {
                ForEach(rows) { row in
                    SessionRowItem(
                        session: row.session,
                        folders: folders,
                        menu: rowMenuDerivations.sessionByItem[
                            .chat(row.sessionID)
                        ]!,
                        onOpen: onOpen,
                        onPin: onPin,
                        onArchive: onArchive,
                        onRename: onRename,
                        onCopyDeepLinks: onCopyDeepLinks,
                        onPurge: onPurge,
                        purgeAvailable: purgeAvailable,
                        purgeUnavailableReason: purgeUnavailableReason,
                        onMove: onMove
                    )
                    .tag(SidebarSelectionID.chat(row.sessionID))
                    .selectionDisabled(false)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // One measurement for the whole pane rather than one reader per
            // row, and no row is wrapped in a conditional branch.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, height in
                guard height > 0, contentHeight != height else { return }
                contentHeight = height
            }
            // A List is greedy, so the pane must always carry a height. The
            // unmeasured first pass gets 1pt, which still lets the list
            // report its content height, and stays invisible.
            .frame(height: paneHeight ?? 1)
            .opacity(paneHeight == nil ? 0 : 1)
        }
    }

    /// The content height for up to three rows: the whole content when there
    /// are three or fewer, and three rows' share of it when there are more.
    private var paneHeight: CGFloat? {
        guard let contentHeight, !rows.isEmpty else { return nil }
        let visible = min(CGFloat(rows.count), SidebarMetrics.visibleScheduleRows)
        return contentHeight * visible / CGFloat(rows.count)
    }
}
