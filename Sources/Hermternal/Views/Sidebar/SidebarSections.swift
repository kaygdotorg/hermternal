import SwiftUI
import UniformTypeIdentifiers
import HermternalCore

/// Sidebar sectioning metrics.
///
/// Measured from the live Craft sidebar, then from our own accessibility
/// geometry. Craft's header ink is 9.7pt tall on the same glyph classes as
/// its rows' 12.3pt, so its header font is about 13.3pt against 16.8pt rows:
/// smaller than its rows in relative terms, but bold and full white where
/// the rows sit at 0.90 white. Our rows are 13pt, so 13pt bold at full
/// primary matches Craft's header in absolute size and beats our rows on
/// weight and contrast.
///
/// Craft leaves about 8.5pt above a header and none below it. Our native
/// sidebar already leaves 15.5pt above the header's ink and only 2.5pt
/// below, which is why the header reads as touching its first row. The
/// bottom gap fixes that without drawing anything. Every value is absolute,
/// so none of it drifts when the row height changes.
/// Internal rather than private because the pinned schedules layer lives in
/// its own file and has to share exactly these values.
enum SidebarMetrics {
    static let sectionGap: CGFloat = 2
    static let headerBottomGap: CGFloat = 6
    /// The pinned layer's header is not a List section header, so it carries
    /// the leading inset the native ones get for free. Measured from our own
    /// accessibility geometry: AXOutline x=1296, AXHeading x=1310.
    static let paneHeaderGap: CGFloat = 8
    /// Leading inset for a header TITLE, shared by the List's own section
    /// headers and by the pinned schedules layer. It is the platform's own
    /// header inset, measured from the running app: AXOutline x=1296 against
    /// a header at x=1310. The hover caret adds its width to the title
    /// LOCALLY and never to this constant, so a header that is not hovered
    /// and the pane's header both sit at the same 14.
    static let headerLeadingInset: CGFloat = 14
    /// A trailing inset that balances the leading one, so the header's
    /// menu does not sit flush against the sidebar edge.
    static let headerTrailingInset: CGFloat = 10
    /// Width the hover caret takes, including the gap to the title. Held
    /// only while the pointer is on the header: the indent belongs to the
    /// hover state, not to the base layout.
    static let headerControlSlot: CGFloat = 14
    /// Gap between a header's items, and between the control and the title.
    static let headerControlGap: CGFloat = 4
    /// The folder disclosure gutter, and the leading inset on the chats
    /// inside a folder. One constant does both, so a chat's icon column
    /// lands exactly under the icon column of the folder that holds it,
    /// with the folder's caret alone in the gutter to their left.
    ///
    /// This is a tenth of what the sidebar used to indent by, and it is
    /// local. A `DisclosureGroup` or a `Section(isExpanded:)` makes the
    /// whole List an outline, and an outline reserves an indentation column
    /// on EVERY row: Pinned and the date buckets were pushed right by a
    /// folder feature they have nothing to do with, and sat right of the
    /// same rows in the schedules pane. No public API reduces that column.
    /// So the sidebar List holds no outline primitive at all, and the one
    /// place that wants an indent asks for it by name.
    static let folderIndent: CGFloat = 10
    /// One motion for every disclosure in the sidebar. It runs inside the
    /// expansion bindings, so the header button, the header menu command and
    /// a folder's own caret all animate the same way.
    static let disclosureAnimation = Animation.easeOut(duration: 0.12)
    /// Schedules show three entries at once and scroll for the rest.
    static let visibleScheduleRows: CGFloat = 3
}

struct SidebarSections: View {
    let sections: [SidebarSection]
    let folders: [Folder]
    let membership: [String: String]
    let selection: Set<SidebarSelectionID>
    let visibleOrder: [SidebarSelectionID]
    let folderVisibleOrder: [SidebarSelectionID]
    let rowMenuDerivations: SidebarRowMenuDerivations
    let onOpen: (ChatSession) -> Void
    let onPin: ([ChatSession], Bool) -> Void
    let onArchive: ([ChatSession]) -> Void
    let onRename: (ChatSession) -> Void
    let onCopyDeepLinks: ([ChatSession]) -> Void
    let onMove: ([ChatSession], String?) -> Void
    let onRenameFolder: (SidebarFolderTarget) -> Void
    /// Selects a folder without changing the active transcript.
    let onSelectFolder: (String) -> Void
    let onDeleteFolder: ([SidebarFolderTarget]) -> Void
    let onNewFolder: () -> Void
    let onPurge: ([String], [String], SessionPurgeActionMode) -> Void
    let purgeAvailable: Bool
    let purgeUnavailableReason: String
    let onReorderFolders: ([String]) -> Void

    /// Collapse is view state, not user data. It is deliberately not
    /// persisted, because a disclosure click must not write to disk. The
    /// collapsed ids are stored rather than the expanded ones, so a folder
    /// created later opens expanded without seeding anything.
    @State private var collapsedFolderIDs: Set<String> = []
    /// The same rule for the List's own sections.
    @State private var collapsedSections: Set<SidebarSectionKind> = []
    @State private var isFoldersExpanded = true

    var body: some View {
        // `sections` is already built. Splitting it walks a handful of
        // entries once per pass and never rebuilds the ordering.
        let runs = SidebarSectionRuns(sections)
        ForEach(runs.leading) { section in
            sectionView(section)
        }
        if !runs.folders.isEmpty {
            foldersSection(runs.folders)
        }
        ForEach(runs.trailing) { section in
            sectionView(section)
        }
    }

    /// Every folder under one header, as rows rather than as sections.
    ///
    /// A `Section` can neither receive a drop nor be reordered, and a row can
    /// do both. That, and not decoration, is why the shape changed. The
    /// trailing control sits on the header, which is Craft's shape too.
    ///
    /// The chats of a folder are siblings of their folder row, not children
    /// of a `DisclosureGroup`. Nesting them turned the List into an outline
    /// and indented every unrelated row with it. Flat rows plus
    /// `folderIndent` group the chats under their folder, leave every other
    /// row on the plain sidebar baseline, and keep each chat its own list
    /// row for selection, drag and swipe.
    @ViewBuilder
    private func foldersSection(_ runs: [SidebarFolderRun]) -> some View {
        Section {
            // Expansion gates the content instead of `Section(isExpanded:)`,
            // which draws a second disclosure control on the trailing side
            // and turns the List into an outline.
            if isFoldersExpanded {
                ForEach(runs) { run in
                    SidebarFolderRow(
                        target: run.target,
                        isExpanded: folderExpansion(for: run.target.id),
                        selection: selection,
                        visibleOrder: folderVisibleOrder,
                        menu: rowMenuDerivations.folderByItem[
                            .folder(run.target.id)
                        ]!,
                        onRename: onRenameFolder,
                        onSelect: onSelectFolder,
                        onPin: onPin,
                        onArchive: onArchive,
                        onPurge: onPurge,
                        purgeAvailable: purgeAvailable,
                        purgeUnavailableReason: purgeUnavailableReason,
                        onDelete: onDeleteFolder,
                        onDropSessions: file,
                        onDropFolders: reorderFolders
                    )
                    if isFolderExpanded(run.target.id) {
                        // A List spreads a modifier on a `ForEach` over the
                        // rows it makes, so this is one inset per chat and
                        // not a wrapper view around the run.
                        rows(for: run.section)
                            .padding(.leading, SidebarMetrics.folderIndent)
                    }
                }
            }
        } header: {
            SidebarSectionHeader(title: "Folders", isExpanded: foldersExpansion) {
                Menu {
                    FoldersSectionCommands(
                        isExpanded: foldersExpansion,
                        onNewFolder: onNewFolder
                    )
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Folder options")
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: SidebarSection) -> some View {
        switch section.kind {
        case .ungrouped:
            // Craft draws a rule only where a group has no title, and lets
            // a bright header do that work everywhere else. The ungrouped
            // list is our only untitled group.
            Section {
                unfilingRows(for: section)
            } header: {
                Divider()
                    .padding(.top, SidebarMetrics.sectionGap)
            }
        case .bucket:
            Section {
                if isSectionExpanded(section.kind) {
                    unfilingRows(for: section)
                }
            } header: {
                SidebarSectionHeader(
                    title: sectionTitle(for: section.kind),
                    isExpanded: sectionExpansion(for: section.kind)
                )
            }
        default:
            Section {
                if isSectionExpanded(section.kind) {
                    rows(for: section)
                }
            } header: {
                SidebarSectionHeader(
                    title: sectionTitle(for: section.kind),
                    isExpanded: sectionExpansion(for: section.kind)
                )
            }
        }
    }

    @ViewBuilder
    private func rows(for section: SidebarSection) -> some View {
        sessionRows(for: section)
        hint(for: section)
    }

    /// A date bucket is also where a chat comes back OUT of a folder. The
    /// drop lands on the `ForEach` itself, which is why `sessionRows` is
    /// typed as `DynamicViewContent`: no `Section` can be a drop target.
    @ViewBuilder
    private func unfilingRows(for section: SidebarSection) -> some View {
        sessionRows(for: section)
            .onInsert(of: [SidebarDragPayload.carrier]) { _, providers in
                unfileDropped(providers)
            }
        hint(for: section)
    }

    /// The session rows of one section, typed as `DynamicViewContent` so a
    /// caller can attach a drop handler to the `ForEach` rather than to a row.
    private func sessionRows(for section: SidebarSection) -> some DynamicViewContent {
        ForEach(section.rows) { row in
            SessionRowItem(
                session: row.session,
                folders: folders,
                menu: rowMenuDerivations.sessionByItem[
                    .chat(row.sessionID)
                ]!,
                isSelected: selection.contains(.chat(row.sessionID)),
                onOpen: onOpen,
                onPin: onPin,
                onArchive: onArchive,
                onRename: onRename,
                onCopyDeepLinks: onCopyDeepLinks,
                onPurge: onPurge,
                purgeAvailable: purgeAvailable,
                purgeUnavailableReason: purgeUnavailableReason,
                onMove: onMove
            )
            .tag(SidebarSelectionID.chat(row.sessionID))
            .selectionDisabled(false)
            .onDrag {
                SidebarDragPayload.provider(
                    sessionIDs: dragSessionIDs(
                        for: row.sessionID,
                        in: section.kind
                    )
                )
            }
        }
    }
    /// Drag selection is resolved at gesture start, not while constructing
    /// every section. Held-arrow selection changes therefore do not rebuild a
    /// per-section drag table.
    private func dragSessionIDs(
        for sessionID: String,
        in sectionKind: SidebarSectionKind
    ) -> [String] {
        guard sectionKind != .schedules else { return [] }
        return SidebarSelectionPolicy.applicableDragTargets(
            dragged: .chat(sessionID),
            selected: selection,
            visibleOrder: visibleOrder
        )
        .compactMap { item in
            guard case let .chat(id) = item,
                  !rowMenuDerivations.scheduledIDs.contains(id)
            else {
                return nil
            }
            return id
        }
    }

    /// The hint is separate from the rows, so the `ForEach` stays the only
    /// thing in a section that carries row identity.
    @ViewBuilder
    private func hint(for section: SidebarSection) -> some View {
        if section.rows.isEmpty, let text = emptyHint(for: section.kind) {
            SidebarEmptyHint(text: text)
        }
    }

    /// Files chats into a folder. This runs on a drop and never on a body
    /// pass, so it scans sections already in memory instead of holding a
    /// session dictionary that every pass would have to rebuild.
    private func file(_ ids: [String], into folderID: String) {
        guard !ids.isEmpty else { return }
        var wanted = Set(ids)
        var moved = [ChatSession]()
        for section in sections {
            for row in section.rows {
                guard wanted.remove(row.sessionID) != nil,
                      membership[row.sessionID] != folderID
                else { continue }
                moved.append(row.session)
            }
            if wanted.isEmpty { break }
        }
        onMove(moved, folderID)
    }

    /// Takes chats out of their folder, from the ids a bucket's drop carried.
    private func unfileDropped(_ providers: [NSItemProvider]) {
        Task {
            unfile(await sidebarDraggedIDs(
                providers,
                parse: SidebarDragPayload.sessionIDs
            ))
        }
    }

    /// Takes chats out of their folder. The insertion offset that the drop
    /// hands back is ignored on purpose: sidebar order comes from the sort
    /// mode, so the only thing a drop into a date bucket can mean is that the
    /// chat leaves its folder. Only folder sections are searched, so dragging
    private func unfile(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var wanted = Set(ids)
        var moved = [ChatSession]()
        for section in sections {
            guard case .folder = section.kind else { continue }
            for row in section.rows {
                guard wanted.remove(row.sessionID) != nil else { continue }
                moved.append(row.session)
            }
            if wanted.isEmpty { break }
        }
        onMove(moved, nil)
    }

    /// Gives a dragged folder the place of the folder it was dropped on, and
    /// hands on the complete new order because the store rejects a slice.
    ///
    /// The order is read back out of `sections`, which is the order actually
    /// on screen. That happens on a drop, never on a body pass.
    private func reorderFolders(_ draggedIDs: [String], onto targetID: String) {
        var ids = folderVisibleOrder.compactMap { item in
            if case let .folder(id) = item { return id }
            return nil
        }
        let dragged = draggedIDs.filter { ids.contains($0) }
        guard !dragged.isEmpty, !dragged.contains(targetID) else { return }
        ids.removeAll { dragged.contains($0) }
        guard let targetIndex = ids.firstIndex(of: targetID) else { return }
        ids.insert(contentsOf: dragged, at: targetIndex)
        onReorderFolders(ids)
    }

    /// An empty section with no explanation looks broken, so it says what to
    /// do instead of saying nothing.
    private func emptyHint(for kind: SidebarSectionKind) -> String? {
        switch kind {
        case .pinned:
            "Pin a chat to keep it close"
        case .folder:
            "Move chats here to group them"
        default:
            nil
        }
    }

    /// Held as the collapsed set, so the default for any folder is expanded.
    private func folderExpansion(for folderID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolderIDs.contains(folderID) },
            set: { isExpanded in
                withAnimation(SidebarMetrics.disclosureAnimation) {
                    if isExpanded {
                        collapsedFolderIDs.remove(folderID)
                    } else {
                        collapsedFolderIDs.insert(folderID)
                    }
                }
            }
        )
    }

    private func isFolderExpanded(_ folderID: String) -> Bool {
        !collapsedFolderIDs.contains(folderID)
    }

    private func sectionExpansion(for kind: SidebarSectionKind) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(kind) },
            set: { isExpanded in
                withAnimation(SidebarMetrics.disclosureAnimation) {
                    if isExpanded {
                        collapsedSections.remove(kind)
                    } else {
                        collapsedSections.insert(kind)
                    }
                }
            }
        )
    }

    private func isSectionExpanded(_ kind: SidebarSectionKind) -> Bool {
        !collapsedSections.contains(kind)
    }

    /// The Folders header and its menu write through the same animated
    /// binding, so a collapse looks identical from either control.
    private var foldersExpansion: Binding<Bool> {
        Binding(
            get: { isFoldersExpanded },
            set: { isExpanded in
                withAnimation(SidebarMetrics.disclosureAnimation) {
                    isFoldersExpanded = isExpanded
                }
            }
        )
    }

    private func sectionTitle(for kind: SidebarSectionKind) -> String {
        switch kind {
        case .schedules:
            "Schedules"
        case .pinned:
            "Pinned"
        case .folder(_, let name):
            name
        case .bucket(let bucket):
            dateBucketTitle(bucket)
        case .ungrouped:
            ""
        }
    }

    private func dateBucketTitle(_ bucket: DateBucket) -> String {
        switch bucket {
        case .today:
            "Today"
        case .yesterday:
            "Yesterday"
        case .previousSevenDays:
            "Previous 7 Days"
        case .previousThirtyDays:
            "Previous 30 Days"
        case .older:
            "Older"
        }
    }
}

/// One folder, paired with the rows the ordering put inside it.
///
/// The section kind already carries the id and the name, so pairing them here
/// spares every folder row an optional unwrap and keeps the row out of a
/// conditional branch.
private struct SidebarFolderRun: Identifiable {
    let target: SidebarFolderTarget
    let section: SidebarSection

    var id: String { target.id }
}

/// The three runs the sidebar renders: everything above the folders, the
/// folders themselves, and everything below.
///
/// Schedules are dropped here rather than rendered as an empty view, because
/// they belong to the floating layer above the account row. The partition of
/// cron runs from chats still happens in the model.
private struct SidebarSectionRuns {
    var leading: [SidebarSection] = []
    var folders: [SidebarFolderRun] = []
    var trailing: [SidebarSection] = []

    init(_ sections: [SidebarSection]) {
        for section in sections {
            switch section.kind {
            case .schedules:
                continue
            case .folder(let id, let name):
                folders.append(SidebarFolderRun(
                    target: SidebarFolderTarget(id: id, name: name),
                    section: section
                ))
            default:
                if folders.isEmpty {
                    leading.append(section)
                } else {
                    trailing.append(section)
                }
            }
        }
    }
}

/// A List section header: a hover-revealed disclosure control on the leading
/// side, the title, and an optional command menu on the trailing side.
///
/// Hover is not the only way to fold a section away. The whole header is the
/// button, so clicking anywhere on it works, and the Folders header carries
/// the same command in its menu. A hover-only control is invisible to anyone
/// using a keyboard and to anyone who never hovers.
///
/// This caret is the only disclosure control a section has. A section uses a
/// plain `Section` and gates its own content, because `Section(isExpanded:)`
/// draws a second control on the trailing side and makes the whole List an
/// outline, which indents every row in it.
private struct SidebarSectionHeader<Trailing: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var trailing: () -> Trailing
    /// Held here rather than in the parent, so moving the pointer over one
    /// header redraws that header alone and not every row in the list.
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: SidebarMetrics.headerControlGap) {
            // One button for the caret AND the title, so a click on the
            // caret cannot also fire a gesture on the header and cancel
            // itself out, and so the hit target is the whole header at every
            // point in the transition.
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 0) {
                    // The slot carries the gap to the title, so one animated
                    // width moves the caret in and the title across
                    // together. Clipped, so the glyph is never over the
                    // title while the slot is opening or closing.
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .opacity(isHovered ? 1 : 0)
                        .frame(
                            width: isHovered ? SidebarMetrics.headerControlSlot : 0,
                            alignment: .leading
                        )
                        .clipped()

                    Text(title)
                    Spacer(minLength: 4)
                }
                // Hit testing only. The header draws no shape of its own.
                .contentShape(.rect)
                // 120ms ease-out, the same reveal this file already uses: a
                // hover is seen many times a minute and has to be there the
                // moment the pointer is, without a flourish.
                .animation(.easeOut(duration: 0.12), value: isHovered)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isExpanded ? "Collapse \(title)" : "Expand \(title)"
            )

            trailing()
        }
        .sidebarSectionHeader()
        .padding(.trailing, SidebarMetrics.headerTrailingInset)
        .onHover { isHovered = $0 }
        // A header is not a row, and must never join a Select All or hold
        // the selection that a row should have.
        .selectionDisabled()
    }
}

extension SidebarSectionHeader where Trailing == EmptyView {
    init(title: String, isExpanded: Binding<Bool>) {
        self.init(title: title, isExpanded: isExpanded, trailing: { EmptyView() })
    }
}

/// The italic hint under an empty section.
private struct SidebarEmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .italic()
            .foregroundStyle(.secondary)
            .selectionDisabled()
    }
}

extension View {
    /// Bold and full-white at Craft's measured header size, so the header
    /// wins against its rows by weight and contrast rather than by shouting.
    /// The native header slot draws its own background; only type, colour
    /// and padding change here.
    func sidebarSectionHeader(topGap: CGFloat = SidebarMetrics.sectionGap) -> some View {
        font(.body.weight(.bold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.top, topGap)
            .padding(.bottom, SidebarMetrics.headerBottomGap)
    }
}
