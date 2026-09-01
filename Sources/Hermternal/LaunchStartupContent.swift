import AppKit
import HermternalCore

/// Pins the restored transcript and focuses the composer before the window
/// orders front. The first visible frame is then cached content, not chrome.
///
/// Attach on a warm cache is a few milliseconds. Ordering an empty shell
/// front first showed a blank frame, then a late caret.
/// Defended by launchContentAttachesBeforeOrderFront and
/// launchComposerIsFirstResponderWhenTheWindowOrdersFront.
enum LaunchStartupContent {
    /// Attaches the hosted split, pins the tail, and focuses the composer.
    ///
    /// Call this before `makeKeyAndOrderFront`. The window stays hidden
    /// while SwiftUI builds the cached sidebar and chat.
    @MainActor
    static func attachCachedWorkspace(
        _ contentHost: NSViewController,
        to window: NSWindow,
        model: AppModel
    ) {
        if model.phase.presentsWorkspace, !model.isViewingArchivedTranscript {
            model.requestComposerFocus()
        }
        MainWindowStartupConfiguration.attach(contentHost, to: window)
        contentHost.view.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        pinRestoredTranscript(in: window)
        _ = focusComposer(in: window, model: model)
        LaunchClock.mark("window.contentReady")
    }

    /// Holds the restored tail at the bottom before the first visible frame.
    ///
    /// Store attach later expands above this pin. The visible tail does not
    /// move when the content is unchanged.
    @MainActor
    static func pinRestoredTranscript(in window: NSWindow) {
        guard let root = window.contentView else { return }
        pinRestoredTranscript(in: root)
    }

    @MainActor
    static func pinRestoredTranscript(in view: NSView) {
        if let container = view as? BlockTranscriptContainerView {
            TranscriptViewportAnchoring.pinToBottom(container.tableView)
            return
        }
        for child in view.subviews {
            pinRestoredTranscript(in: child)
        }
    }

    /// Makes the composer field first responder when the workspace can take
    /// a keystroke. Returns `false` when no field exists yet.
    @MainActor
    @discardableResult
    static func focusComposer(in window: NSWindow, model: AppModel) -> Bool {
        guard model.phase.presentsWorkspace,
              !model.isViewingArchivedTranscript
        else { return false }
        guard let root = window.contentView,
              let editor = composerEditor(in: root)
        else { return false }
        let accepted = window.makeFirstResponder(editor)
        if accepted {
            LaunchClock.mark("interactivity.composerCaret")
            LaunchClock.mark("interactivity.firstResponder")
        }
        return accepted
    }

    /// The live composer text view, if the hosted tree has built it.
    @MainActor
    static func composerEditor(in view: NSView) -> NSTextView? {
        if let scroll = view as? ComposerEditorScrollView,
           let editor = scroll.documentView as? NSTextView {
            return editor
        }
        for child in view.subviews {
            if let editor = composerEditor(in: child) {
                return editor
            }
        }
        return nil
    }

    /// The restored transcript table, if the hosted tree has built it.
    @MainActor
    static func transcriptContainer(in view: NSView) -> BlockTranscriptContainerView? {
        if let container = view as? BlockTranscriptContainerView {
            return container
        }
        for child in view.subviews {
            if let container = transcriptContainer(in: child) {
                return container
            }
        }
        return nil
    }
}
