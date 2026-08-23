import SwiftUI
import HermternalCore

struct SidebarView: View {
    @Bindable var model: AppModel
    let accountName: String
    let accountDetail: String?
    let accountID: String?
    @State private var pendingOpenTask: Task<Void, Never>?
    @State private var pointerActivatedID: String?

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
                        SessionRow(session: session)
                            .contentShape(.rect)
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    openImmediately(session)
                                }
                            )
                            .tag(session.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

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

private struct SessionRow: View {
    let session: ChatSession

    /// An empty value reads as no value, so this avoids a conditional branch that
    /// would give the row two identities and churn it when the count crosses zero.
    private var accessibilityCount: String {
        switch session.messageCount {
        case ..<1: ""
        case 1: "1 message"
        default: "\(session.messageCount) messages"
        }
    }

    var body: some View {
        // `displayTitle` is stored on the session, so reading it costs nothing.
        let title = session.displayTitle
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .lineLimit(1)
                .font(.body)
                .help(title)
            HStack(spacing: 5) {
                if let startedAt = session.startedAt {
                    Text(startedAt, format: .relative(presentation: .named))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityCount)
        .accessibilityIdentifier("session-row-\(session.id)")
    }
}
