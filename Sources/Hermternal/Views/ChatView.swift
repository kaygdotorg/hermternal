import SwiftUI
import HermternalCore
import AppKit


struct ChatView: View {
    @Bindable var model: AppModel
    let isReadOnly: Bool
    @Environment(\.hermternalAlwaysShowsChatMetadata) private var alwaysShowsChatMetadata
    @State private var isFindPresented = false
    @State private var findQuery = ""
    @State private var activeFindIndex = 0
    @State private var findMatches: [TranscriptFindMatch] = []
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
            // The AppKit hosting boundary clears the titlebar safe area, so
            // this ramp is measured from the physical window top.
            .mask { ChatPhysicalTopMask() }
            // The archived transcript has no bottom editing surface.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isReadOnly {
                    ComposerView(
                        model: model.composerModel,
                        focusRequest: composerFocusRequest
                    )
                }
            }
        .onChange(of: model.findRequestGeneration) { _, _ in
            openFind()
        }
        .onChange(of: model.composerFocusRequestGeneration) { _, _ in
            guard !isReadOnly else { return }
            composerFocusRequest &+= 1
        }
        .onChange(of: model.selectedSessionID) { oldID, newID in
            HermternalSelectionOccupancyTrace.observerInvoked(
                forChatID: newID,
                messages: model.transcriptSummary?.messageCount ?? 0
            )
            resetTranscriptVisibility(for: newID)
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
            messages: model.transcriptSummary?.messageCount ?? 0,
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



    private func openFind() {
        isFindPresented = true
        activeFindIndex = 0
    }

    private func closeFind() {
        isFindPresented = false
        findQuery = ""
        activeFindIndex = 0
    }

    private func advanceFind(by delta: Int) {
        guard !findMatches.isEmpty else { return }
        activeFindIndex = (activeFindIndex + delta + findMatches.count) % findMatches.count
    }
    @MainActor
    private func refreshFindMatches() async {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let cursor = await model.makeTranscriptFindCursor(query: query)
        else {
            findMatches = []
            activeFindIndex = 0
            return
        }
        var matches: [TranscriptFindMatch] = []
        matches.reserveCapacity(64)
        while matches.count < 256, !Task.isCancelled {
            guard let page = try? await cursor.next(maximumResults: 64),
                  !page.isEmpty
            else { break }
            matches.append(contentsOf: page)
        }
        findMatches = matches
        activeFindIndex = matches.isEmpty ? 0 : min(activeFindIndex, matches.count - 1)
    }

    /// Whether the pane has nothing at all to draw, and so shows the product
    /// mark instead.
    ///
    /// `TranscriptEmptyStatePolicy` owns the rule, so the macOS surface and a
    /// future iOS surface cannot disagree, and so a renderer change cannot
    /// silently redefine an empty chat again.
    private func isTranscriptEmpty(summary: TranscriptSummary?) -> Bool {
        TranscriptEmptyStatePolicy.showsEmptyState(
            publishedMessageCount: model.messages.count,
            summary: summary,
            selectedSessionID: model.selectedSessionID,
            archivedSessionID: model.viewingArchivedSessionID
        )
    }
    
    @ViewBuilder
    private var transcript: some View {
        let route = model.activeTranscriptRoute
        let summary = model.transcriptSummary
        let rendererInput = TranscriptRendererInput(
            store: model.activeTranscriptStore,
            route: route,
            summary: summary,
            revision: model.transcriptRevision,
            isReadOnly: isReadOnly,
            isStreaming: model.isAwaitingReply,
            findQuery: isFindPresented ? findQuery : "",
            pendingMessageID: model.pendingMessageLocation.map {
                String($0.messageID.rawValue)
            },
            findMessageID: findMatches.indices.contains(activeFindIndex)
                ? findMatches[activeFindIndex].descriptor.messageID
                : nil,
            showsMetadata: alwaysShowsChatMetadata,
            onCopyCode: { code in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            },
            onPaint: { visibleAtNanoseconds in
                guard HermternalSwitchTrace.isEnabled else { return }
                let generation = Int(route?.generation ?? 0)
                Task { @MainActor in
                    markTranscriptVisible(
                        sessionID: model.selectedSessionID,
                        generation: generation,
                        routeIdentity: transcriptIdentity,
                        renderedRows: summary?.rowCount ?? 0,
                        visibleAtNanoseconds: visibleAtNanoseconds,
                        largestRowCharacterCount: { nil }
                    )
                }
            }
        )

        BlockTranscriptView(input: rendererInput)
            .id(route.map { "\($0.sessionID):\($0.generation)" } ?? "none")
            .task(id: findQuery) {
                await refreshFindMatches()
            }
            .overlay {
                if isTranscriptEmpty(summary: summary) {
                    EmptyState()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        .overlay(alignment: .top) {
            if isFindPresented {
                FindBar(
                    query: $findQuery,
                    matchCount: findMatches.count,
                    selectedMatchNumber: findMatches.indices.contains(activeFindIndex)
                        ? activeFindIndex + 1
                        : nil,
                    next: { advanceFind(by: 1) },
                    previous: { advanceFind(by: -1) },
                    close: closeFind
                )
                .padding(.top, 12)
                .padding(.horizontal, 18)
            }
        }
    }


}


/// The transcript's top fade, measured down from the physical window top.
///
/// The curve and the origin are unchanged; only the reach moved, from 20pt to
/// 28pt, because 20pt released the last row too close to the chrome. 28pt is
/// the smallest increment a reader notices, and it is the same reach this
/// fade carried before the AppKit renderer replaced its first implementation.
private struct ChatPhysicalTopMask: View {
    /// The ramp's downward reach, in points.
    private static let reach: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.reach)
            Color.black
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
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


