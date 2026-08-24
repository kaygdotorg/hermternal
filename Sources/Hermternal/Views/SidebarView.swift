import Foundation
import SwiftUI
import AppKit
import HermternalCore

/// SwiftUI's `List(selection:)` reports only the resulting Set. The local
/// monitor captures the initiating event synchronously, so a modified click
/// cannot be mistaken for an ordinary singleton selection later.
@MainActor
enum SidebarSelectionEventAdapter {
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
                let modifiers = event.modifierFlags.intersection([.command, .shift, .control])
                let isControlClick = modifiers.contains(.control)
                // Every mouse-down owns a complete click turn. Replacing the
                // prior record here means a click with no List selection
                // delta cannot leak its flags into the next click.
                pending = Event(
                    isContextClick: isControlClick,
                    isModified: !modifiers.isEmpty
                )
            case .rightMouseDown:
                pending = Event(isContextClick: true, isModified: true)
            case .keyDown:
                pending = nil
            default:
                break
            }
            return event
        }
    }

    static func current() -> (isContextClick: Bool, isModified: Bool)? {
        guard let pending else { return nil }
        return (pending.isContextClick, pending.isModified)
    }

    static func allowsPrimaryActivation() -> Bool {
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
/// Opt-in aggregate accounting for the synchronous work observed during one
/// sidebar selection turn. All clocks are monotonic and all state is
/// main-actor isolated, so disabled builds pay only one static branch at each
/// probe; the enabled summary emits counters and durations, never raw
/// identifiers or row content.
@MainActor
enum HermternalSelectionOccupancyTrace {
    private static var gate = DebugModuleGate(mask: .none)

    static func configure(gate: DebugModuleGate) {
        self.gate = gate
    }

    private struct State {
        let selection: Set<SidebarSelectionID>
        let messages: Int
        var sidebarBodies = 0
        var sidebarBodyNanoseconds: UInt64 = 0
        var sessionRows = 0
        var folderRows = 0
        var orderingResolves = 0
        var orderingNanoseconds: UInt64 = 0
        var observers = 0
    }

    private static var state: State?
    private static var completedSelection: Set<SidebarSelectionID>?
    private static var flushTask: Task<Void, Never>?

    static func beginIfNeeded(
        selection: Set<SidebarSelectionID>,
        messages: Int
    ) {
        guard gate.isEnabled(.mainActorOccupancy) else { return }
        guard !selection.isEmpty else { return }
        if state == nil, completedSelection == selection {
            return
        }
        if let current = state, current.selection == selection {
            return
        }
        flush()
        state = State(selection: selection, messages: messages)
        flushTask?.cancel()
        flushTask = Task { @MainActor in
            await Task.yield()
            await Task.yield()
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    static func observerInvoked(
        forChatID id: String?,
        messages: Int
    ) {
        guard gate.isEnabled(.mainActorOccupancy) else { return }
        guard let id else {
            observerInvoked()
            return
        }
        let selection: Set<SidebarSelectionID> = [.chat(id)]
        beginIfNeeded(selection: selection, messages: messages)
        observerInvoked()
    }

    static func observerInvoked() {
        guard gate.isEnabled(.mainActorOccupancy) else { return }
        state?.observers += 1
    }

    static func sidebarBodyBegan() -> UInt64? {
        guard gate.isEnabled(.mainActorOccupancy) else { return nil }
        state?.sidebarBodies += 1
        return DispatchTime.now().uptimeNanoseconds
    }

    static func sidebarBodyEnded(_ start: UInt64?) {
        guard gate.isEnabled(.mainActorOccupancy), let start else { return }
        state?.sidebarBodyNanoseconds += DispatchTime.now().uptimeNanoseconds - start
    }

    static func orderingResolveBegan() -> UInt64? {
        guard gate.isEnabled(.mainActorOccupancy) else { return nil }
        state?.orderingResolves += 1
        return DispatchTime.now().uptimeNanoseconds
    }

    static func orderingResolveEnded(_ start: UInt64?) {
        guard gate.isEnabled(.mainActorOccupancy), let start else { return }
        state?.orderingNanoseconds += DispatchTime.now().uptimeNanoseconds - start
    }

    static func sessionRowBodyEvaluated() {
        guard gate.isEnabled(.mainActorOccupancy) else { return }
        state?.sessionRows += 1
    }

    static func folderRowBodyEvaluated() {
        guard gate.isEnabled(.mainActorOccupancy) else { return }
        state?.folderRows += 1
    }

    private static func flush() {
        guard gate.isEnabled(.mainActorOccupancy), let state else { return }
        HermternalSwitchTrace.selection(
            "selection.occupancy.summary",
            selection: state.selection,
            messages: state.messages,
            detail: "sidebarBodies=\(state.sidebarBodies)"
                + " sidebarBodyNs=\(state.sidebarBodyNanoseconds)"
                + " sessionRows=\(state.sessionRows)"
                + " folderRows=\(state.folderRows)"
                + " orderingResolves=\(state.orderingResolves)"
                + " orderingNs=\(state.orderingNanoseconds)"
                + " observers=\(state.observers)",
            module: .mainActorOccupancy
        )
        completedSelection = state.selection
        Self.state = nil
    }
}

 

enum SidebarContentMode: String, Hashable {
    case chats
    case archived
}

private enum SidebarFocusTarget: Hashable {
    case chats
    case archived
}

struct SidebarView: View {
    @Bindable var model: AppModel
    let accountName: String
    let accountDetail: String?
    let accountID: String?
    @State private var pendingOpenTask: Task<Void, Never>?
    @State private var sidebarSelection: Set<SidebarSelectionID> = []
    @State private var pointerActivatedID: String?
    @State private var archivedPointerActivatedID: String?
    @State private var programmaticSelectionID: String?
    @State private var programmaticArchivedSelectionID: String?
    @State private var contentMode: SidebarContentMode = .chats
    @State private var archivedSelection: Set<String> = []
    /// The native List is the window's browsing focus target. Keeping this
    /// identity in SwiftUI lets defaultFocus and row taps use the same seam
    /// without reaching into AppKit's responder chain.
    @FocusState private var focusedList: SidebarFocusTarget?
    @State private var renameSession: ChatSession?
    @State private var renameTitle = ""
    @State private var isCreatingFolder = false
    @State private var renameFolderTarget: SidebarFolderTarget?
    @State private var deleteFolderTarget: SidebarFolderDeletionTarget?
    @State private var purgePreparationTask: Task<Void, Never>?
    @State private var purgeRequestGeneration = 0
    /// Shared by the create and the rename alert. Only one of the two can be
    @State private var purgeTarget: SidebarPurgeTarget?
    @State private var purgeConfirmation = ""
    /// on screen, so a second field would only be a second thing to reset.
    @State private var folderNameField = ""
    /// Height of the floating pinned layer. The chat list's dissolve is
    /// measured up from this layer's top edge.
    @State private var pinnedLayerHeight: CGFloat = 0
    /// Ordering and row identity maps survive selection-only body passes. The
    /// cache invalidates only on the explicit ordering inputs.
    @State private var sidebarDerivationCache = SidebarDerivationCache()
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
        let _ = HermternalSelectionOccupancyTrace.beginIfNeeded(
            selection: sidebarSelection,
            messages: model.messages.count
        )
        let bodyStart = HermternalSelectionOccupancyTrace.sidebarBodyBegan()
        let orderingStart = HermternalSelectionOccupancyTrace.orderingResolveBegan()
        let derived = sidebarDerivationCache.resolve(
            sessions: model.sessions,
            folders: model.folders,
            membership: model.membership,
            sortMode: model.sortMode,
            groupByDate: model.groupByDate,
            calendar: calendar,
            now: now
        )
        let _ = HermternalSelectionOccupancyTrace.orderingResolveEnded(orderingStart)
        let sections = derived.sections
        let scheduleRows = derived.scheduleRows
        let scheduledIDs = derived.scheduledIDs
        let visibleOrder = derived.visibleOrder
        let folderVisibleOrder = derived.folderVisibleOrder
        let sessionsByID = derived.sessionsByID
        let foldersByID = derived.foldersByID
        let content = columnChrome(
            Group {
                if contentMode == .chats {
                    ZStack(alignment: .bottom) {
                        chatList(
                            sections,
                            visibleOrder: visibleOrder,
                            folderVisibleOrder: folderVisibleOrder,
                            sessionsByID: sessionsByID,
                            foldersByID: foldersByID,
                            scheduledIDs: scheduledIDs
                        )
                        floatingLayer(
                            scheduleRows,
                            visibleOrder: visibleOrder,
                            sessionsByID: sessionsByID,
                            scheduledIDs: scheduledIDs
                        )
                    }
                } else {
                    archivedList
                }
            }
        )
        let _ = HermternalSelectionOccupancyTrace.sidebarBodyEnded(bodyStart)
        return content
    }
    private var archivedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $archivedSelection) {
                ArchivedSidebarContent(
                    sessions: model.archivedSessions,
                    selection: $archivedSelection,
                    isLoading: model.archivedSessionsLoading,
                    errorMessage: model.archivedSessionsError,
                    onOpen: { session in
                        openArchivedImmediately(session)
                    },
                    onRefresh: {
                        Task { await model.loadArchivedSessions() }
                    },
                    onRestore: { sessions in
                        Task { await model.restoreArchived(sessions) }
                    },
                    onCopyDeepLinks: { sessions in
                        model.copyDeepLinks(for: sessions)
                    },
                    canPurge: model.canPurgeSessions,
                    purgeUnavailableReason: model.sessionPurgeUnavailableReason,
                    onPurge: { ids in
                        requestPurge(chatIDs: ids, folderIDs: [], mode: .chatsOnly)
                    }
                )
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($focusedList, equals: .archived)
            // List remains the owner of selection. This observes the
            // completed primary click and also covers the row tap seam.
            .simultaneousGesture(
                TapGesture(count: 1)
                    .onEnded { focusedList = .archived }
            )
            Divider()
            SidebarAccountRow(
                gateway: accountName,
                account: accountDetail,
                accountID: accountID
            )
            .padding(.horizontal, 14)
        }
    }
    private func chatList(
        _ sections: [SidebarSection],
        visibleOrder: [SidebarSelectionID],
        folderVisibleOrder: [SidebarSelectionID],
        sessionsByID: [String: ChatSession],
        foldersByID: [String: SidebarFolderTarget],
        scheduledIDs: Set<String>
    ) -> some View {
        List(selection: $sidebarSelection) {
            sessionSections(
                sections,
                visibleOrder: visibleOrder,
                folderVisibleOrder: folderVisibleOrder,
                sessionsByID: sessionsByID,
                foldersByID: foldersByID,
                scheduledIDs: scheduledIDs
            )
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
        // This is a SwiftUI focus identity rather than an AppKit responder
        // lookup. The default is applied only when the window is choosing its
        // initial focus; Composer requests focus explicitly after New Chat.
        .focusable()
        .focused($focusedList, equals: .chats)
        .defaultFocus($focusedList, .chats)
        // List remains the owner of selection. This observes the completed
        // primary click and also covers SessionRowItem's tap seam.
        .simultaneousGesture(
            TapGesture(count: 1)
                .onEnded { focusedList = .chats }
        )
    }

    /// Split out on its own so the thirteen-argument call is an expression
    /// the solver checks by itself. Its concrete return type costs it
    /// nothing and saves it inferring one.
    private func sessionSections(
        _ sections: [SidebarSection],
        visibleOrder: [SidebarSelectionID],
        folderVisibleOrder: [SidebarSelectionID],
        sessionsByID: [String: ChatSession],
        foldersByID: [String: SidebarFolderTarget],
        scheduledIDs: Set<String>
    ) -> SidebarSections {
        SidebarSections(
            sections: sections,
            folders: model.folders,
            membership: model.membership,
            selection: sidebarSelection,
            visibleOrder: visibleOrder,
            folderVisibleOrder: folderVisibleOrder,
            sessionsByID: sessionsByID,
            foldersByID: foldersByID,
            scheduledIDs: scheduledIDs,
            onOpen: { session in openImmediately(session) },
            onPin: { sessions, pinned in
                Task { await model.setPinned(sessions, pinned: pinned) }
            },
            onArchive: { sessions in
                Task { await model.setArchived(sessions, archived: true) }
            },
            onRename: { session in beginRename(session) },
            onCopyDeepLinks: { sessions in model.copyDeepLinks(for: sessions) },
            onMove: { sessions, folderID in
                Task { await model.assign(sessions, toFolder: folderID) }
            },
            onRenameFolder: { target in beginFolderRename(target) },
            onSelectFolder: { id in
                HermternalSwitchTrace.folder(
                    "folder.onSelect.before",
                    id: id,
                    messages: model.messages.count
                )
                setSidebarSelection([.folder(id)], event: "sidebarSelection.folder.onSelect")
                HermternalSwitchTrace.folder(
                    "folder.onSelect.after",
                    id: id,
                    messages: model.messages.count
                )
            },
            onDeleteFolder: { targets in
                let affected = Set(model.membership.compactMap { sessionID, folderID in
                    targets.contains { $0.id == folderID } ? sessionID : nil
                }).count
                deleteFolderTarget = SidebarFolderDeletionTarget(
                    folders: targets,
                    affectedChatCount: affected
                )
            },
            onNewFolder: beginFolderCreate,
            onPurge: requestPurge,
            purgeAvailable: model.canPurgeSessions,
            purgeUnavailableReason: model.sessionPurgeUnavailableReason,
            onReorderFolders: { ids in
                Task { await model.reorderFolders(ids: ids) }
            }
        )
    }

    /// A floating layer, not an inline pane: the list keeps its full height
    /// and its rows pass beneath, dissolving into the mask above. An empty
    /// layer would hold a strip of the chat list hostage to say nothing,
    /// and a user cannot create a schedule from here, so absence hides it.
    private func floatingLayer(
        _ scheduleRows: [SidebarRow],
        visibleOrder: [SidebarSelectionID],
        sessionsByID: [String: ChatSession],
        scheduledIDs: Set<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !scheduleRows.isEmpty {
                schedulesPane(
                    scheduleRows,
                    visibleOrder: visibleOrder,
                    sessionsByID: sessionsByID,
                    scheduledIDs: scheduledIDs
                )
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

    private func schedulesPane(
        _ scheduleRows: [SidebarRow],
        visibleOrder: [SidebarSelectionID],
        sessionsByID: [String: ChatSession],
        scheduledIDs: Set<String>
    ) -> SidebarSchedulesPane {
        return SidebarSchedulesPane(
            rows: scheduleRows,
            folders: model.folders,
            membership: model.membership,
            visibleOrder: visibleOrder,
            sessionsByID: sessionsByID,
            scheduledIDs: scheduledIDs,
            selection: $sidebarSelection,
            onOpen: { session in openImmediately(session) },
            onPin: { sessions, pinned in
                Task { await model.setPinned(sessions, pinned: pinned) }
            },
            onArchive: { sessions in
                Task { await model.setArchived(sessions, archived: true) }
            },
            onRename: { session in beginRename(session) },
            onCopyDeepLinks: { sessions in model.copyDeepLinks(for: sessions) },
            onPurge: requestPurge,
            purgeAvailable: model.canPurgeSessions,
            purgeUnavailableReason: model.sessionPurgeUnavailableReason,
            onMove: { sessions, folderID in
                Task { await model.assign(sessions, toFolder: folderID) }
            }
        )
    }

    /// Everything the column carries rather than draws: its menu, the four
    /// prompts its rows and its menu raise, and the open it schedules.
    /// Alerts attach anywhere in the column, so gathering them here costs
    /// no behaviour and keeps `body` readable.
    private func columnChrome(_ content: some View) -> some View {
        let folderCount = deleteFolderTarget?.folders.count ?? 0
        let folderDeleteTitle = "Delete \(folderCount) Folders?"
        let chrome = content
            // Declared on the sidebar column, because everything in the
            // menu is a property of the chat list rather than of the open
            // chat.
            .toolbar {
                ToolbarItem {
                    Menu {
                        SidebarModeMenu(
                            mode: $contentMode,
                            onChatsSelected: {
                                if model.viewingArchivedSessionID != nil {
                                    model.leaveArchivedView()
                                }
                            },
                            onArchivedSelected: {
                                Task { await model.loadArchivedSessions() }
                            }
                        )
                        if contentMode == .chats {
                            Divider()
                            SidebarOrganizeMenu(
                                sortMode: sortModeBinding,
                                groupByDate: groupByDateBinding,
                                onNewFolder: beginFolderCreate
                            )
                        }
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
                folderDeleteTitle,
                isPresented: folderDeletePresented,
                titleVisibility: .visible,
                presenting: deleteFolderTarget
            ) { target in
                Button("Delete Folders", role: .destructive) {
                    deleteFolderTarget = nil
                    Task { await model.deleteFolders(ids: target.folders.map(\.id)) }
                }
                Button("Cancel", role: .cancel) {
                    deleteFolderTarget = nil
                }
            } message: { target in
                Text(
                    "\(target.folders.count) folder(s) will be removed. "
                        + "\(target.affectedChatCount) chat(s) will be kept and return to the list."
                )
            }
            .alert(
                purgeTarget.map { purgeTitle(for: $0.plan) } ?? "Permanently Delete",
                isPresented: purgePresented,
                presenting: purgeTarget
            ) { target in
                TextField(
                    "Type delete to confirm \(purgeScope(for: target.plan))",
                    text: $purgeConfirmation
                )
                    .onSubmit {
                        guard SessionPurgeConfirmation.isExact(purgeConfirmation) else { return }
                        completePurge(target)
                    }
                Button("Delete Permanently", role: .destructive) {
                    completePurge(target)
                }
                .disabled(!SessionPurgeConfirmation.isExact(purgeConfirmation))
                Button("Cancel", role: .cancel) {
                    cancelPurge()
                }
            } message: { target in
                let folderInclusion = target.plan.folderCount > 0
                    ? " All chats inside the selected folders are included."
                    : ""
                Text(
                    "\(purgeScope(for: target.plan)) will be permanently deleted."
                        + folderInclusion + " "
                        + "Branches may be retained; scheduled jobs remain. "
                        + "Backups or external memory may retain data. No undo."
                )
            }
        return sidebarLifecycle(chrome)
    }

    private func sidebarLifecycle(_ content: some View) -> some View {
        content
            .onChange(of: model.selectedSessionID) { _, newValue in
                HermternalSelectionOccupancyTrace.observerInvoked(
                    forChatID: newValue,
                    messages: model.messages.count
                )
                synchronizeModelSelection(forceChats: newValue != nil)
            }
            .onChange(of: sidebarSelection) { _, selection in
                HermternalSelectionOccupancyTrace.beginIfNeeded(
                    selection: selection,
                    messages: model.messages.count
                )
                HermternalSelectionOccupancyTrace.observerInvoked()
                HermternalSwitchTrace.selection(
                    "sidebarSelection.onChange",
                    selection: selection,
                    messages: model.messages.count
                )
                let event = SidebarSelectionEventAdapter.current()
                guard selection.count == 1,
                      let item = selection.first,
                      case let .chat(id) = item,
                      model.sessions.contains(where: { $0.id == id })
                else {
                    pendingOpenTask?.cancel()
                    pendingOpenTask = nil
                    pointerActivatedID = nil
                    programmaticSelectionID = nil
                    return
                }
                if programmaticSelectionID == id {
                    programmaticSelectionID = nil
                    pointerActivatedID = nil
                    return
                }
                if pointerActivatedID == id {
                    pointerActivatedID = nil
                    return
                }
                guard let event else {
                    // Mouse-down records belong to the pointer seam. With no
                    // record, this is keyboard/arrow navigation, which must
                    // invalidate an obsolete open before opening the new row.
                    scheduleOpen(for: id)
                    return
                }
                guard !event.isContextClick, !event.isModified else {
                    pendingOpenTask?.cancel()
                    pendingOpenTask = nil
                    pointerActivatedID = nil
                    return
                }
                // A plain pointer click is opened by the row's simultaneous
                // tap seam. Cancel any older open, but do not open here as
                // that would race the tap seam.
                pendingOpenTask?.cancel()
                pendingOpenTask = nil
                pointerActivatedID = nil
            }
            .onChange(of: archivedSelection) { _, selection in
                let event = SidebarSelectionEventAdapter.current()
                guard contentMode == .archived,
                      selection.count == 1,
                      let id = selection.first,
                      let session = model.archivedSessions.first(where: { $0.id == id })
                else {
                    pendingOpenTask?.cancel()
                    pendingOpenTask = nil
                    pointerActivatedID = nil
                    archivedPointerActivatedID = nil
                    programmaticArchivedSelectionID = nil
                    return
                }
                if programmaticArchivedSelectionID == id {
                    programmaticArchivedSelectionID = nil
                    if archivedPointerActivatedID != id {
                        archivedPointerActivatedID = nil
                    }
                    return
                }
                if archivedPointerActivatedID == id {
                    archivedPointerActivatedID = nil
                    return
                }
                guard let event else {
                    openArchivedImmediately(session)
                    return
                }
                guard !event.isContextClick, !event.isModified else {
                    pendingOpenTask?.cancel()
                    pendingOpenTask = nil
                    pointerActivatedID = nil
                    archivedPointerActivatedID = nil
                    return
                }
                pendingOpenTask?.cancel()
                pendingOpenTask = nil
                archivedPointerActivatedID = nil
            }
            .onChange(of: model.viewingArchivedSessionID) { _, _ in
                synchronizeModelSelection(forceChats: true)
            }
            .onChange(of: contentMode) { _, mode in
                if mode == .archived {
                    clearSidebarSelection("sidebarSelection.archiveMode")
                    programmaticSelectionID = nil
                } else {
                    archivedPointerActivatedID = nil
                    archivedSelection.removeAll()
                    programmaticArchivedSelectionID = nil
                    synchronizeModelSelection()
                }
            }
            .onChange(of: model.archivedSessions) { _, sessions in
                archivedSelection.formIntersection(Set(sessions.map(\.id)))
                synchronizeArchivedRouteSelection()
            }
            .onChange(of: model.sessions) { _, sessions in
                pruneSelection(validChatIDs: Set(sessions.map(\.id)))
            }
            .onChange(of: model.folders) { _, folders in
                pruneSelection(validFolderIDs: Set(folders.map(\.id)))
            }
            .onAppear {
                SidebarSelectionEventAdapter.start()
                synchronizeModelSelection()
            }
            .onDisappear {
                SidebarSelectionEventAdapter.stop()
                pendingOpenTask?.cancel()
                pendingOpenTask = nil
                purgePreparationTask?.cancel()
                archivedPointerActivatedID = nil
                purgePreparationTask = nil
                purgeRequestGeneration &+= 1
            }
    }
    private func setSidebarSelection(
        _ selection: Set<SidebarSelectionID>,
        event: String
    ) {
        HermternalSwitchTrace.selection(
            "\(event).before",
            selection: sidebarSelection,
            messages: model.messages.count
        )
        sidebarSelection = selection
        HermternalSwitchTrace.selection(
            "\(event).after",
            selection: selection,
            messages: model.messages.count
        )
    }

    private func clearSidebarSelection(_ event: String) {
        setSidebarSelection([], event: event)
    }


    /// Model navigation is authoritative. A transcript route can temporarily
    /// carry an id that is not in the live list (archived and New Chat both do
    /// this), so selection must be cleared rather than left as an inert tag.
    private func synchronizeModelSelection(forceChats: Bool = false) {
        if let archivedID = model.viewingArchivedSessionID {
            contentMode = .archived
            clearSidebarSelection("sidebarSelection.modelSynchronization.archived")
            programmaticSelectionID = nil
            pointerActivatedID = nil
            let selection = model.archivedSessions.contains(where: { $0.id == archivedID })
                ? [archivedID]
                : []
            if archivedSelection != Set(selection) {
                programmaticArchivedSelectionID = selection.first
                archivedSelection = Set(selection)
            }
            return
        }

        if forceChats {
            contentMode = .chats
            archivedSelection.removeAll()
            programmaticArchivedSelectionID = nil
            archivedPointerActivatedID = nil
        }
        if contentMode == .archived {
            archivedSelection.formIntersection(Set(model.archivedSessions.map(\.id)))
        }

        guard let liveID = model.selectedSessionID,
              model.sessions.contains(where: { $0.id == liveID })
        else {
            // A manually selected Archived mode has no live row to highlight
            // while its archived list is loading.
            clearSidebarSelection("sidebarSelection.modelSynchronization.empty")
            programmaticSelectionID = nil
            pointerActivatedID = nil
            return
        }

        guard contentMode == .chats else {
            clearSidebarSelection("sidebarSelection.modelSynchronization.mode")
            programmaticSelectionID = nil
            pointerActivatedID = nil
            return
        }

        let selection: Set<SidebarSelectionID> = [.chat(liveID)]
        guard sidebarSelection != selection else { return }
        programmaticSelectionID = liveID
        setSidebarSelection(selection, event: "sidebarSelection.modelSynchronization.live")
        pointerActivatedID = nil
    }

    /// Archived rows can arrive after the read-only route. Restore only that
    /// route's row here; live-chat selection remains untouched for ordinary
    /// archive list refreshes.
    private func synchronizeArchivedRouteSelection() {
        guard let archivedID = model.viewingArchivedSessionID else { return }
        contentMode = .archived
        clearSidebarSelection("sidebarSelection.archivedRouteSynchronization")
        programmaticSelectionID = nil
        guard model.archivedSessions.contains(where: { $0.id == archivedID }) else {
            return
        }
        if archivedPointerActivatedID != archivedID {
            archivedPointerActivatedID = nil
        }
        guard archivedSelection != Set([archivedID]) else { return }
        programmaticArchivedSelectionID = archivedID
        archivedSelection = [archivedID]
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
    private var purgePresented: Binding<Bool> {
        Binding(
            get: { purgeTarget != nil },
            set: { presented in
                if !presented { cancelPurge() }
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
    private func pruneSelection(
        validChatIDs: Set<String>? = nil,
        validFolderIDs: Set<String>? = nil
    ) {
        let chats = validChatIDs ?? Set(model.sessions.map(\.id))
        let folders = validFolderIDs ?? Set(model.folders.map(\.id))
        let pruned = SidebarSelectionPolicy.prunedSelection(
            sidebarSelection,
            validChatIDs: chats,
            validFolderIDs: folders
        )
        setSidebarSelection(pruned, event: "sidebarSelection.prune")
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

    private func requestPurge(
        chatIDs: [String],
        folderIDs: [String],
        mode: SessionPurgeActionMode
    ) {
        guard model.canPurgeSessions else { return }
        purgePreparationTask?.cancel()
        purgeRequestGeneration &+= 1
        let generation = purgeRequestGeneration
        purgeTarget = nil
        purgeConfirmation = ""
        purgePreparationTask = Task {
            guard !Task.isCancelled,
                  let plan = await model.preparePurge(
                      selectedChatIDs: chatIDs,
                      selectedFolderIDs: folderIDs,
                      mode: mode
                  ),
                  !Task.isCancelled,
                  generation == purgeRequestGeneration,
                  !plan.isEmpty
            else { return }
            purgeTarget = SidebarPurgeTarget(plan: plan)
            purgePreparationTask = nil
        }
    }

    private func purgeScope(for plan: SessionPurgePlan) -> String {
        let folderPhrase = plan.folderCount == 1
            ? "Folder"
            : "\(plan.folderCount) Folders"
        let chatNoun = plan.chatCount == 1 ? "Chat" : "Chats"
        switch plan.mode {
        case .chatsOnly:
            return "\(plan.chatCount) \(chatNoun)"
        case .foldersOnly, .foldersAndChats:
            return "\(folderPhrase) and \(plan.chatCount) \(chatNoun)"
        }
    }

    private func purgeTitle(for plan: SessionPurgePlan) -> String {
        "Permanently Delete \(purgeScope(for: plan))?"
    }

    private func completePurge(_ target: SidebarPurgeTarget) {
        guard SessionPurgeConfirmation.isExact(purgeConfirmation) else { return }
        purgeTarget = nil
        purgeConfirmation = ""
        purgePreparationTask?.cancel()
        purgePreparationTask = nil
        Task {
            await model.purge(plan: target.plan)
        }
    }

    private func cancelPurge() {
        purgeConfirmation = ""
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

    /// Explicit activation (including VoiceOver) opens immediately. Mark the
    /// id so the model's selection observer does not schedule a second open.
    private func openImmediately(_ session: ChatSession) {
        HermternalSwitchTrace.session(
            "open.requested.pointer",
            id: session.id,
            messages: model.messages.count
        )
        // Re-tapping the active, loaded live row has no work to do. Empty
        // transcripts and a failed gateway remain retryable.
        let isFailed = switch model.phase {
        case .failed: true
        default: false
        }
        if model.selectedSessionID == session.id,
           model.viewingArchivedSessionID == nil,
           !model.messages.isEmpty,
           !isFailed {
            return
        }
        model.userNavigationDidBegin()
        pointerActivatedID = session.id
        pendingOpenTask?.cancel()
        pendingOpenTask = model.requestOpen(session)
    }

    /// Explicit archived activation shares cancellation with native singleton
    /// selection, while the list remains the owner of its row surface.
    private func openArchivedImmediately(_ session: ChatSession) {
        guard model.viewingArchivedSessionID != session.id else {
            archivedPointerActivatedID = nil
            return
        }
        archivedPointerActivatedID = session.id
        model.userNavigationDidBegin()
        pendingOpenTask?.cancel()
        pendingOpenTask = nil
        pendingOpenTask = Task {
            guard !Task.isCancelled else { return }
            await model.openArchived(session)
            if !Task.isCancelled, archivedPointerActivatedID == session.id {
                archivedPointerActivatedID = nil
            }
        }
    }

    /// Native selection and scrolling update immediately. Each keyboard
    /// selection cancels prior work, and AppModel coalesces transcript
    /// publication by selection ticket without delaying one deliberate click.
    private func scheduleOpen(for id: String?) {
        pendingOpenTask?.cancel()
        pendingOpenTask = nil
        guard let id,
              let session = model.sessions.first(where: { $0.id == id })
        else { return }

        HermternalSwitchTrace.session(
            "open.requested.keyboard",
            id: id,
            messages: model.messages.count
        )
        model.userNavigationDidBegin()
        pointerActivatedID = id
        pendingOpenTask = model.requestOpen(session)
    }

}

/// The body-level values derived from sidebar ordering inputs. Selection is
/// deliberately not represented here; rows consume it independently.
private struct SidebarDerivedData {
    let sections: [SidebarSection]
    let scheduleRows: [SidebarRow]
    let scheduledIDs: Set<String>
    let visibleOrder: [SidebarSelectionID]
    let folderVisibleOrder: [SidebarSelectionID]
    let sessionsByID: [String: ChatSession]
    let foldersByID: [String: SidebarFolderTarget]
}

/// Keeps the ordering projection and its dependent identity maps resident
/// across SwiftUI body passes. The memo's input excludes selection, so a
/// selection-only update performs no ordering or map construction.
private final class SidebarDerivationCache {
    private var orderingMemo = SidebarOrderingMemo()
    private var derived: SidebarDerivedData?
    private var derivedRebuildCount = 0

    func resolve(
        sessions: [ChatSession],
        folders: [Folder],
        membership: [String: String],
        sortMode: SortMode,
        groupByDate: Bool,
        calendar: Calendar,
        now: Date
    ) -> SidebarDerivedData {
        let projection = orderingMemo.resolve(
            SidebarOrderingInputs(
                sessions: sessions,
                folders: folders,
                membership: membership,
                sortMode: sortMode,
                groupByDate: groupByDate,
                calendar: calendar,
                now: now
            )
        )
        guard derivedRebuildCount != orderingMemo.rebuildCount || derived == nil else {
            return derived!
        }

        let scheduleRows = projection.sections.first { $0.kind == .schedules }?.rows ?? []
        let sessionsByID = Dictionary(
            projection.sections.flatMap { $0.rows }.map { ($0.sessionID, $0.session) },
            uniquingKeysWith: { first, _ in first }
        )
        let foldersByID = Dictionary(
            folders.map { ($0.id, SidebarFolderTarget(id: $0.id, name: $0.name)) },
            uniquingKeysWith: { first, _ in first }
        )
        let next = SidebarDerivedData(
            sections: projection.sections,
            scheduleRows: scheduleRows,
            scheduledIDs: Set(scheduleRows.map(\.sessionID)),
            visibleOrder: projection.visibleOrder,
            folderVisibleOrder: projection.folderVisibleOrder,
            sessionsByID: sessionsByID,
            foldersByID: foldersByID
        )
        derived = next
        derivedRebuildCount = orderingMemo.rebuildCount
        return next
    }
}

private struct SidebarPurgeTarget: Identifiable {
    let plan: SessionPurgePlan

    var id: String {
        "\(plan.mode.rawValue):\(plan.chatIDs.joined(separator: ",")):"
            + "\(plan.folderIDs.joined(separator: ","))"
    }
}

private struct SidebarModeMenu: View {
    @Binding var mode: SidebarContentMode
    let onChatsSelected: () -> Void
    let onArchivedSelected: () -> Void

    var body: some View {
        Button {
            onChatsSelected()
            mode = .chats
        } label: {
            modeLabel("Chats", selected: mode == .chats)
        }
        Button {
            mode = .archived
            onArchivedSelected()
        } label: {
            modeLabel("Archived Chats", selected: mode == .archived)
        }
    }

    private func modeLabel(_ title: String, selected: Bool) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "checkmark")
                .opacity(selected ? 1 : 0)
        }
    }
}

private struct SidebarFolderDeletionTarget: Identifiable {
    let folders: [SidebarFolderTarget]
    let affectedChatCount: Int

    var id: String { folders.map(\.id).joined(separator: ",") }
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
