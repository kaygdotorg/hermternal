import SwiftUI
import HermternalCore

struct SidebarView: View {
    @Bindable var model: AppModel
    let accountName: String
    let accountDetail: String?
    let accountID: String?
    @State private var pendingOpenTask: Task<Void, Never>?
    @State private var pointerActivatedID: String?
    @State private var renameSession: ChatSession?
    @State private var renameTitle = ""

    init(
        model: AppModel,
        accountName: String,
        accountDetail: String? = nil,
        accountID: String? = nil
    ) {
        self._model = Bindable(model)
        self.accountName = accountName
        self.accountDetail = accountDetail
        self.accountID = accountID
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            List(selection: $model.selectedSessionID) {
                Section("Chats") {
                    ForEach(model.sessions) { session in
                        SessionRowItem(
                            session: session,
                            onOpen: { session in
                                openImmediately(session)
                            },
                            onPin: { session in
                                Task {
                                    await model.setPinned(session, pinned: !session.pinned)
                                }
                            },
                            onArchive: { session in
                                Task {
                                    await model.setArchived(session, archived: true)
                                }
                            },
                            onRename: { session in
                                beginRename(session)
                            }
                        )
                        .tag(session.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .alert(
                "Rename Chat",
                isPresented: renamePresented,
                presenting: renameSession
            ) { _ in
                TextField("Title", text: $renameTitle)
                    .onSubmit { commitRename() }
                Button("Rename") {
                    commitRename()
                }
                Button("Cancel", role: .cancel) {
                    cancelRename()
                }
            } message: { _ in
                Text("Enter a new title.")
            }

            SidebarBottomEdge {
                SidebarAccountRow(
                    name: accountName,
                    detail: accountDetail,
                    accountID: accountID
                )
            }
        }
        .onChange(of: model.selectedSessionID) { _, newValue in
            if pointerActivatedID == newValue {
                pointerActivatedID = nil
                return
            }
            pointerActivatedID = nil
            scheduleOpen(for: newValue)
        }
        .onDisappear {
            pendingOpenTask?.cancel()
            pendingOpenTask = nil
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameSession != nil },
            set: { isPresented in
                if !isPresented {
                    cancelRename()
                }
            }
        )
    }

    private func beginRename(_ session: ChatSession) {
        renameTitle = session.displayTitle
        renameSession = session
    }

    private func commitRename() {
        guard let session = renameSession else { return }
        let title = renameTitle
        renameSession = nil
        renameTitle = ""
        Task {
            await model.rename(session, to: title)
        }
    }

    private func cancelRename() {
        renameSession = nil
        renameTitle = ""
    }

    /// Mouse activation should paint cached detail immediately. Mark the id
    /// so the selection change does not schedule a duplicate delayed open.
    private func openImmediately(_ session: ChatSession) {
        pointerActivatedID = session.id
        pendingOpenTask?.cancel()
        pendingOpenTask = nil
        if model.selectedSessionID != session.id {
            model.selectedSessionID = session.id
        }
        pendingOpenTask = Task {
            guard !Task.isCancelled else { return }
            await model.open(session)
        }
    }

    /// Native selection and scrolling update immediately. Delay only detail
    /// work long enough for key repeat to collapse into the final row.
    private func scheduleOpen(for id: String?) {
        pendingOpenTask?.cancel()
        pendingOpenTask = nil
        guard let id,
              let session = model.sessions.first(where: { $0.id == id })
        else { return }

        pendingOpenTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(45))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await model.open(session)
        }
    }
}

/// Spoken message count for a row. Empty reads as no value.
private func messageCountLabel(_ count: Int) -> String {
    switch count {
    case ..<1: ""
    case 1: "1 message"
    default: "\(count) messages"
    }
}

private struct SessionRowItem: View {
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
