import SwiftUI
import AppKit
import HermternalCore

/// Captures the native event that owns a selection change.
/// Programmatic model selection has no matching event and never opens again.
@MainActor
private enum SidebarSelectionEventAdapter {
    private struct Event {
        let isContextClick: Bool
        let isModified: Bool
    }

    private static var monitor: Any?
    private static var pending: Event?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { event in
            switch event.type {
            case .leftMouseDown:
                pending = Event(
                    isContextClick: false,
                    isModified: event.modifierFlags.intersection([.command, .shift]).isEmpty == false
                )
            case .rightMouseDown:
                pending = Event(isContextClick: true, isModified: true)
            case .keyDown:
                pending = Event(isContextClick: false, isModified: false)
            default:
                break
            }
            return event
        }
    }

    static func consume() -> (isContextClick: Bool, isModified: Bool) {
        defer { pending = nil }
        guard let pending else { return (false, false) }
        return (pending.isContextClick, pending.isModified)
    }

    static func isUserNavigationPending() -> Bool {
        guard let pending else { return false }
        return !pending.isContextClick && !pending.isModified
    }

    static func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        pending = nil
    }
}

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
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { model.selectedSessionID },
            set: { id in
                guard !model.hasProgrammaticSelection(id),
                      SidebarSelectionEventAdapter.isUserNavigationPending()
                else {
                    model.selectedSessionID = id
                    return
                }
                model.userNavigationDidBegin()
                model.selectedSessionID = id
            }
        )
    }

    private func chatList(_ sections: [SidebarSection]) -> some View {
        List(selection: selectionBinding) {
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
                .frame(height: pinnedLayerHeight + SidebarDissolve.reach)
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
            selection: selectionBinding,
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
                let event = SidebarSelectionEventAdapter.consume()
                if model.consumeProgrammaticSelection(newValue) {
                    pointerActivatedID = nil
                    return
                }
                if pointerActivatedID == newValue {
                    pointerActivatedID = nil
                    return
                }
                guard !event.isContextClick, !event.isModified else {
                    pointerActivatedID = nil
                    pendingOpenTask?.cancel()
                    pendingOpenTask = nil
                    return
                }
                pointerActivatedID = nil
                model.userNavigationDidBegin()
                scheduleOpen(for: newValue)
            }
            .onAppear {
                SidebarSelectionEventAdapter.start()
            }
            .onDisappear {
                SidebarSelectionEventAdapter.stop()
                pendingOpenTask?.cancel()
                pendingOpenTask = nil
            }
    }

    /// One continuous gradient with two ramps. The first ramp fades the
    /// rows that move under the glass titlebar. The second ramp fades the
    /// rows that move under the floating layer. Two masks would make two
    /// compositing groups over the same rows, so one gradient holds both
    /// ramps.
    ///
    /// The code measures both ramps in points from the edge that they
    /// belong to, then converts the points to fractions. Each ramp keeps
    /// its length at any window height.
    ///
    /// The list frame extends 44pt up, under the titlebar. SwiftUI lays out
    /// mask content inside the safe area. A gradient that uses only the
    /// size of this proxy therefore starts at the bottom edge of the
    /// titlebar. The overlap band then gets no gradient, the rows cross it
    /// at full opacity, and the complete ramp falls on the resting section
    /// header. The offset below draws the gradient through the inset, over
    /// the rows.
    ///
    /// The mask extends up, and the list does not. `ignoresSafeArea` here,
    /// or a top inset on the list, changes the position of the first
    /// section header. An offset changes only the paint, so the column
    /// keeps its layout.
    private var chatListDissolve: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let height = max(geometry.size.height + insets.top + insets.bottom, 1)
            SidebarDissolve.ramp(
                boundary: max(height - pinnedLayerHeight, 0),
                height: height
            )
            .frame(height: height)
            .offset(y: -insets.top)
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
        model.userNavigationDidBegin()
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

/// The chat list's two dissolves: one under the glass titlebar at the top,
/// one under the floating layer at the bottom.
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
/// So the code keeps the proportions and takes the distances from this
/// column. `reach` is 48pt, which is one and a half rows. A row is fully
/// opaque at 48pt from the chrome. A row is fully transparent at `gone`,
/// which is 15pt from the chrome. Only the row that passes under the
/// chrome fades.
///
/// Both edges use the same four distances, in mirror, because both edges
/// are the same event: a row arrives at fixed chrome. Measurement on the
/// Mac at true 2x shows that the top edge has the space for it. The list
/// frame starts 8pt down the window. It extends 44pt up, under the
/// titlebar. The bottom edge of the titlebar is 52pt down the window. The
/// first section header rests at 54pt.
///
/// The top ramp is therefore transparent for its first 15pt, which end at
/// 23pt down the window, and it keeps ink away from the window buttons.
/// The ramp fades the rows across the overlap band, where the glass
/// titlebar draws no background of its own. The ramp is fully opaque at
/// 48pt, which is 56pt down the window. That point is 2pt inside the
/// ascenders of the resting header, and above the body of its text.
///
/// The 6pt ramp that this replaced came from an incorrect measurement.
/// That measurement put the top of the list frame at the bottom edge of
/// the titlebar. The ramp had no overlap band to work in, so it faded the
/// resting header instead.
///
/// One type owns these numbers because two things depend on them: the mask
/// that draws the ramps, and the list's bottom content margin that keeps
/// the last row out of the bottom one. Split across two literals they
/// would drift, and the drift is invisible until a row is unreadable.
private enum SidebarDissolve {
    /// Distances from the chrome edge each ramp belongs to: up from the
    /// floating layer's top edge at the bottom, down from the list's own
    /// frame edge at the top.
    static let reach: CGFloat = 48
    static let strong: CGFloat = 36
    static let soft: CGFloat = 24
    /// Fully gone, short of the edge, so no ink ever touches it.
    static let gone: CGFloat = 15

    /// One continuous gradient. Stacked opacity bands would step and seam,
    /// and a second mask would be a second compositing group.
    ///
    /// `boundary` is the distance from the mask's top edge down to the
    /// floating layer, and `height` is the mask's own height.
    static func ramp(boundary: CGFloat, height: CGFloat) -> LinearGradient {
        // The code limits every bottom stop to the end of the top ramp. In
        // a sidebar that is too short for both ramps, the two ramps then
        // meet, but they never cross and invert. The unlimited values
        // increase in order, so the limited values stay in order.
        func up(_ above: CGFloat) -> CGFloat {
            min(max(boundary - above, reach), height) / height
        }
        func down(_ below: CGFloat) -> CGFloat {
            min(below, height) / height
        }
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: down(gone)),
                .init(color: .black.opacity(0.12), location: down(soft)),
                .init(color: .black.opacity(0.55), location: down(strong)),
                .init(color: .black, location: down(reach)),
                .init(color: .black, location: up(reach)),
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
