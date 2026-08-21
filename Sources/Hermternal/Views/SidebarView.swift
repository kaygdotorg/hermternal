import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @Bindable var appearance: AppearanceSettings
    @FocusState private var sidebarFocused: Bool

    private func moveSelection(by offset: Int, using proxy: ScrollViewProxy) -> KeyPress.Result {
        let sessions = model.sessions
        guard !sessions.isEmpty else { return .handled }
        let currentIndex = model.selectedSessionID.flatMap { selectedID in
            sessions.firstIndex { $0.id == selectedID }
        }
        let targetIndex: Int
        if let currentIndex {
            let nextIndex = currentIndex + offset
            guard sessions.indices.contains(nextIndex) else { return .handled }
            targetIndex = nextIndex
        } else {
            targetIndex = offset > 0 ? 0 : sessions.count - 1
        }

        let session = sessions[targetIndex]
        model.selectedSessionID = session.id
        Task { await model.open(session) }
        withAnimation {
            proxy.scrollTo(session.id, anchor: .center)
        }
        return .handled
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(model.sessions) { session in
                            SessionButton(
                                session: session,
                                isSelected: model.selectedSessionID == session.id
                            ) {
                                sidebarFocused = true
                                model.selectedSessionID = session.id
                                Task { await model.open(session) }
                            }
                            .id(session.id)
                        }
                    } header: {
                        Text("Chats")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
            .focusable()
            .focused($sidebarFocused)
            .onKeyPress(.downArrow) {
                moveSelection(by: 1, using: proxy)
            }
            .onKeyPress(.upArrow) {
                moveSelection(by: -1, using: proxy)
            }
            .glassSurface(intensity: appearance.sidebarGlass)
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

private struct SessionButton: View {
    let session: ChatSession
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear),
                in: .rect(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
