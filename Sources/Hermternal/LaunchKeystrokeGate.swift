import AppKit
import HermternalCore

/// Accepts keystrokes when the composer field is not yet first responder.
///
/// Launch attaches the cached workspace before the window orders front and
/// focuses the composer on that first frame. This gate is the fallback when
/// that field is not ready. A local key-down monitor also keeps characters
/// that arrive while later work blocks the runloop.
/// Defended by launchKeystrokesBeforeAttachReachComposer.
@MainActor
final class LaunchKeystrokeGate: NSView {
    private var buffer = ""
    private var monitor: Any?
    private var isOpen = false

    override var acceptsFirstResponder: Bool { true }

    /// Characters held since install. Tests read this before a drain.
    var bufferedText: String { buffer }

    /// Places the gate in the window, makes it first responder, and starts
    /// the local key-down monitor.
    func install(in window: NSWindow) {
        frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        isHidden = true
        autoresizingMask = []
        if superview == nil {
            window.contentView?.addSubview(self)
        }
        isOpen = true
        startMonitor()
        if window.makeFirstResponder(self) {
            LaunchClock.mark("interactivity.firstResponder")
        }
    }

    /// Starts the local monitor without changing the view hierarchy.
    func startMonitor() {
        guard monitor == nil else { return }
        isOpen = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            return self.consume(event) ? nil : event
        }
    }

    /// Removes the view and returns the buffer. The monitor stays so keys
    /// that arrive during the later attach are not lost.
    func detachFromWindowKeepingMonitor() -> String {
        removeFromSuperview()
        let text = buffer
        buffer = ""
        return text
    }

    /// Stops the monitor, removes the view, and returns remaining text.
    func stop() -> String {
        isOpen = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        removeFromSuperview()
        let text = buffer
        buffer = ""
        return text
    }

    override func keyDown(with event: NSEvent) {
        if !consume(event) {
            super.keyDown(with: event)
        }
    }

    static func postCharacter(_ character: String, to window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        ) else { return }
        if NSApp.windows.contains(window) {
            NSApp.sendEvent(event)
        } else {
            window.sendEvent(event)
        }
    }

    @discardableResult
    func consume(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        if let responder = event.window?.firstResponder as? NSTextView,
           responder !== self {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.control) {
            return false
        }
        switch event.keyCode {
        case 51, 117:
            if !buffer.isEmpty {
                buffer.removeLast()
            }
            return true
        case 36, 48, 53, 76:
            return false
        default:
            break
        }
        guard let characters = event.characters, !characters.isEmpty else {
            return false
        }
        var accepted = false
        for character in characters {
            if let ascii = character.asciiValue, ascii < 32 {
                continue
            }
            buffer.append(character)
            accepted = true
        }
        return accepted
    }
}

/// Marks first main-actor idle and then runs `work` on that turn.
///
/// Launch uses this to report interactivity after the first content frame,
/// not to delay attach. A yield lets the composer take the caret after
/// AppKit finishes becoming key.
enum LaunchInteractivityScheduling {
    /// Waits for the next main-actor idle, then runs `work`.
    @MainActor
    @discardableResult
    static func afterFirstIdle(
        _ work: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            await Task.yield()
            LaunchClock.mark("interactivity.runloopIdle")
            LaunchClock.markReadyIfInteractive()
            work()
        }
    }
}
