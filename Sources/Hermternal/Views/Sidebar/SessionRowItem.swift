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

struct SidebarSessionMenuDerivation {
    let chats: [ChatSession]
    let moveChats: [ChatSession]
    let folderIDs: [String]
    let pinAction: SidebarPinAction?
    let disabledFolderIDs: Set<String>
    let hasFolderMembership: Bool
}

struct SessionRowItem: View {
    let session: ChatSession
    let folders: [Folder]
    let menu: SidebarSessionMenuDerivation
    let isSelected: Bool
    let onOpen: (ChatSession) -> Void
    let onPin: ([ChatSession], Bool) -> Void
    let onArchive: ([ChatSession]) -> Void
    let onRename: (ChatSession) -> Void
    let onCopyDeepLinks: ([ChatSession]) -> Void
    let onPurge: ([String], [String], SessionPurgeActionMode) -> Void
    let purgeAvailable: Bool
    let purgeUnavailableReason: String
    let onMove: ([ChatSession], String?) -> Void
    @Environment(\.hermternalAccentColor) private var accentColor
}


extension SessionRowItem {


    var body: some View {
        let _ = HermternalSelectionOccupancyTrace.sessionRowBodyEvaluated()
        return rowContent
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                pinButton
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                archiveButton
            }
            .contextMenu {
                contextMenu
            }
    }

    /// List owns primary clicks for rows that are not selected.
    ///
    /// Only the selected row needs a tap recognizer because List does not
    /// publish a selection change when the user activates it again.
    @ViewBuilder
    private var rowContent: some View {
        let content = SessionRow(session: session)
            .accessibilityLabel(session.displayTitle)
            .accessibilityValue(sessionRowDetail(session))
            .accessibilityIdentifier("session-row-\(session.id)")
            .accessibilityAction {
                HermternalSwitchTrace.session(
                    "selection.observed.accessibility",
                    id: session.id,
                    messages: session.messageCount
                )
                onOpen(session)
            }
        if isSelected {
            content.modifier(
                SessionRowTapModifier(
                    session: session,
                    onOpen: onOpen
                )
            )
        } else {
            content
        }
    }



    @ViewBuilder
    private var contextMenu: some View {
        let chats = menu.chats
        let folderIDs = menu.folderIDs
        let chatNoun = chats.count == 1 ? "Chat" : "Chats"
        let linkNoun = chats.count == 1 ? "Link" : "Links"
        let folderPhrase: String? = if folderIDs.isEmpty {
            nil
        } else if folderIDs.count == 1 {
            "Folder"
        } else {
            "\(folderIDs.count) Folders"
        }
        let chatScope = "\(chats.count) \(chatNoun)"
            + (folderPhrase.map { " in \($0)" } ?? "")
        let linkScope = folderPhrase.map {
            "\(chats.count) Deep \(linkNoun) in \($0)"
        } ?? "\(chats.count) Deep \(linkNoun)"
        if let action = menu.pinAction {
            Button(
                action == .pin ? "Pin \(chatScope)" : "Unpin \(chatScope)",
                systemImage: action == .pin ? "pin" : "pin.slash"
            ) {
                onPin(chats, action == .pin)
            }
        }
        Button("Archive \(chatScope)", systemImage: "archivebox") {
            onArchive(chats)
        }
        Button("Copy \(linkScope)", systemImage: "link") {
            onCopyDeepLinks(chats)
        }
        if !folderIDs.isEmpty {
            Button(
                folderIDs.count == 1
                    ? "Permanently Delete Folder and Chats…"
                    : "Permanently Delete \(folderIDs.count) Folders and Chats…",
                systemImage: "trash.fill",
                role: .destructive
            ) {
                onPurge(chats.map(\.id), folderIDs, .foldersAndChats)
            }
            .disabled(!purgeAvailable)
            .help(
                purgeAvailable
                    ? "Permanently delete all chats inside \(folderPhrase!)"
                    : purgeUnavailableReason
            )
        } else {
            Button(
                "Permanently Delete \(chats.count) \(chatNoun)…",
                systemImage: "trash.fill",
                role: .destructive
            ) {
                onPurge(chats.map(\.id), [], .chatsOnly)
            }
            .disabled(!purgeAvailable)
            .help(purgeAvailable ? "Permanently delete \(chats.count) \(chatNoun)" : purgeUnavailableReason)
        }
        if !menu.moveChats.isEmpty {
            moveMenu(menu.moveChats, folderCount: folderIDs.count)
        }
        Divider()
        Button("Rename", systemImage: "pencil") {
            if chats.count == 1, let chat = chats.first { onRename(chat) }
        }
        .disabled(chats.count != 1)
    }
    @ViewBuilder
    private func moveMenu(_ chats: [ChatSession], folderCount: Int) -> some View {
        let noun = chats.count == 1 ? "Chat" : "Chats"
        let folderPhrase: String? = if folderCount == 0 {
            nil
        } else if folderCount == 1 {
            "Folder"
        } else {
            "\(folderCount) Folders"
        }
        let scope = "\(chats.count) \(noun)"
            + (folderPhrase.map { " in \($0)" } ?? "")
        Menu("Move \(scope) to Folder", systemImage: "folder") {
            if folders.isEmpty {
                Button("No Folders Yet") {}.disabled(true)
            } else {
                ForEach(folders) { folder in
                    Button(folder.name) {
                        onMove(chats, folder.id)
                    }
                    .disabled(menu.disabledFolderIDs.contains(folder.id))
                }
            }
            if menu.hasFolderMembership {
                Divider()
                Button("Remove from Folder", systemImage: "folder.badge.minus") {
                    onMove(chats, nil)
                }
            }
        }
    }

    private var pinButton: some View {
        Button(
            session.pinned ? "Unpin" : "Pin",
            systemImage: session.pinned ? "pin.slash" : "pin"
        ) {
            onPin([session], !session.pinned)
        }
        .tint(accentColor)
    }

    private var archiveButton: some View {
        Button("Archive", systemImage: "archivebox") {
            onArchive([session])
        }
        .tint(accentColor)
    }

}

/// Reopens the selected row without intercepting native selection.
private struct SessionRowTapModifier: ViewModifier {
    let session: ChatSession
    let onOpen: (ChatSession) -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            TapGesture(count: 1)
                .onEnded {
                    let allowed =
                        SidebarSelectionEventAdapter.allowsCompletedTapActivation()
                    HermternalSwitchTrace.session(
                        "selection.tapGate",
                        id: session.id,
                        messages: session.messageCount,
                        detail: allowed ? "allowed" : "blocked"
                    )
                    guard allowed else {
                        HermternalSwitchTrace.selectionGuard(
                            "sessionRow.tapGate",
                            id: session.id,
                            messages: session.messageCount,
                            reason: "contextOrModifiedClick"
                        )
                        return
                    }
                    HermternalSwitchTrace.session(
                        "selection.observed.pointer",
                        id: session.id,
                        messages: session.messageCount
                    )
                    onOpen(session)
                }
        )
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .font(.body)
        .help(title)
    }
}
