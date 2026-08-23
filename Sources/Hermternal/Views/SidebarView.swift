import SwiftUI
import HermternalCore

struct SidebarView: View {
    @Bindable var model: AppModel
    let accountName: String
    let accountDetail: String?
    let accountID: String?
    @State private var pendingOpenTask: Task<Void, Never>?
    @State private var pointerActivatedID: String?
    @State private var renameSession: ChatSession?
    @State private var renameTitle = ""
    @State private var isCreatingFolder = false
    @State private var renameFolderTarget: SidebarFolderTarget?
    @State private var deleteFolderTarget: SidebarFolderTarget?
    /// Shared by the create and the rename alert. Only one of the two can be
    /// on screen, so a second field would only be a second thing to reset.
    @State private var folderNameField = ""
    /// Height of the floating pinned layer. The chat list's dissolve is
    /// measured up from this layer's top edge.
    @State private var pinnedLayerHeight: CGFloat = 0
    let calendar: Calendar
    let now: Date
    init(
        model: AppModel,
        accountName: String,
        accountDetail: String? = nil,
        accountID: String? = nil,
        calendar: Calendar = .current,
        now: Date = Date()
    ) {
        self._model = Bindable(model)
        self.accountName = accountName
        self.accountDetail = accountDetail
        self.accountID = accountID
        self.calendar = calendar
        self.now = now
    }

    /// Three named parts, not one chain. The chain this replaced went over
    /// the type checker's budget twice in one day, and every part of it was
    /// load bearing, so the fix is to give the solver smaller expressions
    /// rather than to give up a behaviour.
    var body: some View {
        // The complete ordering is rebuilt once per body pass. No section and
        // no row calls this again.
        let sections = sidebarRows(
            sessions: model.sessions,
            folders: model.folders,
            membership: model.membership,
            sortMode: model.sortMode,
            groupByDate: model.groupByDate,
            calendar: calendar,
            now: now
        )
        // The schedules section still comes from the model; only its
        // rendering moves out of the List. Reading the section shares its
        // rows array rather than copying any row.
        let scheduleRows = sections.first { $0.kind == .schedules }?.rows ?? []

        return columnChrome(
            ZStack(alignment: .bottom) {
                chatList(sections)
                floatingLayer(scheduleRows)
            }
        )
    }

    /// The chat list, and the edge treatment that lets its rows travel
    /// under fixed chrome without colliding with it.
    private func chatList(_ sections: [SidebarSection]) -> some View {
        List(selection: $model.selectedSessionID) {
            sessionSections(sections)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // The list keeps its full height, so rows travel all the way to
        // the floating layer and dissolve on the way. Its SCROLL CONTENT
        // stops short of it, so the last row cannot come to rest inside
        // the ramp, where the mask would erase it and no amount of
        // scrolling could bring it back.
        //
        // Only the bottom edge needs this. A progressive edge exists so
        // content can pass UNDER fixed chrome, not so blank space can be
        // reserved above it, and at the top there is no final row that
        // needs parking space. Measured on the Mac at true 2x, an inset
        // here pushed the whole list down by its own height and moved the
        // first header 32pt away from the traffic lights.
        //
        // `.contentMargins(_:_:for: .scrollContent)` is a no-op on a
        // `.sidebar` List, also measured, so the inset is the only
        // primitive that applies.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: pinnedLayerHeight + SidebarDissolve.bottomReach)
        }
        // Rows travel under fixed chrome at both edges, so the CONTENT
        // dissolves before it reaches either boundary. A `Material` behind
        // the layer could not do this: it is behind-window vibrancy and
        // cannot obscure an in-window sibling. One continuous gradient,
        // never stacked opacity bands, and never hit-testing.
        .mask { chatListDissolve }
    }

    /// Split out on its own so the thirteen-argument call is an expression
    /// the solver checks by itself. Its concrete return type costs it
    /// nothing and saves it inferring one.
    private func sessionSections(_ sections: [SidebarSection]) -> SidebarSections {
        SidebarSections(
            sections: sections,
            folders: model.folders,
            membership: model.membership,
            onOpen: { session in
                openImmediately(session)
            },
            onPin: { session in
                Task {
                    await model.setPinned(session, pinned: !session.pinned)
                }
            },
            onArchive: { session in
                Task {
                    await model.setArchived(session, archived: true)
                }
            },
            onRename: { session in
                beginRename(session)
            },
            onCopyDeepLink: { session in
                model.copyDeepLink(for: session)
            },
            onMove: { session, folderID in
                Task {
                    if let folderID {
                        await model.assign(session, toFolder: folderID)
                    } else {
                        await model.unassign(session)
                    }
                }
            },
            onRenameFolder: { target in
                beginFolderRename(target)
            },
            onDeleteFolder: { target in
                deleteFolderTarget = target
            },
            // The same door as the toolbar menu, on the Folders header
            // where Craft puts it.
            onNewFolder: beginFolderCreate,
            // The complete new order, every folder, never a slice.
            onReorderFolders: { ids in
                Task { await model.reorderFolders(ids: ids) }
            }
        )
    }

    /// A floating layer, not an inline pane: the list keeps its full height
    /// and its rows pass beneath, dissolving into the mask above. An empty
    /// layer would hold a strip of the chat list hostage to say nothing,
    /// and a user cannot create a schedule from here, so absence hides it.
    private func floatingLayer(_ scheduleRows: [SidebarRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !scheduleRows.isEmpty {
                schedulesPane(scheduleRows)
            }
            Divider()
            // `accountName` and `accountDetail` are the older names at the
            // composition root. The gateway is the primary line now. The
            // account name is the secondary line.
            SidebarAccountRow(
                gateway: accountName,
                account: accountDetail,
                accountID: accountID
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        // The mask's reach is measured from this layer's own top edge, so
        // it stays correct when the schedules layer appears or goes.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            guard pinnedLayerHeight != height else { return }
            pinnedLayerHeight = height
        }
    }

    private func schedulesPane(_ scheduleRows: [SidebarRow]) -> SidebarSchedulesPane {
        SidebarSchedulesPane(
            rows: scheduleRows,
            folders: model.folders,
            membership: model.membership,
            selection: $model.selectedSessionID,
            onOpen: { session in
                openImmediately(session)
            },
            onPin: { session in
                Task {
                    await model.setPinned(session, pinned: !session.pinned)
                }
            },
            onArchive: { session in
                Task {
                    await model.setArchived(session, archived: true)
                }
            },
            onRename: { session in
                beginRename(session)
            },
            onCopyDeepLink: { session in
                model.copyDeepLink(for: session)
            },
            onMove: { session, folderID in
                Task {
                    if let folderID {
                        await model.assign(session, toFolder: folderID)
                    } else {
                        await model.unassign(session)
                    }
                }
            }
        )
    }

    /// Everything the column carries rather than draws: its menu, the four
    /// prompts its rows and its menu raise, and the open it schedules.
    /// Alerts attach anywhere in the column, so gathering them here costs
    /// no behaviour and keeps `body` readable.
    private func columnChrome(_ content: some View) -> some View {
        content
            // Declared on the sidebar column, because everything in the
            // menu is a property of the chat list rather than of the open
            // chat.
            .toolbar {
                ToolbarItem {
                    Menu {
                        SidebarOrganizeMenu(
                            sortMode: sortModeBinding,
                            groupByDate: groupByDateBinding,
                            onNewFolder: beginFolderCreate
                        )
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("Folders, sorting and grouping")
                }
            }
            .alert(
                "Rename Chat",
                isPresented: renamePresented,
                presenting: renameSession
            ) { _ in
                TextField("Title", text: $renameTitle)
                    .onSubmit { commitRename() }
                Button("Rename") {
                    commitRename()
                }
                Button("Cancel", role: .cancel) {
                    cancelRename()
                }
            } message: { _ in
                Text("Enter a new title.")
            }
            .alert("New Folder", isPresented: $isCreatingFolder) {
                TextField("Name", text: $folderNameField)
                    .onSubmit { commitFolderCreate() }
                Button("Create") {
                    commitFolderCreate()
                }
                Button("Cancel", role: .cancel) {
                    folderNameField = ""
                }
            } message: {
                Text("Enter a name for the folder.")
            }
            .alert(
                "Rename Folder",
                isPresented: folderRenamePresented,
                presenting: renameFolderTarget
            ) { _ in
                TextField("Name", text: $folderNameField)
                    .onSubmit { commitFolderRename() }
                Button("Rename") {
                    commitFolderRename()
                }
                Button("Cancel", role: .cancel) {
                    cancelFolderRename()
                }
            } message: { _ in
                Text("Enter a new name for the folder.")
            }
            .confirmationDialog(
                "Delete Folder?",
                isPresented: folderDeletePresented,
                titleVisibility: .visible,
                presenting: deleteFolderTarget
            ) { target in
                Button("Delete Folder", role: .destructive) {
                    deleteFolderTarget = nil
                    Task {
                        await model.deleteFolder(id: target.id)
                    }
                }
                Button("Cancel", role: .cancel) {
                    deleteFolderTarget = nil
                }
            } message: { target in
                // The kept chats are the whole question a user has here, so
                // the answer is stated and not left to be assumed.
                Text("“\(target.name)” is removed. The chats inside it are kept and return to the list.")
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

    /// One continuous gradient with two ramps: a short softening where the
    /// list's first rows pass under the glass titlebar, and a longer one
    /// where its last rows pass under the floating layer. Two masks would
    /// be two compositing groups fighting over the same rows, so both
    /// ramps live in one gradient.
    ///
    /// Both are measured in points from the edge they belong to and only
    /// then turned into fractions, so each keeps its real length whatever
    /// the window's height.
    private var chatListDissolve: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height, 1)
            SidebarDissolve.ramp(
                boundary: max(height - pinnedLayerHeight, 0),
                height: height
            )
            // Rule 4 of the progressive edge: a mask that hit-tests would
            // swallow the scrolling, clicks and focus it sits over.
            .allowsHitTesting(false)
        }
    }

    /// Both preferences write through the model, so both persist.
    private var sortModeBinding: Binding<SortMode> {
        Binding(
            get: { model.sortMode },
            set: { mode in
                guard mode != model.sortMode else { return }
                Task { await model.setSortMode(mode) }
            }
        )
    }

    private var groupByDateBinding: Binding<Bool> {
        Binding(
            get: { model.groupByDate },
            set: { isEnabled in
                guard isEnabled != model.groupByDate else { return }
                Task { await model.setGroupByDate(isEnabled) }
            }
        )
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameSession != nil },
            set: { isPresented in
                if !isPresented {
                    cancelRename()
                }
            }
        )
    }

    private var folderRenamePresented: Binding<Bool> {
        Binding(
            get: { renameFolderTarget != nil },
            set: { isPresented in
                if !isPresented {
                    cancelFolderRename()
                }
            }
        )
    }

    private var folderDeletePresented: Binding<Bool> {
        Binding(
            get: { deleteFolderTarget != nil },
            set: { isPresented in
                if !isPresented {
                    deleteFolderTarget = nil
                }
            }
        )
    }

    private func beginRename(_ session: ChatSession) {
        renameTitle = session.displayTitle
        renameSession = session
    }

    private func commitRename() {
        guard let session = renameSession else { return }
        let title = renameTitle
        renameSession = nil
        renameTitle = ""
        Task {
            await model.rename(session, to: title)
        }
    }

    private func cancelRename() {
        renameSession = nil
        renameTitle = ""
    }

    private func beginFolderCreate() {
        folderNameField = ""
        isCreatingFolder = true
    }

    private func commitFolderCreate() {
        let name = folderNameField.trimmingCharacters(in: .whitespacesAndNewlines)
        folderNameField = ""
        isCreatingFolder = false
        guard !name.isEmpty else { return }
        Task {
            await model.createFolder(named: name)
        }
    }

    private func beginFolderRename(_ target: SidebarFolderTarget) {
        folderNameField = target.name
        renameFolderTarget = target
    }

    private func commitFolderRename() {
        guard let target = renameFolderTarget else { return }
        let name = folderNameField.trimmingCharacters(in: .whitespacesAndNewlines)
        renameFolderTarget = nil
        folderNameField = ""
        guard !name.isEmpty, name != target.name else { return }
        Task {
            await model.renameFolder(id: target.id, to: name)
        }
    }

    private func cancelFolderRename() {
        renameFolderTarget = nil
        folderNameField = ""
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

/// The chat list's two dissolves: a short one under the glass titlebar at
/// the top, and a longer one under the floating layer at the bottom.
///
/// Both ramps borrow their SHAPE from what the app already ships, and
/// neither borrows its distance. `SearchPanel` runs clear through 30pt,
/// 0.12 at 48pt, 0.55 at 72pt and opaque at 96pt: proportions of
/// 0.31 / 0.5 / 0.75 / 1. `ChatView` runs its top fade over 130pt at
/// 0.30 / 0.55 / 0.76 of the way. Those distances were measured in a
/// full-width results panel and a full-width reading column, where 96pt is
/// a fraction of one card. This column is about 250pt wide with 32pt rows,
/// so 96pt would be three whole rows fading at once: a hazy band, which is
/// the thing rule 3 of the progressive-edge skill exists to prevent.
///
/// So the proportions are kept and the distances come from this column.
/// `bottomReach` is 48pt, one and a half rows: the dissolve starts a row
/// and a half above the layer and is complete 15pt short of it, so only
/// the row actually passing underneath is fading.
///
/// `topReach` is 6pt, and it is small because the geometry leaves no room
/// for more. Measured on the Mac at true 2x: the chat list's frame begins
/// at the titlebar's BOTTOM edge, 52pt down, and the first section
/// header's ink rests 2pt below that, at 54pt. The list does not pass
/// under the titlebar, so there is no overlap band to dissolve in, and any
/// ramp longer than the header's own ink dims that header where it rests.
/// 6pt is the longest feather that leaves the header's body fully opaque
/// and softens only its ascenders, while still taking the hard edge off a
/// row on its way out. A real top dissolve would need the list's frame to
/// extend under the titlebar, which is a change to the column's base
/// geometry rather than to this mask.
///
/// One type owns these numbers because two things depend on them: the mask
/// that draws the ramps, and the list's bottom content margin that keeps
/// the last row out of the bottom one. Split across two literals they
/// would drift, and the drift is invisible until a row is unreadable.
private enum SidebarDissolve {
    /// Distances up from the floating layer's top edge.
    static let bottomReach: CGFloat = 48
    static let strong: CGFloat = 36
    static let soft: CGFloat = 24
    /// Fully gone, short of the boundary, so no ink ever touches it.
    static let gone: CGFloat = 15

    /// Distance down from the list's own top edge.
    static let topReach: CGFloat = 6

    /// One continuous gradient. Stacked opacity bands would step and seam,
    /// and a second mask would be a second compositing group.
    ///
    /// `boundary` is the distance from the mask's top edge down to the
    /// floating layer, and `height` is the mask's own height.
    static func ramp(boundary: CGFloat, height: CGFloat) -> LinearGradient {
        // Clamped to the end of the top ramp, so in a sidebar too short to
        // hold both the two can meet but never cross and invert.
        func up(_ above: CGFloat) -> CGFloat {
            max(boundary - above, topReach) / height
        }
        func down(_ below: CGFloat) -> CGFloat {
            min(below, height) / height
        }
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.25), location: down(topReach * 0.30)),
                .init(color: .black.opacity(0.65), location: down(topReach * 0.55)),
                .init(color: .black.opacity(0.88), location: down(topReach * 0.76)),
                .init(color: .black, location: down(topReach)),
                .init(color: .black, location: up(bottomReach)),
                .init(color: .black.opacity(0.55), location: up(strong)),
                .init(color: .black.opacity(0.12), location: up(soft)),
                .init(color: .clear, location: up(gone)),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
