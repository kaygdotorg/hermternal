import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedSessionID },
            set: { id in
                guard let id, let session = model.sessions.first(where: { $0.id == id })
                else { return }
                Task { await model.open(session) }
            }
        )) {
            Section("Chats") {
                ForEach(model.sessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.newChat() }
                } label: {
                    Label("New Chat", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await model.loadSessions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh chats")
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .padding(10)
        }
    }
}

private struct SessionRow: View {
    let session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.displayTitle)
                .lineLimit(1)
                .font(.body)
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
    }
}
