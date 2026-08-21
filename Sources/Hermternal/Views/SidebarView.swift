import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @Bindable var appearance: AppearanceSettings

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(model.sessions) { session in
                        SessionButton(
                            session: session,
                            isSelected: model.selectedSessionID == session.id
                        ) {
                            // Direct activation avoids the selection binding
                            // indirection that previously swallowed clicks.
                            model.selectedSessionID = session.id
                            Task { await model.open(session) }
                        }
                    }
                } header: {
                    Text("Chats")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        // Let content disappear beneath the floating header
                        // without putting an opaque strip across the glass.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)
        }
        // List(.sidebar) is an NSTableView inside an NSVisualEffectView and
        // paints its own sidebar material regardless of
        // scrollContentBackground(.hidden). A plain lazy stack has no hidden
        // AppKit backing, so this glass is the only material in the column.
        .glassSurface(intensity: appearance.sidebarGlass)
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
