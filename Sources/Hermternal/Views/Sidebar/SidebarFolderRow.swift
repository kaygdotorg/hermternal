import SwiftUI
import UniformTypeIdentifiers
import HermternalCore

/// The sidebar's drag payload.
///
/// Plain text is the carrier, and the payload says what it is. An app-owned
/// `UTType` would read better, but a type has to be declared in the bundle's
/// Info.plist before a drop will match it, and an undeclared one fails
/// silently: a live build with `UTType(exportedAs:)` accepted no drop at all,
/// while the same build carrying plain text accepted every one. So the kind
/// travels in the string.
///
/// The two prefixes are what keeps a folder id and a session id apart: they
/// land on the same row and mean entirely different things. Any text without
/// one of them parses to `nil` and changes nothing, which is also what any
/// text dragged in from another application does.
enum SidebarDragPayload {
    /// `NSString` registers plain text, and `.text` is what a drop asks for.
    static let carrier = UTType.text

    private static let sessionPrefix = "hermternal-sidebar-session:"
    private static let folderPrefix = "hermternal-sidebar-folder:"

    static func provider(sessionID: String) -> NSItemProvider {
        NSItemProvider(object: (sessionPrefix + sessionID) as NSString)
    }

    static func provider(folderID: String) -> NSItemProvider {
        NSItemProvider(object: (folderPrefix + folderID) as NSString)
    }

    static func sessionID(from payload: String) -> String? {
        id(from: payload, prefix: sessionPrefix)
    }

    static func folderID(from payload: String) -> String? {
        id(from: payload, prefix: folderPrefix)
    }

    private static func id(from payload: String, prefix: String) -> String? {
        guard payload.hasPrefix(prefix) else { return nil }
        let id = payload.dropFirst(prefix.count)
        return id.isEmpty ? nil : String(id)
    }
}

/// The ids a drop carried, deduplicated and in the order they arrived.
///
/// A drop may hold several providers, each of which answers on its own queue,
/// so the ids are gathered here and handed back on the main actor. Only the
/// string crosses the boundary; no view or model closure ever does. `parse`
/// decides which kind of id is wanted and rejects everything else.
@MainActor
func sidebarDraggedIDs(
    _ providers: [NSItemProvider],
    parse: (String) -> String?
) async -> [String] {
    var ids = [String]()
    ids.reserveCapacity(providers.count)
    var seen = Set<String>(minimumCapacity: providers.count)
    for provider in providers {
        guard let payload = await provider.sidebarText(),
              let id = parse(payload),
              seen.insert(id).inserted
        else { continue }
        ids.append(id)
    }
    return ids
}

private extension NSItemProvider {
    /// The provider's text. The completion closure captures the continuation
    /// and nothing else, so an answer arriving off the main queue cannot
    /// touch view state.
    @MainActor
    func sidebarText() async -> String? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString) as String?)
            }
        }
    }
}

/// One folder as a flat List row: a disclosure caret, then the folder.
///
/// A row rather than a `Section`, because a drop attaches to a view and a
/// `Section` cannot receive one. Dragging a chat onto a folder is the gesture
/// a sidebar is for, so the folder has to be something that can be dropped
/// on.
///
/// The chats of the folder are NOT children of this view. The Folders section
/// places them after this row as siblings, each with one small leading inset.
/// A `DisclosureGroup` nested them instead, and a nested row makes the whole
/// List an outline: every other row in the sidebar, including Pinned and the
/// date buckets, then carries an indentation column it never asked for, and
/// sits right of the same rows in the schedules pane. No public API reduces
/// that column.
///
/// The drop is `onDrop` and the drag is `onDrag`, not `dropDestination` and
/// `draggable`. That is measured, not preferred: in a live build the modern
/// `Transferable` pair started no drag session at all on a
/// `.listStyle(.sidebar)` row, while the item-provider pair worked on the
/// first attempt with every other variable held fixed. Both are Apple APIs;
/// only one of them works here.
///
/// Reordering rides the same route, for the same measured reason: `onMove` on
/// the flat folder `ForEach` did nothing at three different drag speeds, in
/// the build where a chat drop already worked. So a folder is draggable
/// itself, and dropping one folder on another gives the dragged folder that
/// row's place. That is a whole position rather than a gap between two rows,
/// which is the honest limit of what these APIs can express here, and it
/// beats a reorder gesture that silently does nothing.
///
/// The caret is the one thing this row draws, and it is the same glyph, scale
/// and rotation the section headers use, so the sidebar keeps one disclosure
/// vocabulary. The row's highlight still belongs to the platform.
struct SidebarFolderRow: View {
    let target: SidebarFolderTarget
    @Binding var isExpanded: Bool
    let onRename: (SidebarFolderTarget) -> Void
    let onDelete: (SidebarFolderTarget) -> Void
    /// The dropped session ids, with the folder they were dropped on.
    let onDropSessions: ([String], String) -> Void
    /// A folder dragged onto this one: the dragged id, then this row's id.
    let onDropFolder: (String, String) -> Void

    /// Held here, so a drag over one folder redraws that folder alone.
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            disclosure
            label
        }
        // A folder is not a chat, so it must not become the List selection
        // and clear the open conversation. The chats of the folder are
        // sibling rows now and state their own rule.
        .selectionDisabled()
        .contextMenu {
            FolderCommands(
                target: target,
                onRename: onRename,
                onDelete: onDelete
            )
        }
    }

    /// The folder's caret, always visible.
    ///
    /// A section header may keep its caret for hover, because the header
    /// title is part of the same button. A folder title is the drop target,
    /// so the caret is the only control that opens the folder and it has to
    /// be there before the pointer is.
    private var disclosure: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .frame(width: SidebarMetrics.folderIndent, alignment: .leading)
                // The gutter is narrow, so the target takes the height of the
                // row and not the height of the glyph.
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isExpanded ? "Collapse \(target.name)" : "Expand \(target.name)"
        )
    }

    /// The drop lands on the label and not on the caret's gutter, so the
    /// control that opens the folder is never also its drop target.
    private var label: some View {
        Label {
            Text(target.name)
                .lineLimit(1)
                // Emphasis, not a plate. Accent text and a filled folder are
                // the platform's own vocabulary for "this is where it goes",
                // and neither draws a shape.
                .foregroundStyle(isTargeted ? Color.accentColor : Color.primary)
        } icon: {
            Image(systemName: "folder")
                .symbolVariant(isTargeted ? .fill : SymbolVariants.none)
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
        }
        .font(.body)
        .help(target.name)
        // Layout only: the drop target is the row's full width, so aiming at
        // a short folder name is not required.
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDrag {
            SidebarDragPayload.provider(folderID: target.id)
        }
        .onDrop(of: [SidebarDragPayload.carrier], isTargeted: $isTargeted) { providers in
            let targetID = target.id
            Task {
                // A folder arriving means reordering; a chat arriving means
                // filing. The payload says which, so neither case has to
                // guess what a bare string was supposed to mean, and text
                // from anywhere else parses to nothing.
                let folderIDs = await sidebarDraggedIDs(
                    providers,
                    parse: SidebarDragPayload.folderID
                )
                if let dragged = folderIDs.first {
                    onDropFolder(dragged, targetID)
                    return
                }
                let sessionIDs = await sidebarDraggedIDs(
                    providers,
                    parse: SidebarDragPayload.sessionID
                )
                // An id the sidebar does not currently render changes
                // nothing: the caller resolves ids against the rows it has.
                guard !sessionIDs.isEmpty else { return }
                onDropSessions(sessionIDs, targetID)
                // A chat that lands in a collapsed folder would otherwise
                // vanish without saying where it went.
                isExpanded = true
            }
            return true
        }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}
