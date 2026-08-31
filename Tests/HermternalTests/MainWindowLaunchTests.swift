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

    MainWindowStartupConfiguration.prepare(
        window,
        restoringFrameNamed: nil
    )
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
