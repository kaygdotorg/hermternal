import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @Bindable var appearance: AppearanceSettings

    var body: some View {
        // Bind selection straight to the model and react in onChange. An
        // inline Binding(get:set:) here never delivered its setter, so
        // clicking a row did nothing at all.
        List(selection: $model.selectedSessionID) {
            Section("Chats") {
                ForEach(model.sessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                }
            }
        }
        .listStyle(.sidebar)
        // scrollContentBackground only clears the scroll content; the split
        // view's own sidebar material still paints over the glass.
        .scrollContentBackground(.hidden)
        .clearAppKitBackground()
        .glassSurface(intensity: appearance.sidebarGlass)
        .onChange(of: model.selectedSessionID) { _, newValue in
            guard let id = newValue,
                  let session = model.sessions.first(where: { $0.id == id })
            else { return }
            Task { await model.open(session) }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.newChat() }
                } label: {
                    Image(systemName: "plus")
                }
                .help("New chat")
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem {
                Button {
                    Task { await model.loadSessions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload the chat list from the server")
            }
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
