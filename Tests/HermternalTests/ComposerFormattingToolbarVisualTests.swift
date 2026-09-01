import AppKit
import HermternalCore
import SwiftUI
import Testing

@testable import Hermternal

/// A live composer, held on screen so a person can look at it.
///
/// Liquid Glass is drawn by the compositor, so no bitmap this process can read
/// holds the material. The only way to see the strip is to put a real window
/// on a real screen and capture it from outside. This test does that, and it
/// runs only when it is asked to:
///
///     HERMTERNAL_TOOLBAR_VISUAL=1 swift test --no-parallel \
///         --filter floatingToolbarStaysOnScreenForCapture
///
/// It prints the screen rectangle to capture, then holds the window for eight
/// seconds. It is never part of an unattended run.
@Test(
    "Visual: the floating toolbar over a live composer field",
    .enabled(
        if: ProcessInfo.processInfo.environment["HERMTERNAL_TOOLBAR_VISUAL"] == "1"
    )
)
@MainActor
func floatingToolbarStaysOnScreenForCapture() async throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)
    let model = ComposerModel(
        route: ComposerRoute(identity: "new"),
        runtime: VisualRuntimeStub(),
        attachmentStaging: VisualAttachmentStub(),
        turn: nil
    )
    let hosting = NSHostingView(rootView: ComposerView(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 320)
    let window = NSWindow(
        contentRect: hosting.frame,
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.contentView = hosting
    // Above the other windows of the session, so nothing covers the capture.
    window.level = .floating
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer {
        window.contentView = nil
        window.close()
    }
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()

    let textView = try #require(firstVisualTextView(in: hosting))
    #expect(window.makeFirstResponder(textView))
    let message = "Hermes, read this paragraph and name the one rule that keeps "
        + "a floating toolbar off the typing path of a composer field."
    textView.insertText(message, replacementRange: textView.selectedRange())
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()

    // A selection in the middle of the second line, so the strip has room
    // above it and has to choose that side.
    let range = (textView.string as NSString).range(of: "one rule")
    textView.setSelectedRange(range)
    for _ in 0..<8 {
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()
    }

    guard let screen = window.screen ?? NSScreen.main else { return }
    let frame = window.frame
    let top = screen.frame.maxY - frame.maxY
    print(
        "COMPOSER_TOOLBAR_CAPTURE region="
            + "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
    )
    try await Task.sleep(for: .seconds(8))
}

@MainActor
private func firstVisualTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
        if let found = firstVisualTextView(in: subview) { return found }
    }
    return nil
}

private struct VisualRuntimeStub: SessionRuntimeControlling {
    func modelInventory(sessionID: String?, refresh: Bool) async throws -> ModelInventory {
        ModelInventory(providers: [])
    }

    func setModel(
        _ model: String,
        provider: String?,
        sessionID: String
    ) async throws -> ModelSwitchOutcome {
        ModelSwitchOutcome(appliedValue: model, isDeferredToNextTurn: false)
    }

    func setReasoning(_ setting: ReasoningSetting, sessionID: String) async throws {}
}

private struct VisualAttachmentStub: AttachmentStaging {
    func stageBatch(
        _ steps: [ComposerStagingStep],
        sessionID: String,
        routeIdentity: String,
        progress: @escaping @Sendable (UUID, Int) -> Void,
        reusing receipts: [AttachmentStagingReceipt]
    ) async throws -> any AttachmentStagingTransaction {
        throw AttachmentStagingError.invalidRoute
    }
}
