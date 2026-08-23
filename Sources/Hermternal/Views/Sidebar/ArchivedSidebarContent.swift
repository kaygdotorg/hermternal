import SwiftUI
import HermternalCore

/// Every row in this mode is archived, so the glyph column carries one fixed
/// symbol instead of the per-source table the Chats mode uses. That keeps the
/// glyph column at the same width in both modes, so switching modes does not
/// move the row titles sideways, and it states the row's state for anyone
/// reading the sidebar rather than its header.
private let archivedRowGlyph = "archivebox"

/// The visible recency, abbreviated because it shares one narrow line with the
/// title. Hoisted to file scope, so a row body never builds a format style.
private let archivedRecencyStyle = Date.RelativeFormatStyle(
    presentation: .numeric,
    unitsStyle: .abbreviated
)

/// The spoken recency. Abbreviations read badly aloud, so the spoken form uses
/// the named presentation while the visible label stays short.
private let archivedSpokenStyle = Date.RelativeFormatStyle(presentation: .named)

/// Spoken detail for an archived row: its state first, then when it was last
/// active. `Text` holds the date and formats it only when accessibility reads
/// the row, so the row body itself does no string work.
private func archivedRowDetail(_ session: ChatSession) -> Text {
    let archived = Text("Archived")
    guard let timestamp = session.lastActive ?? session.startedAt else {
        return archived
    }
    return archived + Text(verbatim: ", ") + Text(timestamp, format: archivedSpokenStyle)
}

/// The whole sidebar list in Archived Chats mode, as content for a `List`
/// rather than as a list, a sheet or a window of its own.
///
/// REQUIRED HOST: this content belongs in the archived mode's own
/// `List(selection: $archivedSelection)`, whose selection is `Set<String>` of
/// chat ids. The rows tag `session.id`, so embedding them in the Chats mode
/// `List` that selects `SidebarSelectionID` would produce tags of the wrong
/// type and silently break selection in both modes. The two modes are two
/// lists, not two sections of one list.
///
/// The mode holds archived chats only: no pinned run, no folders, no date
/// buckets and no schedules. That is why selection is a set of chat ids and
/// not a `SidebarSelectionID` set, and why the rows carry no move, pin,
/// rename or archive command. Restore and the deep link are the only two
/// things an archived chat can do, and both come from this file.
///
/// Loading, emptiness and failure are rows, not replacement states. A refresh
/// that fails while chats are already on screen must not hide them, so the
/// failure is announced above the list it could not renew.
struct ArchivedSidebarContent: View {
    /// The header title, exposed so the mode's menu item and this header
    /// cannot drift apart.
    static let title = "Archived"

    let sessions: [ChatSession]
    /// Owned by the host `List`, which writes the user's selection through it.
    @Binding var selection: Set<String>
    let isLoading: Bool
    let errorMessage: String?
    let onOpen: (ChatSession) -> Void
    let onRefresh: () -> Void
    let onRestore: ([ChatSession]) -> Void
    let onCopyDeepLinks: ([ChatSession]) -> Void
    let canPurge: Bool
    let purgeUnavailableReason: String
    let onPurge: ([String]) -> Void

    var body: some View {
        Section {
            content
        } header: {
            header
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            failureRow(errorMessage)
        }
        ForEach(sessions) { session in
            ArchivedSidebarRow(session: session, onOpen: onOpen)
                .tag(session.id)
                .selectionDisabled(false)
                // A per-row menu keeps the command tied to the clicked row
                // without changing List selection.
                .contextMenu {
                    commands(for: session)
                }
        }
        if sessions.isEmpty, errorMessage == nil {
            statusRow
        }
    }

    /// What an empty archive says. The header already names the mode, so the
    /// hint says what will appear here rather than repeating "archived".
    ///
    /// The in-flight case carries no progress view of its own: the header slot
    /// holds the only one, and one operation must not show two indicators.
    private var statusRow: some View {
        Text(isLoading ? "Loading archived chats…" : "Archived chats will appear here.")
            .font(.callout)
            .italic()
            .foregroundStyle(.secondary)
            .selectionDisabled()
    }

    /// Names the failure, shows what the gateway said, and keeps a refresh
    /// within reach of the message itself as well as in the header.
    @ViewBuilder
    private func failureRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Archived chats unavailable", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                // The sidebar is narrow, so the message wraps rather than
                // truncating the one sentence that explains the failure.
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again", action: onRefresh)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isLoading)
        }
        .padding(.vertical, 4)
        .selectionDisabled()
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    /// A section header that names the mode and holds the refresh control.
    ///
    /// It has no disclosure caret, unlike the Chats mode headers: this is the
    /// only section in the mode, so collapsing it would leave the sidebar
    /// empty with no way back.
    private var header: some View {
        HStack(spacing: SidebarMetrics.headerControlGap) {
            Text(Self.title)
            Spacer(minLength: 4)
            refreshControl
        }
        .sidebarSectionHeader()
        .padding(.trailing, SidebarMetrics.headerTrailingInset)
    }

    /// The refresh control, replaced by the one progress view in the mode
    /// while a load is actually in flight. The indicator tracks real work, and
    /// it stands where the control it replaces stood, so nothing moves.
    @ViewBuilder
    private var refreshControl: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading archived chats")
        } else {
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Refresh archived chats")
            .help("Refresh")
        }
    }

    // MARK: - Commands

    /// Restore and the deep link, over the rows the click applies to.
    ///
    /// The menu is built when it opens, not on a body pass, so counting the
    /// targets here costs nothing per row.
    @ViewBuilder
    private func commands(for clicked: ChatSession) -> some View {
        let targets = contextTargets(clicked: clicked)
        Button(restoreLabel(count: targets.count), systemImage: "tray.and.arrow.up") {
            onRestore(targets)
        }
        Button(copyLabel(count: targets.count), systemImage: "link") {
            onCopyDeepLinks(targets)
        }
        Button("Delete Chats Permanently", systemImage: "trash.fill", role: .destructive) {
            onPurge(targets.map(\.id))
        }
        .disabled(!canPurge)
        .help(canPurge ? "Permanently delete selected chats" : purgeUnavailableReason)
    }

    /// The same rule as `SidebarSelectionPolicy.contextTargets`, expressed on
    /// chat ids because this mode holds no folders: a click on a selected row
    /// applies to the whole selection, and a click on any other row applies to
    /// that row alone without changing the selection.
    ///
    /// `sessions` is already in visible order, so the result is too. The single
    /// target case returns before the scan, which is the common case.
    private func contextTargets(clicked: ChatSession) -> [ChatSession] {
        guard selection.count > 1, selection.contains(clicked.id) else {
            return [clicked]
        }
        return sessions.filter { selection.contains($0.id) }
    }

    /// Title case and an always-present count, which is the Chats mode menu
    /// vocabulary for a command over a selection. The noun agrees with the
    /// count, so a single target never reads as a plural.
    private func restoreLabel(count: Int) -> String {
        count == 1 ? "Restore 1 Chat" : "Restore \(count) Chats"
    }

    private func copyLabel(count: Int) -> String {
        count == 1 ? "Copy 1 Deep Link" : "Copy \(count) Deep Links"
    }
}

/// One archived chat: its glyph, its title, and when it was last active.
///
/// The row surface is owned by the host `List`; accessibility activation is
/// explicit because there is no row Button to consume native selection.
private struct ArchivedSidebarRow: View {
    let session: ChatSession
    let onOpen: (ChatSession) -> Void

    var body: some View {
        label
            .accessibilityLabel(session.displayTitle)
            .accessibilityValue(archivedRowDetail(session))
            .accessibilityIdentifier("archived-row-\(session.id)")
            .accessibilityAction {
                onOpen(session)
            }
    }

    @ViewBuilder
    private var label: some View {
        // `displayTitle` is stored on the session, so reading it costs nothing.
        let title = session.displayTitle
        // No explicit spacing: the platform's own value separates the title
        // from the date. A header metric would be the wrong vocabulary here,
        // and a literal would be a number with nothing behind it.
        HStack {
            // `Label` is the system sidebar row layout. It aligns the glyph
            // column and the title without a wrapper view and without
            // hand-drawn geometry.
            Label {
                Text(title)
                    .lineLimit(1)
            } icon: {
                // Same contract as a chat row's glyph: it takes the row's own
                // foreground rather than a weaker step, so it survives the
                // translucent sidebar and the selection plate alike, and the
                // rendering mode is explicit rather than inferred from
                // context. The date beside it stays `.secondary`, because
                // dense text can afford the step and an outline mark cannot.
                Image(systemName: archivedRowGlyph)
                    .symbolRenderingMode(.monochrome)
            }
            Spacer(minLength: 4)
            if let timestamp = session.lastActive ?? session.startedAt {
                // `Text` holds the date and the hoisted style and formats them
                // at draw time, so the row body allocates no string. Fixed in
                // size, so a long title truncates and the date never does.
                Text(timestamp, format: archivedRecencyStyle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .font(.body)
        .help(title)
    }
}
