import SwiftUI
import HermternalCore

/// The folder that a sidebar command acts on.
///
/// `SidebarSectionKind.folder` already carries these two values, so the
/// target costs one small struct and keeps the alert and the confirmation
/// dialog free of optional unwrapping.
struct SidebarFolderTarget: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Row command that files a chat into a folder, or takes it back out.
///
/// A `Menu` inside a `.contextMenu` is native. The folder list is therefore
/// built when the menu is presented, not on every row body pass.
struct MoveToFolderMenu: View {
    let session: ChatSession
    let folders: [Folder]
    let currentFolderID: String?
    /// A `nil` folder id removes the chat from its folder.
    let onMove: (ChatSession, String?) -> Void

    var body: some View {
        Menu("Move to Folder", systemImage: "folder") {
            if folders.isEmpty {
                // An empty menu looks broken, so the reason is stated.
                Button("No Folders Yet") {}
                    .disabled(true)
            } else {
                ForEach(folders) { folder in
                    Button(folder.name) {
                        onMove(session, folder.id)
                    }
                    .disabled(folder.id == currentFolderID)
                }
            }
            if currentFolderID != nil {
                Divider()
                Button("Remove from Folder", systemImage: "folder.badge.minus") {
                    onMove(session, nil)
                }
            }
        }
    }
}

/// Rename and delete for one folder.
///
/// Shared by the folder row's context menu, so every route to these two
/// commands states them the same way. Folding a folder away is not here: a
/// folder is a row now and carries its own disclosure caret, which is always
/// visible and needs no menu item to stand in for it.
struct FolderCommands: View {
    let target: SidebarFolderTarget
    let onRename: (SidebarFolderTarget) -> Void
    let onDelete: (SidebarFolderTarget) -> Void

    var body: some View {
        Button("Rename Folder…", systemImage: "pencil") {
            onRename(target)
        }
        Button(role: .destructive) {
            onDelete(target)
        } label: {
            Label("Delete Folder…", systemImage: "trash")
        }
    }
}

/// The Folders header menu: create a folder, and fold the whole section away.
///
/// The header's own disclosure control appears on hover, which no keyboard
/// reaches, so the same command lives here where it is always available.
struct FoldersSectionCommands: View {
    @Binding var isExpanded: Bool
    let onNewFolder: () -> Void

    var body: some View {
        Button("New Folder…", systemImage: "folder.badge.plus", action: onNewFolder)
        Divider()
        Button(
            isExpanded ? "Collapse Folders" : "Expand Folders",
            systemImage: isExpanded ? "chevron.right" : "chevron.down"
        ) {
            isExpanded.toggle()
        }
    }
}

/// Sidebar toolbar menu: folder creation plus the two list preferences.
///
/// The bindings write through `AppModel`, so both preferences persist.
struct SidebarOrganizeMenu: View {
    @Binding var sortMode: SortMode
    @Binding var groupByDate: Bool
    let onNewFolder: () -> Void

    var body: some View {
        Button("New Folder…", systemImage: "folder.badge.plus", action: onNewFolder)
        Divider()
        Picker("Sort By", selection: $sortMode) {
            ForEach(SortMode.allCases, id: \.self) { mode in
                Text(mode.sidebarTitle).tag(mode)
            }
        }
        Divider()
        Toggle("Group by Date", isOn: $groupByDate)
    }
}

extension SortMode {
    /// Menu title. The exhaustive `switch` keeps a new case visible to the
    /// compiler instead of falling back to a raw value.
    var sidebarTitle: String {
        switch self {
        case .lastActivity: "Last Activity"
        case .created: "Date Created"
        case .title: "Title"
        }
    }
}
