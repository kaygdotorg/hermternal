import SwiftUI
import HermternalCore
import AppKit

private struct TranscriptBlockProjectionKey: Hashable, Sendable {
    let routeIdentity: String
    let revision: Int
    let range: Range<Int>
}

private struct PreparedTranscriptBlocks: Sendable {
    let key: TranscriptBlockProjectionKey
    let blocks: [TranscriptBlock]
}

private enum TranscriptBlockProjection {
    /// The body only creates bounded source rows. Each placeholder points at
    /// the real message text, so the first paint is plain prose or monospace
    /// code rather than an empty rectangle.
    static func placeholders(for messages: [ChatMessage]) -> [TranscriptBlock] {
        messages.flatMap { TranscriptBlockSegmenter.placeholders(for: $0) }
    }

    /// Markdown segmentation and source-span extraction run after the body
    /// returns, on a non-main executor.
    static func prepare(_ messages: [ChatMessage]) throws -> [TranscriptBlock] {
        var result: [TranscriptBlock] = []
        result.reserveCapacity(messages.count)
        for message in messages {
            try Task.checkCancellation()
            result.append(contentsOf: TranscriptBlockSegmenter.blocks(for: message))
            try Task.checkCancellation()
        }
        return result
    }
}

struct ChatView: View {
    private static let transcriptWindowSize = TranscriptWindowPolicy.initialWindowSize
    @Bindable var model: AppModel
    let isReadOnly: Bool
    @State private var isFindPresented = false
    @State private var findQuery = ""
    @State private var activeFindIndex = 0
    @State private var transcriptWindowState: TranscriptWindowState?
    @State private var isPrimingTranscriptWindow = true
    /// The selection generation captured at publication. A later stream
    /// update may advance `openGeneration`, but it must not turn an old row
    /// paint into a second visibility event for this selection.
    @State private var transcriptVisibilitySessionID: String?
    @State private var transcriptVisibilityGeneration: Int?
    @State private var transcriptVisibilityEmitted = false
    /// Incremented by New Chat and by the selected-session transition that
    /// follows it. Composer consumes this through SwiftUI focus state
    /// rather than taking first responder during every launch.
    @State private var composerFocusRequest = 0
    /// Segmentation is retained only for the current route/window/revision.
    /// A route change or stream revision uses placeholder blocks until the
    /// replacement arrives from the background task.
    @State private var preparedTranscriptBlocks: PreparedTranscriptBlocks?
    var body: some View {
        transcript
            // The archived transcript has no bottom editing surface.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isReadOnly {
                    Composer(
                        model: model,
                        focusRequest: composerFocusRequest
                    )
                        .background { Self.composerHalo }
                }
            }
        // Declared on the detail, not the sidebar column: only the window
        // toolbar region groups adjacent items into one shared pill.
        .toolbar {
            // Reserve the native principal slot without drawing a duplicate
            // window title; the traffic lights and toolbar remain native.
            ToolbarItem(placement: .principal) {
                EmptyView()
            }
            // The item content is unconditional. The `toolbarVisibility`
            // modifier in `RootView` hides these items during search. An
            // earlier version removed the items for the same state change.
            // That removal rebuilt the `NSToolbar`. The old AppKit host then
            // had to apply its changes again after each rebuild.
            if isReadOnly {
                ToolbarItemGroup {
                    Button {
                        guard let session = archivedSession else { return }
                        Task { await model.restoreArchived(session) }
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .help("Restore chat")
                    .disabled(archivedSession == nil)

                    Button {
                        guard let session = archivedSession else { return }
                        model.copyDeepLink(for: session)
                    } label: {
                        Image(systemName: "link")
                    }
                    .help("Copy chat link")
                    .disabled(archivedSession == nil)
                }
            } else {
                ToolbarItemGroup {
                    Button {
                        composerFocusRequest &+= 1
                        Task { await model.newChat() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New chat")
                    .keyboardShortcut("n", modifiers: .command)

                    Button {
                        Task { await model.loadSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload the chat list from the server")
                }
            }
        }
        .focusedSceneValue(\.hermternalFindAction, { openFind() })
        .onChange(of: model.selectedSessionID) { oldID, newID in
            HermternalSelectionOccupancyTrace.observerInvoked(
                forChatID: newID,
                messages: model.messages.count
            )
            resetTranscriptVisibility(for: newID)
            // New Chat clears the durable selection after creating its
            // ephemeral session. That transition is the natural point to
            // return focus to the composer, without stealing it at launch.
            guard !isReadOnly, oldID != nil, newID == nil else { return }
            composerFocusRequest &+= 1
        }
        .onChange(of: model.openGeneration) { _, newGeneration in
            // Re-selecting the already-active chat still creates a new
            // publication generation without changing selectedSessionID.
            // Ignore unrelated generation changes (for example cache or
            // account work) unless this generation is a traced publication.
            guard let sessionID = model.selectedSessionID,
                  transcriptVisibilitySessionID == sessionID,
                  HermternalSwitchTrace.hasPublishedSelection(
                      id: sessionID,
                      generation: newGeneration
                  )
            else {
                return
            }
            resetTranscriptVisibility(for: sessionID)
        }
        .onAppear {
            // Do not reset on a temporary disappearance/reappearance. The
            // same route still represents the same selection.
            guard transcriptVisibilitySessionID != model.selectedSessionID else {
                return
            }
            resetTranscriptVisibility(for: model.selectedSessionID)
        }
        .onChange(of: findQuery) {
            activeFindIndex = 0
        }
    }

    private var archivedSession: ChatSession? {
        guard let id = model.viewingArchivedSessionID else { return nil }
        return model.archivedSessions.first(where: { $0.id == id })
    }
    /// Identity for the displayed route, not for transcript contents.
    ///
    /// The route prefix is intentional: an archived session can have the same
    /// durable identifier as its live counterpart, but it is a different
    /// read-only transcript graph. Streaming updates keep this value unchanged
    /// because they do not change either route or session identifier.
    private var transcriptIdentity: String {
        if let archivedID = model.viewingArchivedSessionID {
            return "archived:\(archivedID)"
        }
        return "live:\(model.selectedSessionID ?? "none")"
    }


    private var initialMessageTarget: MessageIdentity? {
        guard let location = model.pendingMessageLocation,
              model.selectedSessionID == location.sessionID
        else { return nil }
        return .server(location.messageID)
    }

    @MainActor
    private func capturePendingMessageTarget(targetIndex: Int?) -> Bool {
        guard model.pendingMessageLocation != nil,
              let targetIndex,
              model.messages.indices.contains(targetIndex)
        else { return false }
        isPrimingTranscriptWindow = false

        let expanded = TranscriptWindowPolicy.including(
            targetIndex: targetIndex,
            totalMessageCount: model.messages.count,
            requestedWindowSize: Self.transcriptWindowSize,
            currentState: transcriptWindowState
        )
        if transcriptWindowState != expanded.state {
            transcriptWindowState = expanded.state
        }
        return true
    }
    @MainActor
    private func includeActiveFindTarget(matches: [TranscriptMatch]) {
        guard isFindPresented,
              model.pendingMessageLocation == nil,
              matches.indices.contains(activeFindIndex)
        else { return }
        let targetIndex = matches[activeFindIndex].messageIndex
        guard model.messages.indices.contains(targetIndex) else { return }
        isPrimingTranscriptWindow = false
        transcriptWindowState = TranscriptWindowPolicy.including(
            targetIndex: targetIndex,
            totalMessageCount: model.messages.count,
            requestedWindowSize: Self.transcriptWindowSize,
            currentState: transcriptWindowState
        ).state
    }
    @MainActor
    private func resetTranscriptRendererRoute() {
        isPrimingTranscriptWindow = true
        transcriptWindowState = nil
    }
    @MainActor
    private func resetTranscriptVisibility(for sessionID: String?) {
        transcriptVisibilitySessionID = sessionID
        transcriptVisibilityGeneration = sessionID == nil ? nil : model.openGeneration
        transcriptVisibilityEmitted = false
    }

    @MainActor
    private func markTranscriptVisible(
        sessionID: String?,
        generation: Int,
        routeIdentity: String,
        renderedRows: Int,
        visibleAtNanoseconds: UInt64,
        largestRowCharacterCount: () -> Int?
    ) {
        guard !transcriptVisibilityEmitted,
              let sessionID,
              model.selectedSessionID == sessionID,
              transcriptVisibilitySessionID == sessionID,
              transcriptVisibilityGeneration == generation,
              transcriptIdentity == routeIdentity,
              HermternalSwitchTrace.hasPublishedSelection(
                  id: sessionID,
                  generation: generation
              )
        else { return }

        guard HermternalSwitchTrace.transcriptVisible(
            id: sessionID,
            generation: generation,
            messages: model.messages.count,
            renderedRows: renderedRows,
            visibleAtNanoseconds: visibleAtNanoseconds,
            largestRowCharacterCount: largestRowCharacterCount
        ) else {
            return
        }
        transcriptVisibilityEmitted = true
        // The local `sessionID`, not `model.selectedSessionID`: this records
        // the chat whose paint was validated, and the selection may have moved.
        model.noteTranscriptDisplayed(sessionID: sessionID)
    }
    private func largestRenderedRowCharacterCount(
        makeMessages: () -> [ChatMessage]
    ) -> Int? {
        guard model.debugModules.isEnabled(.visiblePaint),
              model.debugModules.isEnabled(.textLayoutAttribution)
        else { return nil }
        return makeMessages().lazy.map { $0.text.utf16.count }.max()
    }


    private func openFind() {
        isFindPresented = true
        activeFindIndex = 0
    }

    private func closeFind() {
        isFindPresented = false
        findQuery = ""
        activeFindIndex = 0
    }

    private func advanceFind(by delta: Int, matches: [TranscriptMatch]) {
        let count = matches.count
        guard count > 0 else { return }
        activeFindIndex = (activeFindIndex + delta + count) % count
    }

    @MainActor
    private func prepareTranscriptBlocks(
        _ messages: [ChatMessage],
        key: TranscriptBlockProjectionKey
    ) async {
        let worker = Task.detached(priority: .userInitiated) {
            try TranscriptBlockProjection.prepare(messages)
        }
        let blocks: [TranscriptBlock]
        do {
            blocks = try await withTaskCancellationHandler(operation: {
                try await worker.value
            }, onCancel: {
                worker.cancel()
            })
        } catch is CancellationError {
            return
        } catch {
            return
        }

        guard key.routeIdentity == transcriptIdentity,
              key.revision == model.messagesRevision,
              key.range == currentTranscriptWindowRange()
        else { return }

        // Keep publication independent of the cancellable `.task` that owns
        // preparation. Once a settled request has produced a current result,
        // a subsequent keypress may cancel the next parse but cannot cancel
        // this publication turn.
        Task { @MainActor in
            guard key.routeIdentity == transcriptIdentity,
                  key.revision == model.messagesRevision,
                  key.range == currentTranscriptWindowRange()
            else { return }
            preparedTranscriptBlocks = PreparedTranscriptBlocks(
                key: key,
                blocks: blocks
            )
        }
    }
    @MainActor
    private func currentTranscriptWindowRange() -> Range<Int> {
        let total = model.messages.count
        let resolved = isPrimingTranscriptWindow
            ? TranscriptWindowPolicy.initial(totalMessageCount: total)
            : TranscriptWindowPolicy.resolve(
                totalMessageCount: total,
                requestedWindowSize: Self.transcriptWindowSize,
                currentState: transcriptWindowState
            )
        guard let target = initialMessageTarget,
              let targetIndex = model.messages.firstIndex(where: { $0.id == target })
        else {
            return resolved.range
        }
        return TranscriptWindowPolicy.including(
            targetIndex: targetIndex,
            totalMessageCount: total,
            requestedWindowSize: Self.transcriptWindowSize,
            currentState: resolved.state
        ).range
    }

    private func transcriptBlocks(
        for messages: [ChatMessage],
        key: TranscriptBlockProjectionKey
    ) -> [TranscriptBlock] {
        guard let prepared = preparedTranscriptBlocks,
              prepared.key == key
        else {
            return TranscriptBlockProjection.placeholders(for: messages)
        }
        return prepared.blocks
    }
    @ViewBuilder
    private var transcript: some View {
        // `selectedSessionID` invalidates this body and SidebarView together.
        // The route identity changes in that same SwiftUI transaction, so the
        // representable update can share its Core Animation commit with the
        // sidebar unless `messages` publishes on a later run-loop turn.
        let messages = model.messages
        let query = isFindPresented ? findQuery : ""
        let matches = model.transcriptMatches(for: query)
        let resolvedWindow = isPrimingTranscriptWindow
            ? TranscriptWindowPolicy.initial(totalMessageCount: messages.count)
            : TranscriptWindowPolicy.resolve(
                totalMessageCount: messages.count,
                requestedWindowSize: Self.transcriptWindowSize,
                currentState: transcriptWindowState
            )
        let pendingTargetIndex = initialMessageTarget.flatMap { target in
            messages.firstIndex(where: { $0.id == target })
        }
        let windowTargetIndex = pendingTargetIndex
        let window = windowTargetIndex.map {
            TranscriptWindowPolicy.including(
                targetIndex: $0,
                totalMessageCount: messages.count,
                requestedWindowSize: Self.transcriptWindowSize,
                currentState: resolvedWindow.state
            )
        } ?? resolvedWindow
        let windowedMessages = Array(messages[window.range])
        let windowedProjection = Self.projectFindMatches(
            matches,
            window: window,
            activeFindIndex: activeFindIndex
        )
        let windowedMatches = windowedProjection.matches
        let activeWindowMatchIndex = windowedProjection.activeIndex
        let blockProjectionKey = TranscriptBlockProjectionKey(
            routeIdentity: transcriptIdentity,
            revision: model.messagesRevision,
            range: window.range
        )
        let windowedBlocks = transcriptBlocks(
            for: windowedMessages,
            key: blockProjectionKey
        )
        // Capture the publication generation, not the latest streaming
        // generation. A stream can begin while the first rows are painting.
        let visibilityGeneration = (
            transcriptVisibilitySessionID == model.selectedSessionID
            ? transcriptVisibilityGeneration
            : nil
        ) ?? model.openGeneration
        let rendererInput = TranscriptRendererInput(
            blocks: windowedBlocks,
            messages: windowedMessages,
            window: window,
            routeIdentity: transcriptIdentity,
            generation: visibilityGeneration,
            isReadOnly: isReadOnly,
            isStreaming: messages.last?.isStreaming == true,
            findQuery: query,
            findMatches: windowedMatches,
            activeFindIndex: activeWindowMatchIndex,
            pendingMessageID: initialMessageTarget,
            onRequestOlder: {
                guard window.hasMoreOlderMessages, !messages.isEmpty else { return }
                isPrimingTranscriptWindow = false
                transcriptWindowState = TranscriptWindowPolicy.grow(
                    totalMessageCount: messages.count,
                    requestedWindowSize: Self.transcriptWindowSize,
                    currentState: window.state
                ).state
            },
            onCopyCode: { code in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            },
            onPaint: { visibleAtNanoseconds in
                guard HermternalSwitchTrace.isEnabled else { return }
                Task { @MainActor in
                    markTranscriptVisible(
                        sessionID: model.selectedSessionID,
                        generation: visibilityGeneration,
                        routeIdentity: transcriptIdentity,
                        renderedRows: windowedBlocks.count,
                        visibleAtNanoseconds: visibleAtNanoseconds,
                        largestRowCharacterCount: {
                            largestRenderedRowCharacterCount {
                                windowedMessages
                            }
                        }
                    )
                }
            }
        )

        BlockTranscriptView(input: rendererInput)
            .id(transcriptIdentity)
            .onChange(of: model.pendingMessageLocation) {
                if model.pendingMessageLocation != nil {
                    _ = capturePendingMessageTarget(targetIndex: pendingTargetIndex)
                }
            }
            .onChange(of: isFindPresented) {
                if isFindPresented {
                    isPrimingTranscriptWindow = false
                    includeActiveFindTarget(matches: matches)
                }
            }
            .onChange(of: findQuery) {
                activeFindIndex = 0
                includeActiveFindTarget(matches: matches)
            }
            .onChange(of: activeFindIndex) {
                includeActiveFindTarget(matches: matches)
            }
            .onChange(of: model.selectedSessionID) { _, _ in
                resetTranscriptRendererRoute()
                if model.pendingMessageLocation != nil {
                    _ = capturePendingMessageTarget(targetIndex: pendingTargetIndex)
                } else {
                    includeActiveFindTarget(matches: matches)
                }
            }
            .onChange(of: model.viewingArchivedSessionID) { _, _ in
                resetTranscriptRendererRoute()
                if model.pendingMessageLocation != nil {
                    _ = capturePendingMessageTarget(targetIndex: pendingTargetIndex)
                } else {
                    includeActiveFindTarget(matches: matches)
                }
            }
            .onChange(of: model.messages.count) {
                if model.pendingMessageLocation != nil {
                    _ = capturePendingMessageTarget(targetIndex: pendingTargetIndex)
                } else if isFindPresented {
                    includeActiveFindTarget(matches: matches)
                } else if !model.messages.isEmpty {
                    isPrimingTranscriptWindow = false
                    transcriptWindowState = TranscriptWindowPolicy.reset(
                        totalMessageCount: model.messages.count,
                        requestedWindowSize: Self.transcriptWindowSize
                    ).state
                }
            }
            .onAppear {
                if model.pendingMessageLocation != nil {
                    _ = capturePendingMessageTarget(targetIndex: pendingTargetIndex)
                } else {
                    includeActiveFindTarget(matches: matches)
                }
            }
            .overlay {
                if messages.isEmpty {
                    EmptyState()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = messages.last,
                          message.role == .assistant,
                          message.isStreaming,
                          message.text.isEmpty {
                    ThinkingIndicator()
                }
            }
        .mask(Self.transcriptTopDissolve)
        .task(id: blockProjectionKey) {
            await prepareTranscriptBlocks(windowedMessages, key: blockProjectionKey)
        }
        .overlay(alignment: .top) {
            if isFindPresented {
                let selectedMatchNumber = matches.indices.contains(activeFindIndex)
                    ? activeFindIndex + 1
                    : nil
                FindBar(
                    query: $findQuery,
                    matchCount: matches.count,
                    selectedMatchNumber: selectedMatchNumber,
                    next: { advanceFind(by: 1, matches: matches) },
                    previous: { advanceFind(by: -1, matches: matches) },
                    close: closeFind
                )
                .padding(.top, 12)
                .padding(.horizontal, 18)
            }
        }
    }

    private static func projectFindMatches(
        _ matches: [TranscriptMatch],
        window: TranscriptWindow,
        activeFindIndex: Int
    ) -> (matches: [TranscriptMatch], activeIndex: Int?) {
        var windowedMatches: [TranscriptMatch] = []
        windowedMatches.reserveCapacity(min(matches.count, window.range.count))
        var activeWindowMatchIndex: Int?
        for (matchIndex, match) in matches.enumerated() {
            guard window.range.contains(match.messageIndex) else { continue }
            if matchIndex == activeFindIndex {
                activeWindowMatchIndex = windowedMatches.count
            }
            windowedMatches.append(
                TranscriptMatch(
                    messageIndex: match.messageIndex - window.range.lowerBound,
                    range: match.range
                )
            )
        }
        return (windowedMatches, activeWindowMatchIndex)
    }

    /// The soft pocket the composer sits in: a fixed ramp above it, then
    /// solid material from the capsule down to the window edge. Expressed in
    /// points rather than gradient stops so the ramp height stays put no
    /// matter how tall the composer grows.
    private static var composerHalo: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(height: Self.haloRamp)
            Rectangle()
                .fill(.ultraThinMaterial)
        }
        .padding(.top, -Self.haloRamp)
        .allowsHitTesting(false)
    }

    /// A hint that rows continue under the titlebar, not a visible gradient.
    ///
    /// Deliberately much shorter than the sidebar's 48pt ramp and far shorter
    /// than the 130pt the deleted SwiftUI transcript used: the titlebar's own
    /// backing is now cleared on every translucent treatment, so this only has
    /// to soften the last few points before the chrome rather than hide an
    /// opaque plate. Anything a reader notices is too strong.
    ///
    /// Seven stops on a smoothstep rather than three, for the reason the
    /// sidebar's ramp was reshaped: evenly spaced stops with a single slope
    /// change leave a visible facet in the mid-alpha range, where the eye
    /// resolves banding best. The mask is a content mask on the transcript
    /// itself, since a material plate cannot obscure in-window siblings.
    private static var transcriptTopDissolve: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: .black.opacity(0.06), location: 0.18),
                    .init(color: .black.opacity(0.20), location: 0.36),
                    .init(color: .black.opacity(0.42), location: 0.54),
                    .init(color: .black.opacity(0.66), location: 0.70),
                    .init(color: .black.opacity(0.86), location: 0.85),
                    .init(color: .black, location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.topDissolveReach)
            Rectangle().fill(.black)
        }
        .allowsHitTesting(false)
    }

    private static let topDissolveReach: CGFloat = 28

    private static let haloRamp: CGFloat = 34

}


private struct EmptyState: View {
    var body: some View {
        // The composer already reads "Message Hermes…", so a heading here
        // would only repeat it. The mark carries the state alone: no copy,
        // no surface, no motion.
        HermternalMarkView(size: 128)
            .frame(maxWidth: .infinity)
    }
}

/// Shown as a SwiftUI overlay while an assistant stream has no text.
private struct ThinkingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 5, height: 5)
                    .foregroundStyle(.secondary)
                    .opacity(0.35 + 0.65 * abs(sin(phase + Double(index) * 0.6)))
            }
        }
        .task {
            // A timer beats a repeatForever animation here: it stops cleanly
            // when the row is replaced by real text.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(90))
                phase += 0.22
            }
        }
    }
}

private struct Composer: View {
    @Bindable var model: AppModel
    let focusRequest: Int
    @FocusState private var isFocused: Bool
    @State private var handledFocusRequest = 0
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Hermes…", text: $model.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .onSubmit { send() }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("field", in: glass)

                Button {
                    if model.isAwaitingReply {
                        Task { await model.interrupt() }
                    } else {
                        send()
                    }
                } label: {
                    Image(systemName: model.isAwaitingReply ? "stop.fill" : "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .clipShape(.circle)
                .glassEffectID("send", in: glass)
                .disabled(!model.isAwaitingReply && model.composerText.isEmptyAfterTrim)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .onChange(of: focusRequest) { _, request in
            guard request != handledFocusRequest else { return }
            handledFocusRequest = request
            isFocused = true
        }
    }
    private func send() {
        Task { await model.send() }
    }
}

/// Hides only the title text while leaving the native titlebar and traffic
/// lights intact. A hidden-titlebar window style would remove those controls.
struct HiddenWindowTitle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowTitleHider {
        WindowTitleHider()
    }

    func updateNSView(_ nsView: WindowTitleHider, context: Context) {
        nsView.hideTitle()
    }
}

final class WindowTitleHider: NSView {
    fileprivate func hideTitle() {
        guard let window else { return }
        window.title = ""
        window.titleVisibility = .hidden
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideTitle()
        // SwiftUI may install the unified toolbar after the representable
        // joins the window; re-apply once that titlebar update has settled.
        DispatchQueue.main.async { [weak self] in
            self?.hideTitle()
        }
    }
}

private extension String {
    var isEmptyAfterTrim: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
