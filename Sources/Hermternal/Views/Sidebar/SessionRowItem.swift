import SwiftUI
import HermternalCore

/// Spoken message count for a row. Empty reads as no value.
private func messageCountLabel(_ count: Int) -> String {
    switch count {
    case ..<1: ""
    case 1: "1 message"
    default: "\(count) messages"
    }
}

struct SessionRowItem: View {
    let session: ChatSession
    let onOpen: (ChatSession) -> Void
    let onPin: (ChatSession) -> Void
    let onArchive: (ChatSession) -> Void
    let onRename: (ChatSession) -> Void

    var body: some View {
        Button {
            onOpen(session)
        } label: {
            SessionRow(session: session)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.displayTitle)
        .accessibilityValue(messageCountLabel(session.messageCount))
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
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .lineLimit(1)
                .font(.body)
                .help(title)
            HStack(spacing: 5) {
                if let timestamp = session.lastActive ?? session.startedAt {
                    Text(timestamp, format: .relative(presentation: .named))
                }
                if session.messageCount > 0 {
                    Text("·")
                    Text("\(session.messageCount)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
