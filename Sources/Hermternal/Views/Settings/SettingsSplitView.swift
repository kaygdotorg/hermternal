import AppKit
import HermternalCore
import SwiftUI

/// Bridges the settings columns to AppKit's split-view item that owns the
/// titlebar-integrated sidebar geometry.
struct SettingsSplitView: NSViewControllerRepresentable {
    let appearance: AppearanceSettings
    let model: AppModel
    let registry: CapabilityRegistry
    let debugModules: any DebugModuleCapability
    @Binding var selection: SettingsSection?

    func makeNSViewController(context: Context) -> SettingsSplitViewController {
        SettingsSplitViewController(
            appearance: appearance,
            model: model,
            registry: registry,
            debugModules: debugModules,
            selection: $selection
        )
    }

    func updateNSViewController(
        _ controller: SettingsSplitViewController,
        context: Context
    ) {
        controller.update(
            appearance: appearance,
            model: model,
            registry: registry,
            debugModules: debugModules,
            selection: $selection
        )
    }
}

final class SettingsSplitViewController: NSSplitViewController {

    private let sidebarHosting: NSHostingController<SettingsSourceList>
    private let detailHosting: NSHostingController<SettingsDetailView>
    private let sidebarItem: NSSplitViewItem
    private var backgroundEffect: NSVisualEffectView?
    private var didSetInitialDividerPosition = false
    private var hasShownWindow = false

    init(
        appearance: AppearanceSettings,
        model: AppModel,
        registry: CapabilityRegistry,
        debugModules: any DebugModuleCapability,
        selection: Binding<SettingsSection?>
    ) {
        sidebarHosting = NSHostingController(
            rootView: SettingsSourceList(selection: selection)
        )
        detailHosting = NSHostingController(
            rootView: SettingsDetailView(
                section: selection.wrappedValue ?? .appearance,
                appearance: appearance,
                model: model,
                registry: registry,
                debugModules: debugModules
            )
        )
        sidebarItem = NSSplitViewItem(
            sidebarWithViewController: sidebarHosting
        )
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.canCollapse = false
        // A little wider than "Appearance" with its icon; the user can drag it.
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 280
        sidebarItem.titlebarSeparatorStyle = .none
        super.init(nibName: nil, bundle: nil)
        // The sidebar spans the titlebar, so both hosted columns inherit a
        // titlebar-sized safe area they do not want. Clearing it here is the
        // hosting-level lever; `ignoresSafeArea` inside the SwiftUI view does
        // not reach it.
        sidebarHosting.safeAreaRegions = []
        detailHosting.safeAreaRegions = []

        // NavigationSplitView cannot expose `allowsFullHeightLayout`.
        // Keeping the AppKit split as the window's content view controller is
        // what makes this setting apply at the window level rather than to a
        // nested SwiftUI hosting view.
        addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: detailHosting)
        detailItem.minimumThickness = 480
        addSplitViewItem(detailItem)
        splitView.isVertical = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        appearance: AppearanceSettings,
        model: AppModel,
        registry: CapabilityRegistry,
        debugModules: any DebugModuleCapability,
        selection: Binding<SettingsSection?>
    ) {
        sidebarHosting.rootView = SettingsSourceList(selection: selection)
        detailHosting.rootView = SettingsDetailView(
            section: selection.wrappedValue ?? .appearance,
            appearance: appearance,
            model: model,
            registry: registry,
            debugModules: debugModules
        )
        configureWindow()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindow()
        if !didSetInitialDividerPosition {
            splitView.setPosition(172, ofDividerAt: 0)
            didSetInitialDividerPosition = true
        }
    }

    private func configureWindow() {
        guard let window = view.window else { return }
        let splitView = self.splitView

        // The SwiftUI Settings scene previously supplied this thin base blur
        // through `containerBackground`. AppKit owns the window now, so keep
        // the same clear-end material without painting an opaque fill.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        splitView.dividerStyle = .thin
        if backgroundEffect == nil {
            let effect = NSVisualEffectView(frame: splitView.bounds)
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            effect.autoresizingMask = [.width, .height]
            splitView.addSubview(effect, positioned: .below, relativeTo: nil)
            backgroundEffect = effect
        }

    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    // The AppKit split holds rendered snapshots of both columns, so a
    // selection change has to push a fresh detail view into it; otherwise the
    // sidebar highlights the new row and the pane keeps the old content.
    private var selection: SettingsSection? = .appearance {
        didSet {
            guard oldValue != selection else { return }
            refreshColumns()
        }
    }
    private var splitController: SettingsSplitViewController?
    private var hasShownWindow = false

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var lastContext: (
        appearance: AppearanceSettings,
        model: AppModel,
        registry: CapabilityRegistry,
        debugModules: any DebugModuleCapability
    )?

    private func refreshColumns() {
        guard let splitController, let lastContext else { return }
        splitController.update(
            appearance: lastContext.appearance,
            model: lastContext.model,
            registry: lastContext.registry,
            debugModules: lastContext.debugModules,
            selection: selectionBinding
        )
    }

    func show(
        appearance: AppearanceSettings,
        model: AppModel,
        registry: CapabilityRegistry,
        debugModules: any DebugModuleCapability
    ) {
        lastContext = (
            appearance: appearance,
            model: model,
            registry: registry,
            debugModules: debugModules
        )
        if let splitController {
            splitController.update(
                appearance: appearance,
                model: model,
                registry: registry,
                debugModules: debugModules,
                selection: selectionBinding
            )
        } else {
            let splitController = SettingsSplitViewController(
                appearance: appearance,
                model: model,
                registry: registry,
                debugModules: debugModules,
                selection: selectionBinding
            )
            self.splitController = splitController
            splitController.preferredContentSize = NSSize(width: 720, height: 460)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
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
            window.contentViewController = splitController
            window.title = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.toolbar = NSToolbar(identifier: "Hermternal.SettingsToolbar")
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            // Tiling window managers classify by AX subrole; a plain titled
            // window reports AXStandardWindow and gets tiled. Settings is a
            // utility surface, so report it as floating.
            window.setAccessibilitySubrole(.floatingWindow)
            window.contentMinSize = NSSize(width: 660, height: 460)
            window.setContentSize(NSSize(width: 720, height: 460))
            self.window = window
        }

        if let window {
            window.makeKeyAndOrderFront(nil)
            if !hasShownWindow {
                hasShownWindow = true
                Task { @MainActor [weak window] in
                    await Task.yield()
                    guard let window else { return }
                    window.setContentSize(NSSize(width: 720, height: 460))
                    window.center()
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private var selectionBinding: Binding<SettingsSection?> {
        Binding(
            get: { [weak self] in self?.selection },
            set: { [weak self] value in self?.selection = value }
        )
    }
}
