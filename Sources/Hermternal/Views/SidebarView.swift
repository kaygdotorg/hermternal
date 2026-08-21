import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var pendingOpenTask: Task<Void, Never>?

    var body: some View {
        List(selection: $model.selectedSessionID) {
            Section("Chats") {
                ForEach(model.sessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                }
            }
        }
        // Tahoe supplies the inset/floating Liquid Glass sidebar, selection,
        // focus, scrolling, and keyboard navigation. Do not layer another
        // background, glass effect, or custom focus system over it.
        .listStyle(.sidebar)
        .onChange(of: model.selectedSessionID) { _, newValue in
            scheduleOpen(for: newValue)
        }
        .onDisappear {
            pendingOpenTask?.cancel()
            pendingOpenTask = nil
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

    /// Selection and native scrolling update immediately. Detail work waits
    /// briefly so key repeat coalesces into one cached paint and one resume.
    private func scheduleOpen(for id: String?) {
        pendingOpenTask?.cancel()
        pendingOpenTask = nil
        guard let id,
              let session = model.sessions.first(where: { $0.id == id })
        else { return }

        pendingOpenTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
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
