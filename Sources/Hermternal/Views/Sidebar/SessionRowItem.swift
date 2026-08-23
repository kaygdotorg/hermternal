import SwiftUI
import HermternalCore

/// One glyph for each known `source`. A file-scope table is built once, so a
/// row body does a hash lookup and never rebuilds a mapping.
private let sessionSourceGlyphs: [String: String] = [
    "subagent": "arrow.triangle.branch",
    "tool": "wrench.adjustable",
    "desktop": "desktopcomputer",
    "tui": "terminal",
    "cli": "chevron.left.forwardslash.chevron.right",
    "cron": "clock",
    "api_server": "server.rack",
    "photon": "bolt",
    "matrix": "number",
]

/// The glyph for a `source` value that the table does not know.
private let sessionFallbackGlyph = "bubble.left"

/// Hoisted out of the row body, because a per-row format style is per-row work.
private let sessionRelativeStyle = Date.RelativeFormatStyle(presentation: .named)

/// Spoken detail for a row. The row shows the title only, so the value keeps the
/// message count and the last-active time available to a screen reader. `Text`
/// holds the count and the date and formats them when accessibility reads the
/// row, so the row body itself does no string work.
private func sessionRowDetail(_ session: ChatSession) -> Text {
    let count = session.messageCount
    let countText: Text? = switch count {
    case ..<1: nil
    case 1: Text("1 message")
    default: Text("\(count) messages")
    }
    guard let timestamp = session.lastActive ?? session.startedAt else {
        return countText ?? Text(verbatim: "")
    }
    let timeText = Text(timestamp, format: sessionRelativeStyle)
    guard let countText else { return timeText }
    return countText + Text(verbatim: ", ") + timeText
}

struct SessionRowItem: View {
    let session: ChatSession
    let folders: [Folder]
    let currentFolderID: String?
    let onMoveToFolder: (ChatSession, String?) -> Void
    let onOpen: (ChatSession) -> Void
    let onPin: (ChatSession) -> Void
    let onArchive: (ChatSession) -> Void
    let onRename: (ChatSession) -> Void
    let onCopyDeepLink: (ChatSession) -> Void
    var body: some View {
        Button {
            onOpen(session)
        } label: {
            SessionRow(session: session)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.displayTitle)
        .accessibilityValue(sessionRowDetail(session))
        .accessibilityIdentifier("session-row-\(session.id)")
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            pinButton(for: session)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            archiveButton(for: session)
        }
        // A per-row menu keeps the action tied to this row without
        // changing List selection.
        .contextMenu {
            pinButton(for: session)
            archiveButton(for: session)
            renameButton(for: session)
            copyDeepLinkButton(for: session)
            MoveToFolderMenu(
                session: session,
                folders: folders,
                currentFolderID: currentFolderID,
                onMove: onMoveToFolder
            )
        }
    }

    @ViewBuilder
    private func pinButton(for session: ChatSession) -> some View {
        Button(
            session.pinned ? "Unpin" : "Pin",
            systemImage: session.pinned ? "pin.slash" : "pin"
        ) {
            onPin(session)
        }
        .tint(.accentColor)
    }

    @ViewBuilder
    private func archiveButton(for session: ChatSession) -> some View {
        Button("Archive", systemImage: "archivebox") {
            onArchive(session)
        }
        .tint(.accentColor)
    }

    @ViewBuilder
    private func copyDeepLinkButton(for session: ChatSession) -> some View {
        Button("Copy deep link", systemImage: "link") {
            onCopyDeepLink(session)
        }
    }

    @ViewBuilder
    private func renameButton(for session: ChatSession) -> some View {
        Button("Rename", systemImage: "pencil") {
            onRename(session)
        }
    }
}

private struct SessionRow: View {
    let session: ChatSession

    var body: some View {
        // `displayTitle` is stored on the session, so reading it costs nothing.
        let title = session.displayTitle
        // `Label` is the system sidebar row layout. It aligns the glyph column
        // and the title without a wrapper view and without hand-drawn geometry.
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            // The glyph takes the row's own foreground and adds no style of
            // its own: primary on an unselected row, the selection's content
            // colour on the accent plate, the inactive label colour when the
            // window is not key. `.secondary` was a step below all three, and
            // a 13pt stroked symbol carries so little ink that the step is the
            // first thing the translucent sidebar swallows. Measured at true
            // 2x, `.secondary` held 4.5:1 against a settled backdrop where the
            // title held 9:1, and lost more than that once the window frost
            // let the desktop through. The glyph stays subordinate because it
            // is a thin outline beside dense text, not because it is dimmer.
            //
            // The rendering mode is explicit because the table holds
            // multi-layer symbols. Left to context, those can resolve
            // hierarchically and draw their own lower layers at a further
            // reduced level, which costs the mark most of its ink.
            Image(systemName: sessionSourceGlyphs[session.source] ?? sessionFallbackGlyph)
                .symbolRenderingMode(.monochrome)
        }
        .font(.body)
        .help(title)
    }
}
