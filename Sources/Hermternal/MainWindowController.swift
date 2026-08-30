import AppKit
import HermternalCore
import SwiftUI

private struct MainOverlayRoot: View {
    let model: AppModel
    let appearance: AppearanceSettings

    let reportToastRegion: ToastLayerHitRegionReporter?
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
    }
}

@MainActor
private final class MainOverlayHostingView: NSHostingView<MainOverlayRoot> {
    let model: AppModel

    private var toastHitRegion: CGRect?

    init(model: AppModel, appearance: AppearanceSettings) {
        self.model = model
        super.init(
            rootView: MainOverlayRoot(
                model: model,
                appearance: appearance,
                reportToastRegion: nil
            )
        )
        rootView = MainOverlayRoot(
            model: model,
            appearance: appearance,
            reportToastRegion: { [weak self] region in
                self?.toastHitRegion = region
            }
        )
        safeAreaRegions = []
    }

    required init(rootView: MainOverlayRoot) {
        self.model = rootView.model
        super.init(rootView: rootView)
        safeAreaRegions = []
    }
    func update(appearance: AppearanceSettings) {
        rootView = MainOverlayRoot(
            model: model,
            appearance: appearance,
            reportToastRegion: { [weak self] region in
                self?.toastHitRegion = region
            }
        )
    }


    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if model.isSearchPresented {
            return super.hitTest(point)
        }
        guard !model.toastPresenter.isSuppressed,
              !model.toastPresenter.entries.isEmpty,
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
    private var backgroundHosting: NSHostingView<WindowBackdrop>?
    private var hostedRootIsActive = true
    private var backdropOpacity = 1.0
    private var backdropUsesLiquidGlass = false

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
        backdropOpacity = appearance.backgroundOpacity
        backdropUsesLiquidGlass = appearance.usesLiquidGlass
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(contentHosting)
        let contentView = contentHosting.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        makeOverlay(model: model, appearance: appearance)
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

        backdropOpacity = appearance.backgroundOpacity
        backdropUsesLiquidGlass = appearance.usesLiquidGlass
        backgroundHosting?.rootView = WindowBackdrop(
            opacity: backdropOpacity,
            usesLiquidGlass: backdropUsesLiquidGlass
        )
        configureWindowIfAttached()
    }

    func updateBackdrop(_ appearance: AppearanceSettings) {
        backdropOpacity = appearance.backgroundOpacity
        backdropUsesLiquidGlass = appearance.usesLiquidGlass
        backgroundHosting?.rootView = WindowBackdrop(
            opacity: backdropOpacity,
            usesLiquidGlass: backdropUsesLiquidGlass
        )
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
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        if backgroundHosting == nil {
            let hosting = NSHostingView(
                rootView: WindowBackdrop(
                    opacity: backdropOpacity,
                    usesLiquidGlass: backdropUsesLiquidGlass
                )
            )
            hosting.safeAreaRegions = []
            hosting.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hosting, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: view.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            backgroundHosting = hosting
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
    static let reloadChats = NSToolbarItem.Identifier("Hermternal.reloadChats")
}

@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    private var model: AppModel
    private weak var toolbar: NSToolbar?
    private weak var visibilityBridge: MainSplitVisibilityBridgeView?
    private let detailGroup = NSToolbarItemGroup(itemIdentifier: .detailControls)
    private lazy var optionsItem = makeOptionsItem()
    private lazy var toggleItem = makeToggleItem()
    private lazy var newChatItem = makeCommandItem(
        identifier: .newChat,
        symbol: "plus",
        label: "New Chat",
        toolTip: "Start a new chat",
        action: #selector(firstDetailAction)
    )
    private lazy var reloadItem = makeCommandItem(
        identifier: .reloadChats,
        symbol: "arrow.clockwise",
        label: "Reload",
        toolTip: "Reload chats",
        action: #selector(secondDetailAction)
    )
    private lazy var optionsMenu: NSMenu = makeOptionsMenu()

    init(model: AppModel, visibilityBridge: MainSplitVisibilityBridgeView?) {
        self.model = model
        self.visibilityBridge = visibilityBridge
        super.init()
        detailGroup.label = "Chat"
        detailGroup.paletteLabel = "Chat"
        detailGroup.subitems = [newChatItem, reloadItem]
        detailGroup.isBordered = true
        detailGroup.isEnabled = true
        detailGroup.controlRepresentation = .expanded
        detailGroup.selectionMode = .momentary
        detailGroup.autovalidates = false
        update(model: model)
    }

    func setVisibilityBridge(_ bridge: MainSplitVisibilityBridgeView?) {
        visibilityBridge = bridge
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
        let commandable = isReadyPhase && !model.isSearchPresented
        optionsItem.isEnabled = commandable
        toggleItem.isEnabled = commandable
        detailGroup.isEnabled = commandable
        configureDetailItems(commandable: commandable)
        updateToolbarVisibility()
    }
    
    private var isReadyPhase: Bool {
        model.phase == .ready
    }

    private func updateToolbarVisibility() {
        guard let toolbar else { return }
        let chromeIdentifiers: Set<NSToolbarItem.Identifier> = [
            .sidebarOptions,
            .sidebarToggle,
            .sidebarTrackingSeparator,
            .detailControls
        ]
        if isReadyPhase {
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

    private func configureDetailItems(commandable: Bool) {
        if let archivedSession {
            newChatItem.image = NSImage(
                systemSymbolName: "archivebox",
                accessibilityDescription: "Restore"
            )
            newChatItem.label = "Restore"
            newChatItem.paletteLabel = "Restore"
            newChatItem.toolTip = "Restore chat"
            reloadItem.image = NSImage(
                systemSymbolName: "link",
                accessibilityDescription: "Copy Link"
            )
            reloadItem.label = "Copy Link"
            reloadItem.paletteLabel = "Copy Link"
            reloadItem.toolTip = "Copy chat link"
            detailGroup.isEnabled = commandable && archivedSession != nil
        } else {
            newChatItem.image = NSImage(
                systemSymbolName: "plus",
                accessibilityDescription: "New Chat"
            )
            newChatItem.label = "New Chat"
            newChatItem.paletteLabel = "New Chat"
            newChatItem.toolTip = "Start a new chat"
            reloadItem.image = NSImage(
                systemSymbolName: "arrow.clockwise",
                accessibilityDescription: "Reload"
            )
            reloadItem.label = "Reload"
            reloadItem.paletteLabel = "Reload"
            reloadItem.toolTip = "Reload chats"
        }
        newChatItem.isEnabled = commandable
        reloadItem.isEnabled = commandable
    }

    private var archivedSession: ChatSession? {
        guard let id = model.viewingArchivedSessionID else { return nil }
        return model.archivedSessions.first { $0.id == id }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
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
        switch identifier {
        case .sidebarOptions:
            optionsItem
        case .sidebarToggle:
            toggleItem
        case .detailControls:
            detailGroup
        case .newChat:
            newChatItem
        case .reloadChats:
            reloadItem
        default:
            nil
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

    @objc private func secondDetailAction() {
        if let archivedSession {
            model.copyDeepLink(for: archivedSession)
        } else {
            Task { await model.loadSessions() }
        }
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
    private var restoredValidFrame = false

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
        self.model = model
        self.appearance = appearance
        self.registry = registry
        self.debugModules = debugModules
        if let shellController {
            shellController.update(appearance: appearance, model: model)
            toolbarController?.update(model: model)
        } else {
            let shellController = MainShellViewController(
                appearance: appearance,
                model: model,
                onModelStateChanged: { [weak self] in
                    onModelStateChanged()
                    self?.refreshChrome()
                }
            )
            self.shellController = shellController
            shellController.preferredContentSize = NSSize(width: 1_040, height: 720)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_040, height: 720),
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
            window.contentViewController = shellController
            let toolbarController = MainToolbarController(
                model: model,
                visibilityBridge: shellController.visibilityBridgeView
            )
            self.toolbarController = toolbarController
            window.toolbar = toolbarController.makeToolbar()
            toolbarController.update(model: model)
            window.title = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("Hermternal.MainWindow")
            window.setFrameAutosaveName("Hermternal.MainWindow")
            window.contentMinSize = NSSize(width: 760, height: 480)
            window.delegate = self
            let restored = window.setFrameUsingName("Hermternal.MainWindow")
            let frame = window.frame
            restoredValidFrame =
                restored
                && frame.width.isFinite
                && frame.height.isFinite
                && frame.width >= window.contentMinSize.width
                && frame.height >= window.contentMinSize.height
            if !restoredValidFrame {
                window.setContentSize(NSSize(width: 1_040, height: 720))
                window.center()
            }
            self.window = window
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.toolbarController?.setVisibilityBridge(
                    self?.shellController?.visibilityBridgeView
                )
            }
            if !hasShownWindow {
                hasShownWindow = true
                Task { @MainActor [weak self, weak window] in
                    await Task.yield()
                    guard let self, let window else { return }
                    let frame = window.frame
                    let currentFrameIsValid =
                        frame.width.isFinite
                        && frame.height.isFinite
                        && frame.width >= window.contentMinSize.width
                        && frame.height >= window.contentMinSize.height
                    if !self.restoredValidFrame || !currentFrameIsValid {
                        window.setContentSize(NSSize(width: 1_040, height: 720))
                        window.center()
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
        launchIfNeeded()
    }

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
        guard didFinishLaunching,
              showMainWindowIfReady(),
              !fixtureMode,
              !didStartRestore,
              let model
        else { return }
        didStartRestore = true
        Task { @MainActor in
            await model.restoreOrPromptSignIn()
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
