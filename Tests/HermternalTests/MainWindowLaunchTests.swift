import AppKit
import Darwin
import Foundation
import HermternalCore
import Testing
@testable import Hermternal

@Test("launch performance contract: chrome and frame settle before content attachment")
@MainActor
func mainWindowChromeSettlesBeforeContentAttachment() {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(
            origin: .zero,
            size: MainWindowStartupConfiguration.defaultContentSize
        ),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false

    MainWindowStartupConfiguration.prepare(
        window,
        restoringFrameNamed: nil
    )
    defer { window.close() }
    #expect(window.contentViewController == nil)
    #expect(window.animationBehavior == .none)
    #expect(window.title.isEmpty)
    #expect(window.titleVisibility == .hidden)
    #expect(window.titlebarAppearsTransparent)
    #expect(window.toolbarStyle == .unified)
    #expect(window.contentMinSize == MainWindowStartupConfiguration.minimumContentSize)
    let finalContentRect = window.contentRect(forFrameRect: window.frame)
    #expect(finalContentRect.size == MainWindowStartupConfiguration.defaultContentSize)
    #expect(window.frame.width >= MainWindowStartupConfiguration.minimumContentSize.width)
    #expect(window.frame.height >= MainWindowStartupConfiguration.minimumContentSize.height)
}

@Test("launch performance contract: initial animation restores exactly once after first key")
func mainWindowInitialAnimationStateRestoresOnce() {
    var state: MainWindowInitialOrderAnimationState = .suppressing

    #expect(state.animationBehavior == .none)
    let restoredOnFirstKey = state.restoreAfterFirstKey()
    let behaviorAfterFirstKey = state.animationBehavior
    let restoredOnSecondKey = state.restoreAfterFirstKey()
    let behaviorAfterSecondKey = state.animationBehavior

    #expect(restoredOnFirstKey)
    #expect(behaviorAfterFirstKey == .default)
    #expect(!restoredOnSecondKey)
    #expect(behaviorAfterSecondKey == .default)
}

@Test("launch performance contract: signed-out toolbar creates no transient chrome")
@MainActor
func signedOutToolbarSkipsReadyOnlyItems() {
    let signedOut = MainToolbarController.defaultItemIdentifiers(isReady: false)
    let ready = MainToolbarController.defaultItemIdentifiers(isReady: true)

    #expect(signedOut == [.flexibleSpace, .flexibleSpace])
    #expect(ready.count == 6)
    #expect(ready.filter { $0 == .flexibleSpace }.count == 2)
}

@Test("toolbar New Chat enablement follows ready, not workspace visibility")
@MainActor
func toolbarDetailActionEnablementTruthTable() {
    struct Row {
        let phase: AppModel.Phase
        let searchPresented: Bool
        let viewingArchived: Bool
        let showsChrome: Bool
        let newChat: Bool
        let restore: Bool
    }
    let rows: [Row] = [
        .init(phase: .signedOut, searchPresented: false, viewingArchived: false, showsChrome: false, newChat: false, restore: false),
        .init(phase: .restoring, searchPresented: false, viewingArchived: false, showsChrome: true, newChat: false, restore: false),
        .init(phase: .connecting, searchPresented: false, viewingArchived: false, showsChrome: true, newChat: false, restore: false),
        .init(phase: .ready, searchPresented: false, viewingArchived: false, showsChrome: true, newChat: true, restore: false),
        .init(phase: .ready, searchPresented: true, viewingArchived: false, showsChrome: true, newChat: false, restore: false),
        .init(phase: .ready, searchPresented: false, viewingArchived: true, showsChrome: true, newChat: false, restore: true),
        .init(phase: .ready, searchPresented: true, viewingArchived: true, showsChrome: true, newChat: false, restore: false),
        .init(phase: .failed("unavailable"), searchPresented: false, viewingArchived: false, showsChrome: false, newChat: false, restore: false)
    ]
    for row in rows {
        let state = MainToolbarController.DetailCommandEnablement.resolve(
            phase: row.phase,
            searchPresented: row.searchPresented,
            viewingArchived: row.viewingArchived
        )
        #expect(state.showsWorkspaceChrome == row.showsChrome)
        #expect(state.isNewChatEnabled == row.newChat)
        #expect(state.isRestoreEnabled == row.restore)
        #expect(state.isDetailActionEnabled == (row.newChat || row.restore))
        #expect(state.areChromeCommandsEnabled == (row.showsChrome && !row.searchPresented))
    }
}

@Test("the toolbar's width toggle is two real symbols and one command")
@MainActor
func toolbarWidthToggleStatesTheMeasureItWouldGive() {
    // The item states the action, so it carries the OTHER measure's symbol and
    // label. Both symbols must exist: `NSImage(systemSymbolName:)` answers nil
    // for a name macOS does not ship, and a toolbar button with no image is a
    // blank square.
    for mode in TranscriptWidthMode.allCases {
        #expect(mode.other != mode)
        #expect(mode.other.other == mode)
        #expect(
            NSImage(
                systemSymbolName: mode.symbolName,
                accessibilityDescription: mode.label
            ) != nil
        )
        #expect(!mode.label.isEmpty)
        #expect(!mode.actionDescription.isEmpty)
    }
    #expect(TranscriptWidthMode.standard.label != TranscriptWidthMode.full.label)
    #expect(
        TranscriptWidthMode.standard.symbolName != TranscriptWidthMode.full.symbolName
    )
}

@Test("the transcript measure persists and reaches the layout")
@MainActor
func transcriptMeasurePersistsAndReachesTheLayout() throws {
    let suiteName = "HermternalTests.TranscriptWidth.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        MessageTypography.widthMode = .standard
    }

    let appearance = AppearanceSettings(defaults: defaults)

    // An absent preference is the standard measure, and reading it writes
    // nothing.
    #expect(appearance.transcriptWidthMode == .standard)
    #expect(MessageTypography.widthMode == .standard)
    #expect(defaults.object(forKey: TranscriptWidthStore.key) == nil)

    appearance.toggleTranscriptWidth()

    // The transcript reads `MessageTypography.widthMode` on every measurement
    // and every row layout, so the setter must have written it already.
    #expect(appearance.transcriptWidthMode == .full)
    #expect(MessageTypography.widthMode == .full)
    #expect(defaults.string(forKey: TranscriptWidthStore.key) == "full")

    // Restoring the same defaults restores the measure, and it reaches the
    // layout before any window exists.
    MessageTypography.widthMode = .standard
    let restored = AppearanceSettings(defaults: defaults)
    #expect(restored.transcriptWidthMode == .full)
    #expect(MessageTypography.widthMode == .full)

    // A reset returns the reading measure.
    restored.resetToDefaults()
    #expect(restored.transcriptWidthMode == .standard)
    #expect(MessageTypography.widthMode == .standard)
}

@Test("launch performance contract: system appearance keeps inherited AppKit appearance")
@MainActor
func systemAppearanceInitializationAvoidsGlobalReset() throws {
    let app = NSApplication.shared
    let originalAppearance = app.appearance
    defer { app.appearance = originalAppearance }

    let inheritedAppearance = try #require(NSAppearance(named: .darkAqua))
    app.appearance = inheritedAppearance

    let suiteName = "HermternalTests.AppearanceSettings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let appearance = AppearanceSettings(defaults: defaults)

    #expect(appearance.mode == .system)
    #expect(app.appearance?.name == inheritedAppearance.name)
}

@Test("launch performance contract: explicit appearance applies before content attachment")
@MainActor
func explicitAppearanceInitializationAppliesAppKitOverride() throws {
    let app = NSApplication.shared
    let originalAppearance = app.appearance
    defer { app.appearance = originalAppearance }
    app.appearance = nil

    let suiteName = "HermternalTests.AppearanceSettings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(AppearanceMode.dark.rawValue, forKey: "appearance.mode")

    let appearance = AppearanceSettings(defaults: defaults)
    let expectedAppearance = try #require(NSAppearance(named: .darkAqua))

    #expect(appearance.mode == .dark)
    #expect(app.appearance?.name == expectedAppearance.name)
}

/// The window has to keep the size it opened at, and stay resizable, once its
/// content host attaches.
///
/// `NSWindow` reads the content view controller's `preferredContentSize` as a
/// size the window must hold, not as a size to open at. Measured on macOS
/// 26.6.2: a window sized 1360x720, whose content controller preferred
/// 1040x720, was pulled to 1040x720 by the attachment and then refused every
/// wider frame; the same window with no preferred size kept 1360x720 and took
/// the wider frame. That is the whole regression. The app restores its frame
/// before attaching content, so a preferred size discards whatever size the
/// user left the window at and then holds the window there. A tiling window
/// manager resizes through the accessibility API, which lands in the same
/// code path, so the window becomes unmanageable rather than merely stubborn.
@Test("launch contract: attaching the content host leaves the window resizable")
@MainActor
func mainWindowStaysResizableAfterContentAttachment() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalTests.MainWindow.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let suiteName = "HermternalTests.AppearanceSettings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let model = AppModel(cache: HistoryCache(directory: directory))
    let shell = MainShellViewController(
        appearance: AppearanceSettings(defaults: defaults),
        model: model,
        onModelStateChanged: {}
    )
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
    window.isReleasedWhenClosed = false
    MainWindowStartupConfiguration.prepare(window, restoringFrameNamed: nil)
    // Stands in for a restored frame: the size the user left the window at,
    // which is what every launch after the first opens with. It differs from
    // the default on purpose — a preferred content size is only observable
    // when the two disagree.
    let restored = MainWindowStartupConfiguration.defaultContentSize.width + 320
    window.setContentSize(
        NSSize(
            width: restored,
            height: MainWindowStartupConfiguration.defaultContentSize.height
        )
    )
    MainWindowStartupConfiguration.attach(shell, to: window)
    defer { window.close() }

    // Attachment kept the restored width. Asserted before the window is
    // ordered on screen, because AppKit constrains a window it orders to the
    // display's visible frame and a test must not depend on the display it
    // runs on.
    #expect(window.contentRect(forFrameRect: window.frame).width == restored)

    // A preferred content size reaches the window through its layout rather
    // than through the assignment, so the window is ordered front and laid out
    // before the resize below is asked for.
    window.makeKeyAndOrderFront(nil)
    shell.view.layoutSubtreeIfNeeded()

    // The rule, stated where a reintroduced assignment would break it.
    #expect(shell.preferredContentSize == .zero)

    // The window still takes a wider frame. Only the width is asserted:
    // `setFrame` clamps a height taller than the visible area and leaves the
    // width alone, which is what keeps this assertion portable.
    let wider = restored + 200
    window.setFrame(
        NSRect(x: 0, y: 0, width: wider, height: window.frame.height),
        display: false
    )
    #expect(window.frame.width == wider)

    // And the floor is still declared. `contentMinSize` is the lever the user
    // and a window manager resize against; a programmatic `setFrame` is not
    // clamped by it, so the floor is asserted where it lives rather than
    // through a frame that AppKit never bounds.
    #expect(window.contentMinSize == MainWindowStartupConfiguration.minimumContentSize)
}

/// Launch orders the prepared window front, then attaches the content host.
/// Attachment still has to keep the restored size and stay resizable.
@Test("launch contract: attaching after orderFront leaves the window resizable")
@MainActor
func mainWindowStaysResizableWhenAttachedAfterOrderFront() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalTests.MainWindow.AfterFront.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let suiteName = "HermternalTests.AppearanceSettings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let model = AppModel(cache: HistoryCache(directory: directory))
    let shell = MainShellViewController(
        appearance: AppearanceSettings(defaults: defaults),
        model: model,
        onModelStateChanged: {}
    )
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
    window.isReleasedWhenClosed = false
    MainWindowStartupConfiguration.prepare(window, restoringFrameNamed: nil)
    let restored = MainWindowStartupConfiguration.defaultContentSize.width + 320
    window.setContentSize(
        NSSize(
            width: restored,
            height: MainWindowStartupConfiguration.defaultContentSize.height
        )
    )
    window.makeKeyAndOrderFront(nil)
    // AppKit may clamp the ordered window to the visible display. Attach
    // has to keep that on-screen frame, not the pre-front restored size.
    let widthAfterFront = window.contentRect(forFrameRect: window.frame).width
    MainWindowStartupConfiguration.attach(shell, to: window)
    defer { window.close() }

    #expect(!window.ignoresMouseEvents)
    #expect(window.contentRect(forFrameRect: window.frame).width == widthAfterFront)
    shell.view.layoutSubtreeIfNeeded()
    #expect(shell.preferredContentSize == .zero)

    let wider = widthAfterFront + 200
    window.setFrame(
        NSRect(x: 0, y: 0, width: wider, height: window.frame.height),
        display: false
    )
    #expect(window.frame.width == wider)
    #expect(window.contentMinSize == MainWindowStartupConfiguration.minimumContentSize)
}

/// The window's translucency has to follow the Appearance pane.
///
/// `AppearanceSettings` is `@Observable`, and the backdrop reaches the window
/// through a hosted SwiftUI root that reads it. The shell used to hold private
/// copies of the opacity and the glass flag and push them into the backdrop by
/// hand, so moving the slider changed the pane's own readout and nothing else;
/// it also forced `isOpaque` to false on every attach and every update, which
/// denied the fully solid end of the dial outright. Both halves are asserted
/// here, because either one alone brings the regression back.
@Test("appearance contract: the window backdrop follows the opacity dial")
@MainActor
func windowBackdropFollowsTheOpacityDial() async throws {
    _ = NSApplication.shared
    // Reduce Transparency resolves every treatment to opaque by design, so a
    // machine with it enabled has nothing here to observe.
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
        return
    }
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalTests.Backdrop.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let suiteName = "HermternalTests.AppearanceSettings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let appearance = AppearanceSettings(defaults: defaults)
    appearance.previewBackgroundOpacity(0.6)

    let model = AppModel(cache: HistoryCache(directory: directory))
    let shell = MainShellViewController(
        appearance: appearance,
        model: model,
        onModelStateChanged: {}
    )
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
    window.isReleasedWhenClosed = false
    MainWindowStartupConfiguration.prepare(window, restoringFrameNamed: nil)
    MainWindowStartupConfiguration.attach(shell, to: window)
    defer { window.close() }
    window.makeKeyAndOrderFront(nil)

    // A translucent dial reached the window at all. An `NSWindow` is opaque
    // until something says otherwise, so this is the backdrop's own work.
    #expect(await settles(shell) { !window.isOpaque })

    // And the solid end of the dial is honoured rather than overwritten.
    appearance.previewBackgroundOpacity(1)
    #expect(await settles(shell) { window.isOpaque })

    // A later shell update leaves it alone. `MainWindowController.show` runs
    // this path every time something reopens the window — New Chat, a deep
    // link, a reactivation — and it used to reset the window's translucency
    // there, which threw away whatever the user had just chosen.
    shell.update(appearance: appearance, model: model)
    #expect(await settles(shell) { window.isOpaque })
}

/// Runs layout passes until `condition` holds, or gives up.
///
/// SwiftUI's observation delivers on a later main-actor turn, so a single
/// layout pass is not enough to see a change land. The bound is small because
/// a change that needs more turns than this is a defect either way.
@MainActor
private func settles(
    _ controller: NSViewController,
    until condition: () -> Bool
) async -> Bool {
    for _ in 0..<16 {
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@Test("launch contract: the app opens only the main window")
func applicationLaunchOpensOnlyTheMainWindow() async throws {
    let fileManager = FileManager.default
    let fixtureDirectory = fileManager.temporaryDirectory
        .appending(path: "HermternalLaunch-\(UUID().uuidString)", directoryHint: .isDirectory)
    let temporaryHomeDirectory = fixtureDirectory
        .appending(path: "home", directoryHint: .isDirectory)
    let preferencesDirectory = temporaryHomeDirectory
        .appending(path: "Library/Preferences", directoryHint: .isDirectory)
    try fileManager.createDirectory(
        at: preferencesDirectory,
        withIntermediateDirectories: true
    )
    var mayCleanUpFixture = true
    defer {
        if mayCleanUpFixture {
            try? fileManager.removeItem(at: fixtureDirectory)
        }
    }

    let executableURL = try hermternalExecutableURL()
    let outputURL = fixtureDirectory.appending(path: "launch.log")
    guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: outputURL.path])
    }
    let output = try FileHandle(forWritingTo: outputURL)
    var outputIsClosed = false
    defer {
        if mayCleanUpFixture, !outputIsClosed {
            output.closeFile()
        }
    }

    let process = Process()
    process.executableURL = executableURL
    process.standardOutput = output
    process.standardError = output
    process.environment = ProcessInfo.processInfo.environment.merging([
        "CFFIXED_USER_HOME": temporaryHomeDirectory.path,
        "HERMTERNAL_FIXTURES": "1",
        "HERMTERNAL_LAUNCH_WINDOW_PROBE": "1",
        "HOME": temporaryHomeDirectory.path
    ]) { _, replacement in replacement }

    try process.run()
    mayCleanUpFixture = false

    var timeoutDetails: String?
    let exitedBeforeDeadline = await waitForProcessExit(process, timeout: .seconds(10))
    if !exitedBeforeDeadline {
        let processIdentifier = process.processIdentifier
        process.terminate()
        let exitedAfterGracefulTermination = await waitForProcessExit(
            process,
            timeout: .seconds(2)
        )
        if !exitedAfterGracefulTermination {
            let forceStopResult = Darwin.kill(processIdentifier, SIGKILL)
            let forceStopDetails: String
            if forceStopResult == 0 {
                forceStopDetails = "SIGKILL sent to pid \(processIdentifier)"
            } else {
                let errorCode = errno
                forceStopDetails = "SIGKILL failed for pid \(processIdentifier): errno=\(errorCode) \(String(cString: strerror(errorCode)))"
            }
            let exitedAfterForceStop = await waitForProcessExit(
                process,
                timeout: .seconds(2)
            )
            guard exitedAfterForceStop else {
                Issue.record(
                    """
                    Launch probe did not exit within 2 seconds after \(forceStopDetails).
                    pid=\(processIdentifier), output retained at \(outputURL.path) to avoid racing a live child.
                    """
                )
                return
            }
            timeoutDetails = "Launch probe exceeded 10 seconds, ignored SIGTERM for 2 seconds, then \(forceStopDetails)."
        } else {
            timeoutDetails = "Launch probe exceeded 10 seconds and exited after SIGTERM."
        }
    }

    mayCleanUpFixture = true

    output.closeFile()
    outputIsClosed = true
    let launchOutput = try String(contentsOf: outputURL, encoding: .utf8)
    let probeCountPrefix = "HERMTERNAL_LAUNCH_VISIBLE_WINDOW_COUNT="
    let visibleFramePrefix = "HERMTERNAL_LAUNCH_VISIBLE_WINDOW_CONTENT_FRAMES="
    let probeCounts: [Int] = launchOutput
        .split(whereSeparator: \.isNewline)
        .compactMap { line in
            guard line.hasPrefix(probeCountPrefix) else { return nil }
            return Int(line.dropFirst(probeCountPrefix.count))
        }
    let visibleContentFrames: [NSRect] = launchOutput
        .split(whereSeparator: \.isNewline)
        .filter { $0.hasPrefix(visibleFramePrefix) }
        .flatMap { line in
            line.dropFirst(visibleFramePrefix.count).split(separator: "|")
        }
        .map { NSRectFromString(String($0)) }
    let expectedFrameSize = await MainActor.run {
        MainWindowStartupConfiguration.defaultContentSize
    }

    guard timeoutDetails == nil,
          process.terminationReason == .exit,
          process.terminationStatus == 0,
          probeCounts == [1],
          visibleContentFrames.map(\.size) == [expectedFrameSize]
    else {
        Issue.record(
            """
            Launch probe failed for \(executableURL.path).
            timeout=\(timeoutDetails ?? "none")
            reason=\(process.terminationReason), status=\(process.terminationStatus)
            probeCounts=\(probeCounts), visibleContentFrames=\(visibleContentFrames)
            output:
            \(launchOutput)
            """
        )
        return
    }
}

private func waitForProcessExit(
    _ process: Process,
    timeout: Duration
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while process.isRunning {
        let remaining = deadline - clock.now
        guard remaining > .zero else { return false }
        try? await Task.sleep(for: min(remaining, .milliseconds(50)))
    }
    return true
}


private func hermternalExecutableURL() throws -> URL {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let buildDirectory = packageRoot.appending(path: ".build", directoryHint: .isDirectory)
    let fileManager = FileManager.default
    let buildConfigurations = try fileManager.contentsOfDirectory(
        at: buildDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    let executableURLs = (
        [buildDirectory] + buildConfigurations.sorted { $0.path < $1.path }
    ).map { directory in
        directory
            .appending(path: "debug", directoryHint: .isDirectory)
            .appending(path: "Hermternal", directoryHint: .notDirectory)
    }
    guard let executableURL = executableURLs.first(
        where: { fileManager.isExecutableFile(atPath: $0.path) }
    ) else {
        throw CocoaError(
            .fileNoSuchFile,
            userInfo: [NSFilePathErrorKey: executableURLs.map(\.path).joined(separator: "\n")]
        )
    }
    return executableURL
}

@Test("app composition keeps the macOS organization directory")
@MainActor
func appCompositionKeepsMacOSOrganizationDirectory() {
    let expectedURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: SessionOrganizationStore.configurationDirectoryName, directoryHint: .isDirectory)
        .appending(path: SessionOrganizationStore.configurationFileName)

    #expect(HermternalApp.makeOrganizationStore().configurationURL == expectedURL)
}
