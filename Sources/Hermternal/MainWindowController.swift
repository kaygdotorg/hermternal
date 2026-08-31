import AppKit
import HermternalCore
import SwiftUI

private struct MainOverlayRoot: View {
    let model: AppModel
    let appearance: AppearanceSettings

    let reportToastRegion: ToastLayerHitRegionReporter?
    let reportHitTestFlags: ((Bool, Bool) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.isSearchPresented, let querying = model.searchQuerying {
                SearchPanel(
                    querying: querying,
                    activate: { location in
                        Task {
                            await model.open(at: location)
                            model.isSearchPresented = false
                        }
                    },
                    dismiss: { model.isSearchPresented = false }
                )
                .transition(.opacity)
                .zIndex(1)
            }
            ToastLayer(reportHitRegion: reportToastRegion)
                .environment(model.toastPresenter)
                .zIndex(2)
        }
        .animation(
            SearchPanel.panelAnimation(reduceMotion: reduceMotion),
            value: model.isSearchPresented
        )
        .environment(
            \.hermternalAccentColor,
            Color(nsColor: appearance.effectiveAccentColor)
        )
        .environment(
            \.hermternalAlwaysShowsChatMetadata,
            appearance.alwaysShowsChatMetadata
        )
        .tint(Color(nsColor: appearance.effectiveAccentColor))
        .task { publishHitTestFlags() }
        .onChange(of: model.isSearchPresented) { _, _ in
            publishHitTestFlags()
        }
        .onChange(of: model.toastPresenter.entries.count) { _, _ in
            publishHitTestFlags()
        }
    }

    private func publishHitTestFlags() {
        // `isSuppressed` is ObservationIgnored. Search presentation is the
        // same condition RootView uses to suppress toasts.
        reportHitTestFlags?(
            model.isSearchPresented,
            !model.isSearchPresented && !model.toastPresenter.entries.isEmpty
        )
    }
}

/// The window backdrop's own root.
///
/// It reads `AppearanceSettings` inside `body`, which is the whole point: the
/// class is `@Observable`, so a read here subscribes this hosted view to the
/// opacity slider and the Liquid Glass box. The shell used to hold two plain
/// `Double` and `Bool` copies and push them into `WindowBackdrop` by hand,
/// and an appearance change reached no code that pushed them again — the
/// Appearance pane moved its own readout and the window kept its launch
/// values. Nothing observes for us here; the read is the subscription.
/// Defended by windowBackdropFollowsTheOpacityDial.
private struct WindowBackdropRoot: View {
    let appearance: AppearanceSettings

    var body: some View {
        WindowBackdrop(
            opacity: appearance.backgroundOpacity,
            usesLiquidGlass: appearance.usesLiquidGlass
        )
    }
}

@MainActor
private final class MainOverlayHostingView: NSHostingView<MainOverlayRoot> {
    let model: AppModel

    private var toastHitRegion: CGRect?
    /// Copies of overlay flags for AppKit hit-testing. `hitTest` is not an
    /// Observation tracking context; IPS 213646 crashed in
    /// `ObservationTracking._AccessList` when this view read AppModel here
    /// during `NSDisplayCycleFlush`.
    private var searchPresented = false
    private var toastHitEnabled = false

    init(model: AppModel, appearance: AppearanceSettings) {
        self.model = model
        super.init(
            rootView: MainOverlayRoot(
                model: model,
                appearance: appearance,
                reportToastRegion: nil,
                reportHitTestFlags: nil
            )
        )
        installRoot(appearance: appearance)
        safeAreaRegions = []
        // This layer is pinned to all four edges of the shell. It must report
        // no size of its own: `sizingOptions` defaults to `.standardBounds`,
        // which makes a hosting view publish minimum, intrinsic, and maximum
        // size constraints, and pay for a zero, an infinite, and an ideal
        // measurement pass on every root assignment.
        sizingOptions = []
    }

    required init(rootView: MainOverlayRoot) {
        self.model = rootView.model
        super.init(rootView: rootView)
        safeAreaRegions = []
        sizingOptions = []
    }
    func update(appearance: AppearanceSettings) {
        installRoot(appearance: appearance)
    }

    private func installRoot(appearance: AppearanceSettings) {
        rootView = MainOverlayRoot(
            model: model,
            appearance: appearance,
            reportToastRegion: { [weak self] region in
                self?.toastHitRegion = region
            },
            reportHitTestFlags: { [weak self] searchPresented, toastHitEnabled in
                self?.searchPresented = searchPresented
                self?.toastHitEnabled = toastHitEnabled
            }
        )
    }


    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if searchPresented {
            return super.hitTest(point)
        }
        guard toastHitEnabled,
              let toastHitRegion
        else {
            return nil
        }
        let appKitRegion: NSRect
        if isFlipped {
            appKitRegion = toastHitRegion
        } else {
            appKitRegion = NSRect(
                x: toastHitRegion.minX,
                y: bounds.height - toastHitRegion.maxY,
                width: toastHitRegion.width,
                height: toastHitRegion.height
            )
        }
        guard appKitRegion.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

/// A responder in the hosted view tree for SwiftUI's standard sidebar action.
/// It owns no model or visibility state; the SwiftUI root supplies the action.
@MainActor
struct MainSplitVisibilityBridge: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> MainSplitVisibilityBridgeView {
        MainSplitVisibilityBridgeView(action: action)
    }

    func updateNSView(
        _ nsView: MainSplitVisibilityBridgeView,
        context: Context
    ) {
        nsView.action = action
    }
}

@MainActor
final class MainSplitVisibilityBridgeView: NSView {
    var action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        super.init(frame: .zero)
        isHidden = false
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func toggleSidebar(_ sender: Any?) {
        action()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // First time the hosted split exists in a window. This is the
        // SwiftUI tree, not the empty shell view.
        LaunchClock.mark("window.firstSwiftUIRender")
    }
}

/// AppKit owns the window and its full-window layers. SwiftUI owns the split,
/// its columns, and the visibility animation inside the single host.
@MainActor
final class MainShellViewController: NSViewController {
    private var model: AppModel
    private var appearance: AppearanceSettings
    private let onModelStateChanged: @MainActor () -> Void
    private let contentHosting: NSHostingController<MainSplitRoot>
    private var overlayHosting: MainOverlayHostingView?
    private var backgroundHosting: NSHostingView<WindowBackdropRoot>?
    private var hostedRootIsActive = true

    init(
        appearance: AppearanceSettings,
        model: AppModel,
        onModelStateChanged: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.appearance = appearance
        self.onModelStateChanged = onModelStateChanged
        self.contentHosting = NSHostingController(
            rootView: MainSplitRoot(
                model: model,
                appearance: appearance,
                onModelStateChanged: onModelStateChanged
            )
        )
        super.init(nibName: nil, bundle: nil)
        // The content host fills the shell, and the shell fills the window,
        // so it has no size of its own to publish. `sizingOptions` defaults to
        // `.standardBounds`, which had it carry a minimum-size and a
        // content-size constraint for content that wants neither, and answer a
        // zero, an infinite and an ideal proposal on either side of every real
        // layout pass — measured as eight proposals where two are the window's
        // actual size. None of that reaches the picture, and the composer is
        // measured once per extra proposal.
        contentHosting.sizingOptions = []
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(contentHosting)
        LaunchClock.mark("window.hostingView.begin")
        let contentView = contentHosting.view
        LaunchClock.mark("window.hostingView.end")
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        makeOverlay(model: model, appearance: appearance)
        LaunchClock.mark("window.shellViewDidLoad")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(appearance: AppearanceSettings, model: AppModel) {
        self.model = model
        self.appearance = appearance
        hostedRootIsActive = true
        contentHosting.rootView = MainSplitRoot(
            model: model,
            appearance: appearance,
            onModelStateChanged: onModelStateChanged,
            isActive: hostedRootIsActive
        )
        overlayHosting?.update(appearance: appearance)
        updateBackdrop(appearance)
        configureWindowIfAttached()
    }

    /// Installs the backdrop for one appearance object.
    ///
    /// Only the object is handed over. Its values are read inside
    /// `WindowBackdropRoot.body`, so the slider and the glass box reach the
    /// window through SwiftUI's own observation and not through a call that
    /// something has to remember to make.
    func updateBackdrop(_ appearance: AppearanceSettings) {
        self.appearance = appearance
        backgroundHosting?.rootView = WindowBackdropRoot(appearance: appearance)
    }

    var visibilityBridgeView: MainSplitVisibilityBridgeView? {
        findVisibilityBridge(in: contentHosting.view)
    }

    private func findVisibilityBridge(in root: NSView) -> MainSplitVisibilityBridgeView? {
        if let bridge = root as? MainSplitVisibilityBridgeView {
            return bridge
        }
        for child in root.subviews {
            if let bridge = findVisibilityBridge(in: child) {
                return bridge
            }
        }
        return nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindowIfAttached()
    }
    private func makeOverlay(model: AppModel, appearance: AppearanceSettings) {
        let hosting = MainOverlayHostingView(model: model, appearance: appearance)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        overlayHosting = hosting
    }

    private func configureWindowIfAttached() {
        guard view.window != nil else { return }
        // `isOpaque` and `backgroundColor` belong to `WindowBackdropView`,
        // which resolves both from the user's opacity and treatment and puts
        // them back when it leaves. The shell used to force them to `false`
        // and `.clear` here, on every attach and on every `update`, which
        // overwrote the backdrop's answer: an opacity of 100% asks for an
        // opaque window, and the hairline-alpha fill the backdrop chooses for
        // the translucent case is deliberately not `.clear`.
        // Defended by windowBackdropFollowsTheOpacityDial.
        //
        // Initial chrome is settled before the content host attaches.
        // Re-applying it here makes AppKit lay out the titlebar and toolbar
        // again during the launch turn.
        if backgroundHosting == nil {
            LaunchClock.mark("window.backdrop.begin")
            let hosting = NSHostingView(
                rootView: WindowBackdropRoot(appearance: appearance)
            )
            hosting.safeAreaRegions = []
            // Pinned to all four edges, exactly like the overlay: it reports
            // no size of its own.
            hosting.sizingOptions = []
            hosting.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hosting, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: view.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            backgroundHosting = hosting
            LaunchClock.mark("window.backdropHosted")
        }
        if overlayHosting == nil {
            makeOverlay(model: model, appearance: appearance)
        }
    }

    func prepareForWindowClose() {
        model.shutdownComposer()
        hostedRootIsActive = false
        contentHosting.rootView = MainSplitRoot(
            model: model,
            appearance: appearance,
            onModelStateChanged: onModelStateChanged,
            isActive: false
        )
        overlayHosting?.removeFromSuperview()
        overlayHosting = nil
        backgroundHosting?.removeFromSuperview()
        backgroundHosting = nil
    }
}

private extension NSToolbarItem.Identifier {
    static let sidebarOptions = NSToolbarItem.Identifier("Hermternal.sidebarOptions")
    static let sidebarToggle = NSToolbarItem.Identifier("Hermternal.sidebarToggle")
    static let detailControls = NSToolbarItem.Identifier("Hermternal.detailControls")
    static let newChat = NSToolbarItem.Identifier("Hermternal.newChat")
    static let transcriptWidth = NSToolbarItem.Identifier("Hermternal.transcriptWidth")
}

@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    private var model: AppModel
    private let appearance: AppearanceSettings
    private weak var toolbar: NSToolbar?
    private weak var visibilityBridge: MainSplitVisibilityBridgeView?
    private lazy var detailGroup = makeDetailGroup()
    private lazy var optionsItem = makeOptionsItem()
    private lazy var toggleItem = makeToggleItem()
    private lazy var newChatItem = makeCommandItem(
        identifier: .newChat,
        symbol: "plus",
        label: "New Chat",
        toolTip: "Start a new chat",
        action: #selector(firstDetailAction)
    )
    /// The transcript's measure, in the slot the reload button held.
    ///
    /// Reload is a rare command with a standard key equivalent, so it belongs in
    /// the View menu and on ⌘R, not in a slot the reader passes every time they
    /// look at the window. The measure is the opposite: it is the one thing
    /// about a transcript a reader changes while reading it.
    private lazy var widthItem = makeCommandItem(
        identifier: .transcriptWidth,
        symbol: appearance.transcriptWidthMode.other.symbolName,
        label: appearance.transcriptWidthMode.other.label,
        toolTip: appearance.transcriptWidthMode.other.actionDescription,
        action: #selector(toggleTranscriptWidth)
    )
    private lazy var optionsMenu: NSMenu = makeOptionsMenu()

    init(
        model: AppModel,
        appearance: AppearanceSettings,
        visibilityBridge: MainSplitVisibilityBridgeView?
    ) {
        self.model = model
        self.appearance = appearance
        self.visibilityBridge = visibilityBridge
        super.init()
        // The View menu flips the measure too, so the item follows the store
        // rather than only its own click. The store posts from the main actor,
        // so the block runs there: the item is relabelled in the same turn as
        // the command, and the toolbar never states a measure the transcript
        // has already left. No teardown: this controller belongs to the one
        // main window, which belongs to the process.
        NotificationCenter.default.addObserver(
            forName: TranscriptWidthStore.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.configureWidthItem(commandable: self.widthItem.isEnabled)
            }
        }
        update(model: model)
    }

    func setVisibilityBridge(_ bridge: MainSplitVisibilityBridgeView?) {
        visibilityBridge = bridge
        guard showsWorkspaceChrome else { return }
        toggleItem.target = bridge
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "Hermternal.mainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        self.toolbar = toolbar
        updateToolbarVisibility()
        return toolbar
    }

    func update(model: AppModel) {
        self.model = model
        guard showsWorkspaceChrome else {
            updateToolbarVisibility()
            return
        }

        let commandable = !model.isSearchPresented
        optionsItem.isEnabled = commandable
        toggleItem.isEnabled = commandable
        detailGroup.isEnabled = commandable
        configureDetailItems(searchPresented: model.isSearchPresented)
        updateToolbarVisibility()
    }
    
    private func makeDetailGroup() -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: .detailControls)
        group.label = "Chat"
        group.paletteLabel = "Chat"
        group.subitems = [newChatItem, widthItem]
        group.isBordered = true
        group.isEnabled = true
        group.controlRepresentation = .expanded
        group.selectionMode = .momentary
        group.autovalidates = false
        return group
    }

    /// Workspace chrome can paint. Network work may still be in flight, so
    /// this is visibility, not per-item enablement.
    private var showsWorkspaceChrome: Bool {
        model.phase.presentsWorkspace
    }

    struct DetailCommandEnablement: Equatable {
        var showsWorkspaceChrome: Bool
        var isNewChatEnabled: Bool
        var isRestoreEnabled: Bool
        var areChromeCommandsEnabled: Bool

        /// New Chat and Restore follow the state their handlers accept.
        /// Chrome visibility is `presentsWorkspace` and stays separate.
        static func resolve(
            phase: AppModel.Phase,
            searchPresented: Bool,
            viewingArchived: Bool
        ) -> Self {
            let chrome = phase.presentsWorkspace
            let handlerReady = phase == .ready && !searchPresented
            return Self(
                showsWorkspaceChrome: chrome,
                isNewChatEnabled: handlerReady && !viewingArchived,
                isRestoreEnabled: handlerReady && viewingArchived,
                areChromeCommandsEnabled: chrome && !searchPresented
            )
        }

        var isDetailActionEnabled: Bool { isNewChatEnabled || isRestoreEnabled }
    }

    private func updateToolbarVisibility() {
        guard let toolbar else { return }
        let chromeIdentifiers: Set<NSToolbarItem.Identifier> = [
            .sidebarOptions,
            .sidebarToggle,
            .sidebarTrackingSeparator,
            .detailControls
        ]
        if showsWorkspaceChrome {
            for (index, identifier) in toolbarDefaultItemIdentifiers(toolbar).enumerated()
                where chromeIdentifiers.contains(identifier)
                    && !toolbar.items.contains(where: { $0.itemIdentifier == identifier }) {
                toolbar.insertItem(
                    withItemIdentifier: identifier,
                    at: min(index, toolbar.items.count)
                )
            }
        } else {
            for (index, item) in toolbar.items.enumerated().reversed()
                where chromeIdentifiers.contains(item.itemIdentifier) {
                toolbar.removeItem(at: index)
            }
        }
    }

    private func configureDetailItems(searchPresented: Bool) {
        let viewingArchived = archivedSession != nil
        if viewingArchived {
            newChatItem.image = NSImage(
                systemSymbolName: "archivebox",
                accessibilityDescription: "Restore"
            )
            newChatItem.label = "Restore"
            newChatItem.paletteLabel = "Restore"
            newChatItem.toolTip = "Restore chat"
        } else {
            newChatItem.image = NSImage(
                systemSymbolName: "plus",
                accessibilityDescription: "New Chat"
            )
            newChatItem.label = "New Chat"
            newChatItem.paletteLabel = "New Chat"
            newChatItem.toolTip = "Start a new chat"
        }
        let enablement = DetailCommandEnablement.resolve(
            phase: model.phase,
            searchPresented: searchPresented,
            viewingArchived: viewingArchived
        )
        newChatItem.isEnabled = enablement.isDetailActionEnabled
        configureWidthItem(commandable: enablement.areChromeCommandsEnabled)
    }

    /// The width toggle states the measure it would give the reader next, so the
    /// button reads as an action rather than as a state.
    ///
    /// The measure belongs to the transcript and not to the chat, so this item
    /// is the same for an archived chat as for a live one. The archived chat's
    /// Copy Link went with the reload button it shared this slot with: it is on
    /// the archived row's own menu in the sidebar, beside Restore, where every
    /// other per-chat command already is.
    private func configureWidthItem(commandable: Bool) {
        let next = appearance.transcriptWidthMode.other
        widthItem.image = NSImage(
            systemSymbolName: next.symbolName,
            accessibilityDescription: next.label
        )
        widthItem.label = next.label
        widthItem.paletteLabel = next.label
        widthItem.toolTip = next.actionDescription
        widthItem.isEnabled = commandable
    }

    private var archivedSession: ChatSession? {
        guard let id = model.viewingArchivedSessionID else { return nil }
        return model.archivedSessions.first { $0.id == id }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItemIdentifiers(isReady: showsWorkspaceChrome)
    }

    /// A signed-out launch has no actionable toolbar controls. Supplying only
    /// the two flexible spaces preserves the complete blank-toolbar geometry
    /// without asking AppKit to create and immediately remove ready-only items.
    static func defaultItemIdentifiers(
        isReady: Bool
    ) -> [NSToolbarItem.Identifier] {
        guard isReady else { return [.flexibleSpace, .flexibleSpace] }
        return [
            .flexibleSpace,
            .sidebarOptions,
            .sidebarToggle,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            .detailControls
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .sidebarOptions,
            .sidebarToggle,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            .detailControls
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard showsWorkspaceChrome else { return nil }
        switch identifier {
        case .sidebarOptions:
            return optionsItem
        case .sidebarToggle:
            return toggleItem
        case .detailControls:
            return detailGroup
        case .newChat:
            return newChatItem
        case .transcriptWidth:
            return widthItem
        default:
            return nil
        }
    }

    private func makeOptionsItem() -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .sidebarOptions)
        item.menu = optionsMenu
        item.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "Options"
        )
        item.label = "Options"
        item.paletteLabel = "Options"
        item.toolTip = "Sidebar options"
        item.isBordered = true
        item.isEnabled = true
        item.autovalidates = false
        item.showsIndicator = false
        return item
    }

    private func makeToggleItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .sidebarToggle)
        item.image = NSImage(
            systemSymbolName: "sidebar.leading",
            accessibilityDescription: "Sidebar"
        )
        item.label = "Sidebar"
        item.paletteLabel = "Sidebar"
        item.toolTip = "Show or hide sidebar"
        item.action = #selector(MainSplitVisibilityBridgeView.toggleSidebar(_:))
        item.target = visibilityBridge
        item.isBordered = true
        item.isEnabled = true
        item.autovalidates = false
        return item
    }

    private func makeCommandItem(
        identifier: NSToolbarItem.Identifier,
        symbol: String,
        label: String,
        toolTip: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip
        item.action = action
        item.target = self
        item.isBordered = true
        item.isEnabled = true
        item.autovalidates = false
        return item
    }

    private func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // NSMenuToolbarItem reserves its first item as the pull-down title.
        // Keep an empty title so Chats remains the first visible command.
        menu.addItem(NSMenuItem())
        menu.addItem(withTitle: "Chats", action: #selector(showChats), keyEquivalent: "")
        menu.addItem(
            withTitle: "Archived Chats",
            action: #selector(showArchivedChats),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        if model.sidebarContentMode == .chats {
            menu.addItem(
                withTitle: "New Folder…",
                action: #selector(newFolder),
                keyEquivalent: ""
            )
            menu.addItem(.separator())
            let sortMenu = NSMenu()
            for mode in SortMode.allCases {
                let item = NSMenuItem(
                    title: mode.sidebarTitle,
                    action: #selector(selectSortMode(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = mode
                item.state = model.sortMode == mode ? .on : .off
                sortMenu.addItem(item)
            }
            let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
            sortItem.submenu = sortMenu
            menu.addItem(sortItem)
            menu.addItem(.separator())
            let groupItem = NSMenuItem(
                title: model.groupByDate ? "Ungroup by Date" : "Group by Date",
                action: #selector(toggleGroupByDate),
                keyEquivalent: ""
            )
            groupItem.target = self
            menu.addItem(groupItem)
        }
        for item in menu.items {
            item.target = self
            item.isEnabled = model.phase == .ready && !model.isSearchPresented
        }
    }

    @objc private func showChats() {
        model.showChatsList()
    }

    @objc private func showArchivedChats() {
        Task { await model.showArchivedList() }
    }

    @objc private func newFolder() {
        model.beginFolderCreate()
    }

    @objc private func selectSortMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? SortMode else { return }
        Task { await model.setSortMode(mode) }
    }

    @objc private func toggleGroupByDate() {
        Task { await model.setGroupByDate(!model.groupByDate) }
    }

    @objc private func firstDetailAction() {
        if let archivedSession {
            Task { await model.restoreArchived(archivedSession) }
        } else {
            Task { await model.newChatCommand() }
        }
    }

    /// Both measures are one command: the item says which one it would give.
    ///
    /// The item is not relabelled here. The store's notification does it, in
    /// this same turn, and it is the one path the View menu takes too.
    @objc private func toggleTranscriptWidth() {
        appearance.toggleTranscriptWidth()
    }
}

/// Chrome and the restored frame must be complete before the content host
/// attaches. `prepare` asserts that the content host is still absent.
/// The window orders front after `prepare` and before `attach`, so the first
/// SwiftUI layout does not block the first visible frame.
@MainActor
enum MainWindowStartupConfiguration {
    static let defaultContentSize = NSSize(width: 1_040, height: 720)
    static let minimumContentSize = NSSize(width: 760, height: 480)
    static let frameAutosaveName = "Hermternal.MainWindow"

    static func prepare(
        _ window: NSWindow,
        restoringFrameNamed autosaveName: String? = frameAutosaveName
    ) {
        precondition(
            window.contentViewController == nil,
            "Configure main window chrome before attaching its content host."
        )

        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // WindowServer resolves this ordering transition asynchronously. Keep
        // it disabled until the initial key-window callback restores defaults.
        window.animationBehavior = .none
        window.identifier = NSUserInterfaceItemIdentifier(frameAutosaveName)
        window.contentMinSize = minimumContentSize

        guard let autosaveName else {
            setDefaultFrame(on: window)
            return
        }

        window.setFrameAutosaveName(autosaveName)
        guard window.setFrameUsingName(autosaveName),
              hasValidRestoredFrame(window)
        else {
            setDefaultFrame(on: window)
            return
        }
    }

    /// Attaches the content host and keeps the frame `prepare` chose.
    ///
    /// Assigning `contentViewController` makes AppKit size the window to the
    /// content view's Auto Layout fitting size, and a hosted SwiftUI root that
    /// fills whatever it is given has no fitting size of its own. Measured on
    /// macOS 26.6.2: a window at 1360x720 dropped to 760x480 — the content
    /// minimum — the moment the host was assigned. So the frame is captured
    /// and put back.
    ///
    /// The alternative was answering with the shell's `preferredContentSize`,
    /// which is what this window used to do. `NSWindow` reads that as a size
    /// the window must hold rather than one to open at: it discarded the
    /// restored frame every launch and then refused every wider frame,
    /// including the accessibility resizes a tiling window manager makes.
    /// Defended by mainWindowStaysResizableAfterContentAttachment.
    static func attach(_ contentHost: NSViewController, to window: NSWindow) {
        LaunchClock.mark("window.attach.begin")
        let preparedFrame = window.frame
        // Size the host to the prepared content rect first. On a visible
        // window, an unsized hosted split reports a fitting size at the
        // content minimum and AppKit shrinks the frame before we can put
        // it back. Measured as a 66 ms second layout plus a visible jump.
        let contentSize = window.contentRect(forFrameRect: preparedFrame).size
        contentHost.view.setFrameSize(contentSize)
        // The window is already ordered front. Mouse tracking during this
        // layout must not walk the overlay before SwiftUI publishes flags.
        let shouldIgnoreMouse = window.isVisible
        if shouldIgnoreMouse {
            window.ignoresMouseEvents = true
        }
        window.contentViewController = contentHost
        LaunchClock.mark("window.contentViewAssigned")
        if window.frame != preparedFrame {
            window.setFrame(preparedFrame, display: false)
            LaunchClock.mark("window.frameRestored")
        }
        if shouldIgnoreMouse {
            window.ignoresMouseEvents = false
        }
        LaunchClock.mark("window.attach.end")
    }

    fileprivate static func setDefaultFrame(on window: NSWindow) {
        window.setContentSize(defaultContentSize)
        window.center()
    }

    private static func hasValidRestoredFrame(_ window: NSWindow) -> Bool {
        let frame = window.frame
        return frame.width.isFinite
            && frame.height.isFinite
            && frame.width >= window.contentMinSize.width
            && frame.height >= window.contentMinSize.height
    }
}
enum MainWindowInitialOrderAnimationState: Equatable {
    case suppressing
    case restored

    var animationBehavior: NSWindow.AnimationBehavior {
        switch self {
        case .suppressing:
            .none
        case .restored:
            .default
        }
    }

    mutating func restoreAfterFirstKey() -> Bool {
        guard self == .suppressing else { return false }
        self = .restored
        return true
    }
}



@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MainWindowController()
    private(set) var model: AppModel?
    private var appearance: AppearanceSettings?
    private var registry: CapabilityRegistry?
    private var debugModules: (any DebugModuleCapability)?
    private var shellController: MainShellViewController?
    private var toolbarController: MainToolbarController?
    private var hasShownWindow = false
    private var initialOrderAnimationState: MainWindowInitialOrderAnimationState = .suppressing

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(
        appearance: AppearanceSettings,
        model: AppModel,
        registry: CapabilityRegistry,
        debugModules: any DebugModuleCapability,
        onModelStateChanged: @escaping @MainActor () -> Void
    ) {
        LaunchClock.mark("window.show.begin")
        self.model = model
        self.appearance = appearance
        self.registry = registry
        self.debugModules = debugModules
        var didOrderFrontThisTurn = false
        if let shellController {
            shellController.update(appearance: appearance, model: model)
            toolbarController?.update(model: model)
        } else {
            LaunchClock.mark("window.shellConstruct.begin")
            let shellController = MainShellViewController(
                appearance: appearance,
                model: model,
                onModelStateChanged: { [weak self] in
                    onModelStateChanged()
                    self?.refreshChrome()
                }
            )
            LaunchClock.mark("window.shellConstruct.end")
            self.shellController = shellController
            // The shell carries no `preferredContentSize`; see
            // `MainWindowStartupConfiguration.attach` for what that cost.
            // Defended by mainWindowStaysResizableAfterContentAttachment.
            LaunchClock.mark("window.create.begin")
            let window = NSWindow(
                contentRect: NSRect(
                    origin: .zero,
                    size: MainWindowStartupConfiguration.defaultContentSize
                ),
                styleMask: [
                    .titled,
                    .closable,
                    .miniaturizable,
                    .resizable,
                    .fullSizeContentView
                ],
                backing: .buffered,
                defer: false
            )
            LaunchClock.mark("window.create.end")
            // Configure the final frame and titlebar before AppKit instantiates
            // the content host and toolbar. The launch profile showed each of
            // those mutations otherwise triggering titlebar layout separately.
            LaunchClock.mark("window.prepare.begin")
            MainWindowStartupConfiguration.prepare(window)
            LaunchClock.mark("window.prepare.end")
            window.delegate = self
            // Toolbar does not walk the hosted split. The bridge is bound
            // after the first yield, once attach has built the SwiftUI tree.
            LaunchClock.mark("window.toolbar.begin")
            let toolbarController = MainToolbarController(
                model: model,
                appearance: appearance,
                visibilityBridge: nil
            )
            self.toolbarController = toolbarController
            window.toolbar = toolbarController.makeToolbar()
            LaunchClock.mark("window.toolbar.end")
            self.window = window
            // Measured: attach laid out the full ChatView tree for ~300 ms
            // before the window could order front. Native chrome and the
            // restored frame are already on the window, so order it first.
            // Attach still owns the first SwiftUI layout; it just no longer
            // blocks the first visible frame. No placeholder chrome.
            LaunchClock.mark("window.orderFront.begin")
            window.makeKeyAndOrderFront(nil)
            LaunchClock.mark("window.orderedFront")
            MainWindowStartupConfiguration.attach(shellController, to: window)
            didOrderFrontThisTurn = true
        }
        if let window {
            if !didOrderFrontThisTurn {
                window.makeKeyAndOrderFront(nil)
            }
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.toolbarController?.setVisibilityBridge(
                    self?.shellController?.visibilityBridgeView
                )
                // Backdrop installs in viewDidAppear, after attach returns.
                LaunchClock.reportBreakdown()
            }
            if !hasShownWindow {
                hasShownWindow = true
                Task { @MainActor [weak window] in
                    await Task.yield()
                    guard let window else { return }
                    let frame = window.frame
                    let currentFrameIsValid =
                        frame.width.isFinite
                        && frame.height.isFinite
                        && frame.width >= window.contentMinSize.width
                        && frame.height >= window.contentMinSize.height
                    // `prepare` already restored or centered this window. A
                    // second reset after the first yield is only needed if
                    // attachment made the frame invalid.
                    if !currentFrameIsValid {
                        MainWindowStartupConfiguration.setDefaultFrame(on: window)
                    }
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshChrome() {
        if let model {
            toolbarController?.update(model: model)
        }
        toolbarController?.setVisibilityBridge(shellController?.visibilityBridgeView)
        if let appearance {
            shellController?.updateBackdrop(appearance)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard initialOrderAnimationState.restoreAfterFirstKey(),
              let window
        else { return }
        window.animationBehavior = initialOrderAnimationState.animationBehavior
    }

    func windowWillClose(_ notification: Notification) {
        shellController?.prepareForWindowClose()
    }
}

@MainActor
final class HermternalApplicationDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var appearance: AppearanceSettings?
    private var registry: CapabilityRegistry?
    private var debugModules: (any DebugModuleCapability)?
    private var fixtureMode = false
    private var capabilityRefresh: (@MainActor () -> Void)?
    private var didFinishLaunching = false
    private var didStartRestore = false


    func configure(
        appearance: AppearanceSettings,
        model: AppModel,
        registry: CapabilityRegistry,
        debugModules: any DebugModuleCapability,
        fixtureMode: Bool,
        capabilityRefresh: @escaping @MainActor () -> Void
    ) {
        self.appearance = appearance
        self.model = model
        self.registry = registry
        self.debugModules = debugModules
        self.fixtureMode = fixtureMode
        self.capabilityRefresh = capabilityRefresh
        launchIfNeeded()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        LaunchClock.mark("applicationDidFinishLaunching")
        launchIfNeeded()
        #if DEBUG
        emitLaunchWindowProbeIfRequested()
        #endif
    }

    #if DEBUG
    private func emitLaunchWindowProbeIfRequested() {
        guard ProcessInfo.processInfo.environment["HERMTERNAL_LAUNCH_WINDOW_PROBE"] == "1" else {
            return
        }
        Task { @MainActor in
            await Task.yield()
            await Task.yield()
            let windowDescriptions = NSApp.windows.map {
                "\($0.className):title=\($0.title.debugDescription):visible=\($0.isVisible):frame=\(NSStringFromRect($0.frame))"
            }
            let visibleWindows = NSApp.windows.filter(\.isVisible)
            let visibleContentFrames = visibleWindows.map {
                NSStringFromRect($0.contentRect(forFrameRect: $0.frame))
            }
            print("HERMTERNAL_LAUNCH_WINDOWS=\(windowDescriptions.joined(separator: "|"))")
            print("HERMTERNAL_LAUNCH_VISIBLE_WINDOW_COUNT=\(visibleWindows.count)")
            print("HERMTERNAL_LAUNCH_VISIBLE_WINDOW_CONTENT_FRAMES=\(visibleContentFrames.joined(separator: "|"))")
            print("HERMTERNAL_LAUNCH_WINDOW_COUNT=\(NSApp.windows.count)")
            NSApp.terminate(nil)
        }
    }
    #endif


    func showMainWindowIfReady() -> Bool {
        guard let appearance,
              let model,
              let registry,
              let debugModules
        else { return false }
        MainWindowController.shared.show(
            appearance: appearance,
            model: model,
            registry: registry,
            debugModules: debugModules,
            onModelStateChanged: { [weak self] in
                self?.capabilityRefresh?()
            }
        )
        return true
    }

    private func launchIfNeeded() {
        guard didFinishLaunching else { return }
        if fixtureMode {
            _ = showMainWindowIfReady()
            return
        }
        guard !didStartRestore else {
            _ = showMainWindowIfReady()
            return
        }
        guard let model else { return }
        didStartRestore = true
        model.publishRestoredTranscript()
        _ = showMainWindowIfReady()
        Task { @MainActor [weak self] in
            await self?.model?.restoreOrPromptSignIn()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        _ = showMainWindowIfReady()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { route(url) }
    }

    private func route(_ url: URL) {
        guard let model else { return }
        _ = showMainWindowIfReady()
        guard let link = MessageDeepLink(url: url) else {
            model.toastPresenter.error("Unsupported message link")
            return
        }
        guard let expectedHost = model.configuredGatewayHost,
              expectedHost.caseInsensitiveCompare(link.gatewayHost) == .orderedSame
        else {
            model.toastPresenter.error("Message belongs to a different gateway")
            return
        }
        model.route(link.destination)
    }
}
