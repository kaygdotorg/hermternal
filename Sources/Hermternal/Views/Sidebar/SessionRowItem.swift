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
    let membership: [String: String]
    let contextChats: [ChatSession]
    let selection: Set<SidebarSelectionID>
    let scheduledIDs: Set<String>
    let onOpen: (ChatSession) -> Void
    let onPin: ([ChatSession], Bool) -> Void
    let onArchive: ([ChatSession]) -> Void
    let onRename: (ChatSession) -> Void
    let onCopyDeepLinks: ([ChatSession]) -> Void
    let onPurge: ([String], [String], SessionPurgeActionMode) -> Void
    let purgeAvailable: Bool
    let purgeUnavailableReason: String
    let onMove: ([ChatSession], String?) -> Void

    var body: some View {
        let _ = HermternalSelectionOccupancyTrace.sessionRowBodyEvaluated()
        SessionRow(session: session)
            .accessibilityLabel(session.displayTitle)
            .accessibilityValue(sessionRowDetail(session))
            .accessibilityIdentifier("session-row-\(session.id)")
            // The row surface belongs to List, but VoiceOver still needs the
            // same default activation that the old row Button provided.
            .accessibilityAction {
                HermternalSwitchTrace.session(
                    "selection.observed.accessibility",
                    id: session.id,
                    messages: session.messageCount
                )
                onOpen(session)
            }
            // List remains the owner of selection. A simultaneous tap only
            // observes the completed primary click, so it cannot swallow
            // native selection, hover, drag, swipe actions, or context menus.
            .simultaneousGesture(
                TapGesture(count: 1)
                    .onEnded {
                        let allowed = SidebarSelectionEventAdapter.allowsPrimaryActivation()
                        HermternalSwitchTrace.session(
                            "selection.tapGate",
                            id: session.id,
                            messages: session.messageCount,
                            detail: allowed ? "allowed" : "blocked"
                        )
                        guard allowed else {
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


    private var moveChats: [ChatSession] {
        contextChats.filter { !scheduledIDs.contains($0.id) }
    }

    @ViewBuilder
    private var contextMenu: some View {
        let chats = contextChats
        let contextSelection = SidebarSelectionPolicy.contextTargets(
            clicked: .chat(session.id),
            selected: selection
        )
        let folderIDs = contextSelection.compactMap { item -> String? in
            guard case let .folder(id) = item else { return nil }
            return id
        }
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
        let action = SidebarSelectionPolicy.convergingPinAction(
            for: chats.map(\.pinned)
        )
        if let action {
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
        if let folderPhrase {
            Button(
                folderIDs.count == 1
                    ? "Permanently Delete Folder and Chats…"
                    : "Permanently Delete \(folderIDs.count) Folders and Chats…",
                systemImage: "trash.fill",
                role: .destructive
            ) {
                let selectedFolderIDs = contextSelection.compactMap { item -> String? in
                    guard case let .folder(id) = item else { return nil }
                    return id
                }
                onPurge(chats.map(\.id), selectedFolderIDs, .foldersAndChats)
            }
            .disabled(!purgeAvailable)
            .help(
                purgeAvailable
                    ? "Permanently delete all chats inside \(folderPhrase)"
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
        if !moveChats.isEmpty {
            moveMenu(moveChats, folderCount: folderIDs.count)
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
                    .disabled(chats.allSatisfy { membership[$0.id] == folder.id })
                }
            }
            if chats.contains(where: { membership[$0.id] != nil }) {
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
        .tint(.accentColor)
    }

    private var archiveButton: some View {
        Button("Archive", systemImage: "archivebox") {
            onArchive([session])
        }
        .tint(.accentColor)
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
