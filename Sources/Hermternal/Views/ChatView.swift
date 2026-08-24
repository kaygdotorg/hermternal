import SwiftUI
import HermternalCore
import AppKit

struct ChatView: View {
    @Bindable var model: AppModel
    let isReadOnly: Bool
    @State private var pendingScrollTask: Task<Void, Never>?
    /// Set only while the selected-session replacement owns bottom positioning.
    /// The message-count observer must not cancel or duplicate this scroll when
    /// the replacement transcript arrives in the same update.
    @State private var replacementScrollSessionID: String?
    @State private var isFindPresented = false
    @State private var findQuery = ""
    @State private var activeFindIndex = 0
    @State private var scrollPosition: MessageIdentity?
    @State private var messageTargetActive = false
    @State private var transcriptWindowState: TranscriptWindowState?
    @State private var windowGrowthTask: Task<Void, Never>?
    @State private var isGrowingWindow = false
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
        if messageTargetActive {
            // A nil write-back means the user has scrolled away. Do not fall
            // through to the routed identity and pull them back.
            return scrollPosition
        }
        guard let location = model.pendingMessageLocation,
              model.selectedSessionID == location.sessionID
        else { return nil }
        // Keep the requested identity bound before the transcript arrives.
        // With scrollTargetLayout below, SwiftUI applies this position during
        // the first layout that contains the target row; no proxy scroll is
        // needed after the transcript has painted.
        return .server(location.messageID)
    }


    private var hasPositionedMessageTarget: Bool {
        messageTargetActive
    }

    private var messageScrollPosition: Binding<MessageIdentity?> {
        Binding(
            get: { initialMessageTarget },
            set: { newPosition in
                guard messageTargetActive else { return }
                scrollPosition = newPosition
            }
        )
    }
    @MainActor
    private func capturePendingMessageTarget(targetIndex: Int?) -> Bool {
        guard let location = model.pendingMessageLocation,
              model.selectedSessionID == location.sessionID,
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
        messageTargetActive = true
        scrollPosition = .server(location.messageID)
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
    private func resetAppKitTranscriptRoute() {
        pendingScrollTask?.cancel()
        pendingScrollTask = nil
        windowGrowthTask?.cancel()
        windowGrowthTask = nil
        isPrimingTranscriptWindow = true
        isGrowingWindow = false
        transcriptWindowState = nil
        scrollPosition = nil
        messageTargetActive = false
        replacementScrollSessionID = nil
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
        renderedRows: Int
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
            renderedRows: renderedRows
        ) else {
            return
        }
        transcriptVisibilityEmitted = true
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

    private func activateFindMatch(
        using proxy: ScrollViewProxy,
        matches: [TranscriptMatch],
        messages: [ChatMessage]
    ) {
        guard isFindPresented,
              matches.indices.contains(activeFindIndex)
        else { return }
        let messageIndex = matches[activeFindIndex].messageIndex
        guard messages.indices.contains(messageIndex) else { return }
        let messageID = messages[messageIndex].id
        let window = TranscriptWindowPolicy.resolve(
            totalMessageCount: messages.count,
            requestedWindowSize: Self.transcriptWindowSize,
            currentState: transcriptWindowState
        )
        pendingScrollTask?.cancel()
        pendingScrollTask = nil
        replacementScrollSessionID = nil

        if !window.range.contains(messageIndex) {
            transcriptWindowState = TranscriptWindowPolicy.including(
                targetIndex: messageIndex,
                totalMessageCount: messages.count,
                requestedWindowSize: Self.transcriptWindowSize,
                currentState: window.state
            ).state
            pendingScrollTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled,
                      isFindPresented,
                      model.messages.contains(where: { $0.id == messageID })
                else {
                    pendingScrollTask = nil
                    return
                }
                withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo(messageID, anchor: .center)
                }
                pendingScrollTask = nil
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.28)) {
            proxy.scrollTo(messageID, anchor: .center)
        }
    }

    @MainActor
    private func growTranscriptWindow(
        using proxy: ScrollViewProxy,
        messages: [ChatMessage],
        window: TranscriptWindow
    ) {
        guard window.hasMoreOlderMessages,
              !isGrowingWindow,
              messages.indices.contains(window.range.lowerBound)
        else { return }
        isGrowingWindow = true
        let anchorID = messages[window.range.lowerBound].id
        let grown = TranscriptWindowPolicy.grow(
            totalMessageCount: messages.count,
            requestedWindowSize: Self.transcriptWindowSize,
            currentState: window.state
        )
        transcriptWindowState = grown.state
        windowGrowthTask?.cancel()
        windowGrowthTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else {
                isGrowingWindow = false
                windowGrowthTask = nil
                return
            }
            proxy.scrollTo(anchorID, anchor: .top)
            isGrowingWindow = false
            windowGrowthTask = nil
        }
    }
    @MainActor
    private func finishInitialTranscriptWindow(
        using proxy: ScrollViewProxy,
        window: TranscriptWindow,
        totalMessageCount: Int,
        generation: Int,
        sessionID: String?
    ) {
        guard isPrimingTranscriptWindow,
              totalMessageCount > 0,
              let sessionID
        else { return }

        isPrimingTranscriptWindow = false
        HermternalSwitchTrace.session(
            "transcript.firstFrame",
            id: sessionID,
            generation: generation,
            messages: totalMessageCount,
            renderedRows: window.range.count
        )

        guard window.hasMoreOlderMessages else { return }
        windowGrowthTask?.cancel()
        windowGrowthTask = Task { @MainActor in
            guard !Task.isCancelled,
                  model.openGeneration == generation,
                  model.selectedSessionID == sessionID,
                  !hasPositionedMessageTarget,
                  !isFindPresented
            else {
                windowGrowthTask = nil
                return
            }
            let grown = TranscriptWindowPolicy.grow(
                totalMessageCount: model.messages.count,
                requestedWindowSize: Self.transcriptWindowSize,
                currentState: window.state,
                growthBy: TranscriptWindowPolicy.extensionStep
            )
            transcriptWindowState = grown.state
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            windowGrowthTask = nil
        }
    }


    @ViewBuilder
    private var transcript: some View {
        let messages = model.messages
        let query = isFindPresented ? findQuery : ""
        let matches = model.transcriptMatches(for: query)
        let activeFindMatch = matches.indices.contains(activeFindIndex)
            ? matches[activeFindIndex]
            : nil
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
        let activeFindTargetIndex = isFindPresented
            ? activeFindMatch?.messageIndex
            : nil
        let windowTargetIndex = pendingTargetIndex ?? activeFindTargetIndex
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
        // Capture the publication generation, not the latest streaming
        // generation. A stream can begin while the first rows are painting.
        let visibilityGeneration = (
            transcriptVisibilitySessionID == model.selectedSessionID
            ? transcriptVisibilityGeneration
            : nil
        ) ?? model.openGeneration
        Group {
        if !Self.usesAppKitTranscript {
            ScrollViewReader { proxy in
            transcriptScrollView(
                using: proxy,
                messages: messages,
                window: window,
                query: query,
                windowedMatches: windowedMatches,
                activeMessageID: activeFindMatch.flatMap { match in
                    messages.indices.contains(match.messageIndex)
                        ? messages[match.messageIndex].id
                        : nil
                },
                visibilityGeneration: visibilityGeneration,
                routeIdentity: transcriptIdentity
            )
            .id(transcriptIdentity)
            .onChange(of: model.pendingMessageLocation) {
                if model.pendingMessageLocation == nil {
                    scrollPosition = nil
                    messageTargetActive = false
                } else {
                    _ = capturePendingMessageTarget(targetIndex: pendingTargetIndex)
                }
            }
            .onChange(of: isFindPresented) {
                if isFindPresented {
                    isPrimingTranscriptWindow = false
                }
                activateFindMatch(using: proxy, matches: matches, messages: messages)
            }
            .onChange(of: findQuery) {
                activateFindMatch(using: proxy, matches: matches, messages: messages)
            }
            .onChange(of: model.selectedSessionID) { _, selectedID in
                HermternalSelectionOccupancyTrace.observerInvoked(
                    forChatID: selectedID,
                    messages: model.messages.count
                )
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
                windowGrowthTask?.cancel()
                windowGrowthTask = nil
                isPrimingTranscriptWindow = true
                isGrowingWindow = false
                transcriptWindowState = nil
                scrollPosition = nil
                messageTargetActive = false
                replacementScrollSessionID = nil

                // A live transcript switch should reveal the recent end even
                // when the replacement has the same message count. Deep-link
                // and Find positioning remain authoritative, as does the
                // archived read-only transcript.
                if let selectedID,
                   let location = model.pendingMessageLocation,
                   location.sessionID == selectedID {
                    isPrimingTranscriptWindow = false
                    pendingScrollTask = Task { @MainActor in
                        await Task.yield()
                        guard !Task.isCancelled else {
                            pendingScrollTask = nil
                            return
                        }
                        _ = capturePendingMessageTarget(targetIndex: pendingTargetIndex)
                        pendingScrollTask = nil
                    }
                    return
                }

                if let selectedID,
                   isFindPresented,
                   model.pendingMessageLocation == nil {
                    isPrimingTranscriptWindow = false
                    pendingScrollTask = Task { @MainActor in
                        await Task.yield()
                        guard !Task.isCancelled,
                              model.selectedSessionID == selectedID,
                              isFindPresented,
                              model.pendingMessageLocation == nil
                        else {
                            pendingScrollTask = nil
                            return
                        }
                        let currentMessages = model.messages
                        let currentMatches = model.transcriptMatches(for: findQuery)
                        activateFindMatch(using: proxy, matches: currentMatches, messages: currentMessages)
                        pendingScrollTask = nil
                    }
                    return
                }

                guard !isReadOnly,
                      model.viewingArchivedSessionID == nil,
                      let selectedID,
                      model.pendingMessageLocation == nil,
                      !hasPositionedMessageTarget,
                      !isFindPresented
                else { return }

                replacementScrollSessionID = selectedID
                pendingScrollTask = Task { @MainActor in
                    await Task.yield()
                    guard !Task.isCancelled,
                          replacementScrollSessionID == selectedID,
                          model.selectedSessionID == selectedID,
                          model.viewingArchivedSessionID == nil,
                          model.pendingMessageLocation == nil,
                          !hasPositionedMessageTarget,
                          !isFindPresented,
                          !model.messages.isEmpty
                    else {
                        if replacementScrollSessionID == selectedID {
                            replacementScrollSessionID = nil
                            pendingScrollTask = nil
                        }
                        return
                    }
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    replacementScrollSessionID = nil
                    pendingScrollTask = nil
                }
            }
            .onChange(of: model.viewingArchivedSessionID) { _, _ in
                // The route key can change while selectedSessionID remains
                // equal (an archived/live identifier collision). Re-apply
                // routed and Find positioning against the replacement rows.
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
                windowGrowthTask?.cancel()
                windowGrowthTask = nil
                isPrimingTranscriptWindow = true
                isGrowingWindow = false
                transcriptWindowState = nil
                scrollPosition = nil
                messageTargetActive = false
                replacementScrollSessionID = nil
                if model.pendingMessageLocation != nil {
                    _ = capturePendingMessageTarget(targetIndex: pendingTargetIndex)
                    return
                }
                guard isFindPresented else { return }
                isPrimingTranscriptWindow = false
                let currentMessages = model.messages
                let currentMatches = model.transcriptMatches(for: findQuery)
                activateFindMatch(
                    using: proxy,
                    matches: currentMatches,
                    messages: currentMessages
                )
            }
            .onChange(of: model.messages.last?.text) {
                guard model.pendingMessageLocation == nil else { return }
                guard !hasPositionedMessageTarget else { return }
                guard !isFindPresented else { return }
                guard pendingScrollTask == nil else { return }
                pendingScrollTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .milliseconds(20))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    pendingScrollTask = nil
                }
            }
            .onChange(of: model.messages.count) { oldCount, newCount in
                // A routed target remains authoritative, even when its row
                // arrives in the same update as a selected-session change.
                guard !hasPositionedMessageTarget else { return }
                if model.pendingMessageLocation != nil {
                    // A target arriving during replacement wins immediately.
                    // Cancel either kind of pending bottom-follow task before
                    // binding the target so it cannot pull the view back down.
                    replacementScrollSessionID = nil
                    pendingScrollTask?.cancel()
                    pendingScrollTask = nil
                    _ = capturePendingMessageTarget(targetIndex: pendingTargetIndex)
                    return
                }

                if isFindPresented {
                    // Find positioning owns the viewport while active.
                    pendingScrollTask?.cancel()
                    pendingScrollTask = nil
                    replacementScrollSessionID = nil
                    return
                }
                // A replacement task owns this update. Leave it intact so
                // equal- and unequal-count session switches each paint once.
                guard replacementScrollSessionID == nil else { return }
                isPrimingTranscriptWindow = false
                transcriptWindowState = TranscriptWindowPolicy.reset(
                    totalMessageCount: newCount,
                    requestedWindowSize: Self.transcriptWindowSize
                ).state

                // From here on this is a same-session transcript update.
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
                guard !isFindPresented else { return }
                guard model.selectedSessionID != nil,
                      model.viewingArchivedSessionID == nil,
                      !model.messages.isEmpty
                else { return }

                if newCount == oldCount + 1 {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onAppear {
                _ = capturePendingMessageTarget(targetIndex: pendingTargetIndex)
            }
            .onDisappear {
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
                windowGrowthTask?.cancel()
                windowGrowthTask = nil
                isGrowingWindow = false
                replacementScrollSessionID = nil
            }
            }
        } else {
            AppKitTranscript(
                messages: windowedMessages,
                routeIdentity: transcriptIdentity,
                isReadOnly: isReadOnly,
                isStreaming: messages.last?.isStreaming == true,
                findQuery: query,
                findMatches: windowedMatches,
                activeFindIndex: activeWindowMatchIndex,
                pendingMessageID: initialMessageTarget,
                onRequestOlder: {
                    guard window.hasMoreOlderMessages,
                          !messages.isEmpty
                    else { return }
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
                }
            )
            .id(transcriptIdentity)
            .overlay(alignment: .topLeading) {
                if HermternalSwitchTrace.isEnabled {
                    TranscriptPaintProbe {
                        markTranscriptVisible(
                            sessionID: model.selectedSessionID,
                            generation: visibilityGeneration,
                            routeIdentity: transcriptIdentity,
                            renderedRows: window.range.count
                        )
                    }
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: model.pendingMessageLocation) {
                if model.pendingMessageLocation == nil {
                    scrollPosition = nil
                    messageTargetActive = false
                } else {
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
                resetAppKitTranscriptRoute()
                if model.pendingMessageLocation != nil {
                    _ = capturePendingMessageTarget(targetIndex: pendingTargetIndex)
                } else {
                    includeActiveFindTarget(matches: matches)
                }
            }
            .onChange(of: model.viewingArchivedSessionID) { _, _ in
                resetAppKitTranscriptRoute()
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
        }
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
    private func transcriptScrollView(
        using proxy: ScrollViewProxy,
        messages: [ChatMessage],
        window: TranscriptWindow,
        query: String,
        windowedMatches: [TranscriptMatch],
        activeMessageID: ChatMessage.ID?,
        visibilityGeneration: Int,

        routeIdentity: String
    ) -> some View {
        let rangesByMessageID = Dictionary(
            grouping: windowedMatches,
            by: { messages[$0.messageIndex + window.range.lowerBound].id }
        ).mapValues { $0.map(\.range) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                transcriptRows(
                    using: proxy,
                    messages: messages,
                    window: window,
                    query: query,
                    rangesByMessageID: rangesByMessageID,
                    activeMessageID: activeMessageID,
                    visibilityGeneration: visibilityGeneration,
                    routeIdentity: routeIdentity
                )
            }
            .scrollTargetLayout()
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // The anchor also decides how content smaller than the container
        // is aligned, and `.bottom` pinned the lone mark just above the
        // composer. With no messages there is nothing to keep at the
        // bottom, so it centers instead — in the region the scroll view
        // has already had reduced by the titlebar above and the composer
        // inset below.
        .defaultScrollAnchor(messages.isEmpty ? .center : .bottom)
        .scrollPosition(id: messageScrollPosition, anchor: .center)
        .transaction { transaction in
            transaction.animation = nil
        }
        .overlay(alignment: .top) { Self.topFade }
        // The viewport overlay is drawn after its scroll content. Unlike a
        // row's `onAppear` or the zero-height first-frame anchor, this probe
        // cannot run until layout has produced a paint pass for the rows
        // currently on screen. One probe per transcript keeps the cost below
        // one probe per row and also works when deep-link/Find positioning
        // leaves the window's last row below the viewport.
        .overlay(alignment: .topLeading) {
            if HermternalSwitchTrace.isEnabled {
                TranscriptPaintProbe {
                    markTranscriptVisible(
                        sessionID: model.selectedSessionID,
                        generation: visibilityGeneration,
                        routeIdentity: routeIdentity,
                        renderedRows: window.range.count
                    )
                }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func transcriptRows(
        using proxy: ScrollViewProxy,
        messages: [ChatMessage],
        window: TranscriptWindow,
        query: String,
        rangesByMessageID: [ChatMessage.ID: [Range<Int>]],
        activeMessageID: ChatMessage.ID?,
        visibilityGeneration: Int,
        routeIdentity: String
    ) -> some View {
        if messages.isEmpty {
            // Placed by the centered alignment anchor below, so
            // the mark carries no inset of its own.
            EmptyState()
        }
        if window.hasMoreOlderMessages {
            // This row already belongs to the scroll content, so
            // appearing at the top is the user's demand for older
            // local rows. It carries no loading state or spinner.
            Color.clear
                .frame(height: 1)
                .id(Self.topAnchor)
                .onAppear {
                    guard !isPrimingTranscriptWindow else { return }
                    growTranscriptWindow(
                        using: proxy,
                        messages: messages,
                        window: window
                    )
                }
        }
        ForEach(window.range, id: \.self) { messageIndex in
            let message = messages[messageIndex]
            let matchRanges = rangesByMessageID[message.id] ?? []
            MessageRow(
                message: message,
                sessionID: model.selectedSessionID,
                gatewayHost: model.configuredGatewayHost,
                findQuery: query,
                matchRanges: matchRanges,
                isFindActive: activeMessageID == message.id
            )
            .id(message.id)
        }
        // This anchor remains a positioning control signal, not the visible
        // marker: its zero-height `onAppear` only proves graph insertion and
        // may run before the transcript rows have reached a paint pass.
        // Zero-height anchor: scrolling to the last message id
        // lands short while its own height is still growing.
        Color.clear
            .frame(height: 1)
            .id(Self.bottomAnchor)
        Color.clear
            .frame(height: 0)
            .id("\(Self.firstFrameAnchor).\(model.selectedSessionID ?? "none")")
            .onAppear {
                finishInitialTranscriptWindow(
                    using: proxy,
                    window: window,
                    totalMessageCount: messages.count,
                    generation: model.openGeneration,
                    sessionID: model.selectedSessionID
                )
            }
    }

    /// Hiding the toolbar backing is what makes the titlebar glass, but it
    /// also removes the built-in scroll edge effect, so the progressive blur
    /// is drawn here instead.
    ///
    /// One masked material rather than stacked bands: a gradient mask fades
    /// continuously, so there are no seams between opacity steps. The stops
    /// are weighted toward the top so the tail is long and the falloff stays
    /// gentle instead of ending on a visible line.
    private static var topFade: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.75), location: 0.30),
                        .init(color: .black.opacity(0.35), location: 0.55),
                        .init(color: .black.opacity(0.12), location: 0.76),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: 130)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
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

    private static let haloRamp: CGFloat = 34

    /// AppKit transcript rendering is opt-in while the SwiftUI route remains
    /// the default.
    private static let usesAppKitTranscript =
        ProcessInfo.processInfo.environment["HERMTERNAL_APPKIT_TRANSCRIPT"] == "1"

    private static let transcriptWindowSize = TranscriptWindowPolicy.defaultWindowSize
    private static let bottomAnchor = "transcript.bottom"
    private static let topAnchor = "transcript.top"
    private static let firstFrameAnchor = "transcript.first-frame"
}

/// DEBUG-switch-7F3A: a one-point AppKit overlay used on the transcript
/// viewport. `draw(_:)` runs from the viewport's paint pass, after SwiftUI
/// has laid out its scroll content; unlike `onAppear`, it cannot report a
/// view that exists only in the graph.
private struct TranscriptPaintProbe: NSViewRepresentable {
    let onPaint: () -> Void

    func makeNSView(context: Context) -> PaintView {
        PaintView(onPaint: onPaint)
    }

    func updateNSView(_ nsView: PaintView, context: Context) {
        nsView.onPaint = onPaint
        nsView.needsDisplay = true
    }
    final class PaintView: NSView {
        var onPaint: () -> Void

        init(onPaint: @escaping () -> Void) {
            self.onPaint = onPaint
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            onPaint()
        }
    }
}

private struct EmptyState: View {
    /// The effective scheme, so an explicit app appearance and the system
    /// setting both resolve to the matching drawing.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The composer already reads "Message Hermes…", so a heading here
        // would only repeat it. The mark carries the state alone: no copy,
        // no surface, no motion.
        mark
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var mark: some View {
        if let image = HermternalMark.image(for: colorScheme) {
            Image(nsImage: image)
                // At 128pt the 256px drawing lands on a Retina backing store
                // 1:1; on a 1x display it is a clean 2:1 downscale, where the
                // better sampler still keeps the line art from aliasing.
                .interpolation(.high)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.markSize, height: Self.markSize)
                .accessibilityLabel("Hermternal")
        } else {
            // The drawing is missing whenever the process runs without its
            // bundle resources, which is what `swift run` does. That is a
            // packaging fault and `HermternalMark` reports it, but the state
            // still has to read as something, so it falls back to the
            // platform's terminal glyph rather than leaving the pane blank.
            //
            // A weight lighter than the 64pt mark used: symbol strokes scale
            // with point size, so `.light` at 128pt reads heavier than the
            // hairline drawing this stands in for.
            Image(systemName: "terminal")
                .font(.system(size: Self.markSize, weight: .ultraLight))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Hermternal")
        }
    }

    /// Alone in the pane the mark is the entire state, so it is sized as a
    /// focal element rather than an ornament. 128pt is the macOS icon step
    /// above the old 64pt and the only size in that range where the 256px
    /// drawing maps to Retina pixels 1:1. In a default-sized window it fills
    /// roughly a fifth of the empty region's height: prominent, and nowhere
    /// near crowding it.
    private static let markSize: CGFloat = 128
}

/// The light and dark drawings of the app mark, decoded at most once each.
///
/// `NSImage(contentsOf:)` reads and decodes the file, so loading inside a
/// `body` would repeat that work on every evaluation. Main-actor isolation
/// is what makes a `static let` of a non-Sendable `NSImage` legal under
/// strict concurrency; view bodies are the only caller.
@MainActor
private enum HermternalMark {
    static func image(for colorScheme: ColorScheme) -> NSImage? {
        colorScheme == .dark ? dark : light
    }

    private static let light = load("HermternalMarkLight")
    private static let dark = load("HermternalMarkDark")

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else {
            Log.error("Missing bundle resource \(name).png")
            return nil
        }
        return image
    }
}

/// The app's own mark as a row avatar, so a reply is attributed to
/// Hermternal rather than to a borrowed system glyph.
///
/// The drawing comes from `HermternalMark`, which decodes each appearance
/// once and holds it, so a row never decodes anything of its own.
private struct AssistantMark: View {
    /// The effective scheme, so an explicit app appearance and the system
    /// setting both resolve to the matching drawing, exactly as the app icon
    /// does.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        mark
            // The container is one body line box tall, and centring in it is
            // what aligns the mark: the 13pt body's cap band runs 3.10–12.40pt
            // inside its 16pt line box, so the band's centre is 7.75pt and the
            // box's is 8pt — a quarter point apart. It holds whatever the reply
            // opens with, where a first-baseline guide would resolve against a
            // code block's header when a reply starts with a fence.
            //
            // Only this box takes part in layout, so the drawing is free to be
            // taller than one line: it overhangs the box by 2pt at each end,
            // the alignment rule and the 30pt gutter both stay exact, and the
            // 18pt gap between rows absorbs the overhang.
            .frame(width: Self.size, height: Self.lineBox)
    }

    @ViewBuilder
    private var mark: some View {
        if let image = HermternalMark.image(for: colorScheme) {
            Image(nsImage: image)
                // 40px on a Retina backing store out of a 256px drawing, so
                // unlike the empty state's 1:1 mapping this is a real
                // reduction and the silhouette's edges need the better sampler.
                .interpolation(.high)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.size, height: Self.size)
                .accessibilityLabel("Hermternal")
        } else {
            // Same contract as the empty state: the drawing is absent only
            // when the process runs without its bundle resources, which
            // `HermternalMark` reports as a packaging fault. The reply still
            // has to be attributed, so the row keeps the platform glyph it
            // carried before. Its column comes from the shared box above, so
            // the gutter — and with it the reading measure — is identical on
            // either branch; the point size can only match the drawing's box,
            // since a symbol's glyph sits inside its em box rather than
            // filling it.
            Image(systemName: "sparkle")
                .font(.system(size: Self.size))
                .foregroundStyle(.tint)
                .accessibilityLabel("Hermternal")
        }
    }

    /// The drawing's box, and the width of the mark's column in the row.
    ///
    /// The artwork carries almost no padding — the light drawing's ink fills
    /// 253 of the 256 rows and 191 of the columns — so a square box of this
    /// size renders ink 19.8pt tall by 14.9pt wide. At the old 12pt that was
    /// 11.9 by 9.0pt, and width is what the eye judges at a glance: 9.0pt put
    /// the mark *narrower* than the 9.3pt cap height of the 13pt body beside
    /// it, so a dense silhouette with a crest and two legs had less room than
    /// a capital letter and read as a smudge rather than as a sender.
    ///
    /// 20pt puts the ink at 1.6× that cap height across and one line of prose
    /// tall — the 19pt body pitch — which is also the ceiling: attribution may
    /// span the line it belongs to and never a second one. Subordination comes
    /// from everything else being unchanged: no type weight, no surface, no
    /// colour of its own, and a fixed column outside the reading measure, so
    /// the mark cannot enter the text's reading order or shift a word of it.
    private static let size: CGFloat = 20

    /// The body's line height, used only as the vertical centring box.
    ///
    /// The column is `size` wide, so with the row's 10pt spacing the gutter is
    /// 20 + 10pt — what `MessageTypography.readingMeasure` subtracts from the
    /// 680pt column, along with its 44pt of padding and 96pt of trailing air.
    private static let lineBox: CGFloat = 16
}

private struct MessageRow: View {
    let message: ChatMessage
    let sessionID: String?
    let gatewayHost: String?
    let findQuery: String
    let matchRanges: [Range<Int>]
    let isFindActive: Bool
    var body: some View {
        rowContent
            .contextMenu {
                if let gatewayHost,
                   let sessionID,
                   let link = MessageDeepLink(
                       gatewayHost: gatewayHost,
                       sessionID: sessionID,
                       messageIdentity: message.id
                   ) {
                    Button("Copy Message Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            link.url.absoluteString,
                            forType: .string
                        )
                    }
                }
            }
    }

    @ViewBuilder
    private var rowContent: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Group {
                    if findQuery.isEmpty {
                        Text(message.text)
                            // A pasted user message is long-form too, so it
                            // reads at the same contrast and leading as a
                            // reply. Role is carried by the tint and the
                            // right-hand alignment, never by dimming text.
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineSpacing(MessageTypography.bodyLineSpacing)
                            .textSelection(.enabled)
                    } else {
                        FindHighlightedMessage(
                            text: message.text,
                            isPlainText: true,
                            matchRanges: matchRanges,
                            isActive: isFindActive
                        )
                    }
                }
                .padding(.horizontal, MessageTypography.bubblePadding)
                .padding(.vertical, 10)
                .background(
                    .tint.opacity(0.16),
                    in: .rect(
                        cornerRadius: AppShapeScale.toast,
                        style: .continuous
                    )
                )
                // Gives a user message the same measure as a reply. The cap
                // sits outside the background, so it only adds transparent
                // trailing space — the bubble still hugs its own text.
                .frame(
                    maxWidth: MessageTypography.userBubbleMeasure,
                    alignment: .trailing
                )
            }
        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                AssistantMark()
                VStack(alignment: .leading, spacing: 6) {
                    if findQuery.isEmpty {
                        MarkdownMessage(text: message.text, isStreaming: message.isStreaming)
                    } else {
                        FindHighlightedMessage(
                            text: message.text,
                            isPlainText: message.isStreaming,
                            matchRanges: matchRanges,
                            isActive: isFindActive
                        )
                    }
                    if message.isStreaming && message.text.isEmpty {
                        ThinkingIndicator()
                    }
                }
                // Caps the line length rather than reserving a fixed gutter,
                // so the measure holds at full width and a narrow window
                // gives the space back to the text.
                .frame(maxWidth: MessageTypography.readingMeasure, alignment: .leading)
                Spacer(minLength: MessageTypography.assistantTrailingInset)
            }
        case .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(
                    isFindActive ? Color.orange.opacity(0.12) : .clear,
                    in: .rect(
                        cornerRadius: AppShapeScale.compact,
                        style: .continuous
                    )
                )
        }
    }
}

/// Shown only before the first token lands, so an empty bubble never sits
/// there looking stalled.
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
