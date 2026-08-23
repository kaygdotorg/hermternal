import Foundation
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
    /// `NSString` keeps the proven item-provider drag/drop route working in a
    /// sidebar List. The envelope is versioned and carries one typed batch.
    static let carrier = UTType.text

    private static let envelopePrefix = "hermternal-sidebar:v2:"
    private static let version = 2

    private struct Envelope: Codable {
        let version: Int
        let kind: Kind
        let ids: [String]

        enum Kind: String, Codable, Equatable {
            case chat
            case folder
        }
    }

    static func provider(sessionID: String) -> NSItemProvider {
        provider(sessionIDs: [sessionID])
    }

    static func provider(folderID: String) -> NSItemProvider {
        provider(folderIDs: [folderID])
    }

    static func provider(sessionIDs: [String]) -> NSItemProvider {
        provider(envelope: Envelope(version: version, kind: .chat, ids: unique(sessionIDs)))
    }

    static func provider(folderIDs: [String]) -> NSItemProvider {
        provider(envelope: Envelope(version: version, kind: .folder, ids: unique(folderIDs)))
    }

    static func sessionID(from payload: String) -> String? {
        sessionIDs(from: payload)?.first
    }

    static func folderID(from payload: String) -> String? {
        folderIDs(from: payload)?.first
    }

    static func sessionIDs(from payload: String) -> [String]? {
        ids(from: payload, kind: .chat)
    }

    static func folderIDs(from payload: String) -> [String]? {
        ids(from: payload, kind: .folder)
    }

    private static func provider(envelope: Envelope) -> NSItemProvider {
        guard !envelope.ids.isEmpty,
              let data = try? JSONEncoder().encode(envelope)
        else { return NSItemProvider(object: "" as NSString) }
        let payload = envelopePrefix + data.base64EncodedString()
        return NSItemProvider(object: payload as NSString)
    }

    private static func ids(from payload: String, kind: Envelope.Kind) -> [String]? {
        guard payload.hasPrefix(envelopePrefix),
              let data = Data(base64Encoded: String(payload.dropFirst(envelopePrefix.count))),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == version,
              envelope.kind == kind
        else { return nil }
        let ids = unique(envelope.ids)
        return ids.isEmpty ? nil : ids
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// The ids a drop carried, deduplicated and in the order they arrived.
///
/// A drop may hold several providers, each of which answers on its own queue,
/// so the ids are gathered here and handed back on the main actor. Only the
/// string crosses the boundary; no view or model closure ever does. `parse`
/// decides which kind of id is wanted and rejects everything else.
@MainActor
private func sidebarPayload(from provider: NSItemProvider) async -> String? {
    let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
        provider.loadDataRepresentation(
            forTypeIdentifier: SidebarDragPayload.carrier.identifier
        ) { data, _ in
            continuation.resume(returning: data)
        }
    }
    return data.flatMap { String(data: $0, encoding: .utf8) }
}

@MainActor
func sidebarDraggedIDs(
    _ providers: [NSItemProvider],
    parse: (String) -> [String]?
) async -> [String] {
    var ids = [String]()
    var seen = Set<String>()
    for provider in providers {
        guard let payload = await sidebarPayload(from: provider),
              let parsed = parse(payload)
        else { continue }
        for id in parsed where seen.insert(id).inserted {
            ids.append(id)
        }
    }
    return ids
}

/// One folder, as one flat list row.
///
/// The chats of the folder are NOT children of this view. The Folders
/// section places them after this row as siblings, each with its own small
/// leading inset. A `DisclosureGroup` would nest them instead, and a nested
/// row makes the whole List an outline: every other row in the sidebar,
/// including Pinned and the date buckets, then carries an indentation
/// column it never asked for.
struct SidebarFolderRow: View {
    let target: SidebarFolderTarget
    @Binding var isExpanded: Bool
    let selection: Set<SidebarSelectionID>
    let visibleOrder: [SidebarSelectionID]
    let foldersByID: [String: SidebarFolderTarget]
    let onRename: (SidebarFolderTarget) -> Void
    let onPurge: ([String], [String], SessionPurgeActionMode) -> Void
    let purgeAvailable: Bool
    let purgeUnavailableReason: String
    let onDelete: ([SidebarFolderTarget]) -> Void
    /// The dropped session ids, with the folder they were dropped on.
    let onDropSessions: ([String], String) -> Void
    /// A block of folders dragged onto this one.
    let onDropFolders: ([String], String) -> Void

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            disclosure
            label
        }
        .tag(SidebarSelectionID.folder(target.id))
        .selectionDisabled(false)
        .contextMenu {
            folderContextMenu
        }
    }

    /// The folder's caret, always visible.
    ///
    /// A section header may keep its caret for hover, because the header
    /// title is part of the same button. A folder title selects the folder
    /// instead, so the caret is the only control that opens the folder and it
    /// has to be there before the pointer is.
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

    private var folderTargets: [SidebarFolderTarget] {
        let targets = SidebarSelectionPolicy.contextTargets(
            clicked: .folder(target.id),
            selected: selection
        )
        var seen = Set<String>()
        return visibleOrder.compactMap { item in
            guard case let .folder(id) = item,
                  targets.contains(item),
                  seen.insert(id).inserted
            else { return nil }
            return foldersByID[id]
        }
    }

    @ViewBuilder
    private var folderContextMenu: some View {
        let targets = folderTargets
        Button("Rename Folder…", systemImage: "pencil") {
            if targets.count == 1, let target = targets.first { onRename(target) }
        }
        .disabled(targets.count != 1)
        Button("Delete \(targets.count) Folders…", systemImage: "trash", role: .destructive) {
            onDelete(targets)
        }
        Button("Delete Folders and Chats Permanently", systemImage: "trash.fill", role: .destructive) {
            onPurge([], targets.map(\.id), .foldersAndChats)
        }
        .disabled(!purgeAvailable)
        .help(purgeAvailable ? "Permanently delete chats in these folders" : purgeUnavailableReason)
    }
    private var label: some View {
        Label {
            Text(target.name)
                .lineLimit(1)
                .foregroundStyle(isTargeted ? Color.accentColor : Color.primary)
        } icon: {
            Image(systemName: "folder")
                .symbolVariant(isTargeted ? .fill : SymbolVariants.none)
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
        }
        .font(.body)
        .help(target.name)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDrag {
            let ids = SidebarSelectionPolicy.applicableDragTargets(
                dragged: .folder(target.id),
                selected: selection,
                visibleOrder: visibleOrder
            ).compactMap { if case let .folder(id) = $0 { id } else { nil } }
            return SidebarDragPayload.provider(folderIDs: ids)
        }
        .onDrop(of: [SidebarDragPayload.carrier], isTargeted: $isTargeted) { providers in
            let targetID = target.id
            Task {
                let folderIDs = await sidebarDraggedIDs(
                    providers,
                    parse: SidebarDragPayload.folderIDs
                )
                if !folderIDs.isEmpty {
                    onDropFolders(folderIDs, targetID)
                    return
                }
                let sessionIDs = await sidebarDraggedIDs(
                    providers,
                    parse: SidebarDragPayload.sessionIDs
                )
                guard !sessionIDs.isEmpty else { return }
                onDropSessions(sessionIDs, targetID)
                isExpanded = true
            }
            return true
        }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}
