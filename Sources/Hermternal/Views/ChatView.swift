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
    @State private var findMatchesAreTruncated = false
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
    /// Incremented by the Format menu command. The composer consumes it to
    /// summon the floating formatting toolbar at the caret.
    @State private var composerToolbarRequest = 0
    var body: some View {
        // Keep the composer off the transcript `.id(session:generation)`.
        // That identity changes on every route publication. If the composer
        // is a modifier of that view, SwiftUI can call onDisappear of the
        // old ComposerView after onAppear of the new one, on the same
        // ComposerModel, and the late unmount leaves the live composer dead.
        // Defended by outOfOrderUnmountDoesNotBlockSubmit.
        composerHost
        .onChange(of: model.findRequestGeneration) { _, _ in
            openFind()
        }
        .onChange(of: model.composerFocusRequestGeneration) { _, _ in
            guard !isReadOnly else { return }
            composerFocusRequest &+= 1
        }
        .onChange(of: model.formattingToolbarRequestGeneration) { _, _ in
            guard !isReadOnly else { return }
            composerToolbarRequest &+= 1
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

    /// Stable host for the composer. The transcript identity lives inside.
    ///
    /// Host ComposerView beside the transcript, not on the `.id` identity.
    /// Defended by outOfOrderUnmountDoesNotBlockSubmit.
    private var composerHost: some View {
        VStack(spacing: 0) {
            transcript
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isReadOnly {
                ComposerView(
                    model: model.composerModel,
                    focusRequest: composerFocusRequest,
                    summonRequest: composerToolbarRequest
                )
            }
        }
    }

    /// Identity for the displayed route, not for transcript contents.
    ///
    /// The route prefix is intentional: an archived session can have the same
    /// durable identifier as its live counterpart, but it is a different
    /// read-only transcript graph. New chat uses the live session id before a
    /// sidebar row exists, so adopt-live is not a switch. Streaming updates
    /// keep this value unchanged.
    private var transcriptIdentity: String {
        model.transcriptPaintIdentity
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
        findMatchesAreTruncated = false
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
            findMatchesAreTruncated = false
            activeFindIndex = 0
            return
        }
        guard let collection = try? await cursor.collect() else {
            findMatches = []
            findMatchesAreTruncated = false
            activeFindIndex = 0
            return
        }
        findMatches = collection.matches
        findMatchesAreTruncated = collection.isTruncated
        activeFindIndex = collection.matches.isEmpty ? 0 : min(activeFindIndex, collection.matches.count - 1)
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
        let publishedAt = model.transcriptPublishUptimeNanoseconds
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
            publishedTail: model.messages,
            paintIdentity: transcriptIdentity,
            onCopyCode: { code in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            },
            onPaint: { visibleAtNanoseconds in
                let published = publishedAt
                if published > 0, visibleAtNanoseconds >= published {
                    let deltaMs = Double(visibleAtNanoseconds &- published) / 1_000_000
                    Log.info(
                        "PERF|transcript publishToDraw|ms=\(String(format: "%.3f", deltaMs)) session=\(model.selectedSessionID ?? "") rows=\(model.messages.count) \(TranscriptPaintAttribution.line())"
                    )
                }
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
            // The representable is reused across chats. `paintIdentity`
            // tells the coordinator the selection changed. Recreating the
            // table on `.id(session)` was measured at 77-97 ms publish-to-draw.
            // Rows travel to the window's own top edge, so the CONTENT
            // dissolves before it reaches it. A `Material` behind the toolbar
            // controls could not do this: it is behind-window vibrancy and
            // cannot obscure an in-window sibling.
            //
            // The mask sits on the SCROLLING renderer, inside the overlays
            // below. Applied to the whole pane it would also fade the find
            // bar, which rests inside the ramp and is not scrolling content.
            .mask { ChatTranscriptTopEdgeMask() }
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
                    isTruncated: findMatchesAreTruncated,
                    focusRequest: model.findRequestGeneration,
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


/// The transcript's top edge, measured down from the physical window top.
///
/// The AppKit hosting boundary clears the titlebar safe area, so every
/// distance here is a depth below the physical window top, and the two things
/// that depend on them read the same numbers: the ramp this file draws, and
/// the scroll view's top content inset in `BlockTranscriptView`. Split across
/// two literals they would drift, and the drift is invisible until a row is
/// unreadable.
///
/// The ramp starts AT the window top, because this window has no titlebar
/// chrome for it to start under. `BlockTranscriptContainerView` turns the
/// system's own scroll edge effect off; it drew a material plate over the
/// whole titlebar band and dissolved content at that band's LOWER edge, which
/// is a strip of chrome over the transcript. A ramp that began there too left
/// the band with no ink at all, which reads as the same strip. One edge, on
/// the window's own top edge, is the whole design.
///
/// `chromeDepth` is the window's top safe-area inset, measured at 52pt on
/// macOS 26.6.2 while the window has toolbar items and 32pt when it has none;
/// the larger is the state with controls to protect. It is not a clear zone.
/// It is the depth the ramp must cross before content is readable, because
/// the New Chat and Reload group lives in that band: measured at true 2x on
/// the same build, the group is 70pt wide and 35.5pt tall, 8pt down the
/// window and 10pt in from its trailing edge, so its deepest ink is 43.5pt
/// down, and an outgoing bubble is trailing aligned, so it travels straight
/// under it. The ramp holds content to 0.55 alpha at that depth and reaches
/// full opacity only 32pt further down, so nothing arrives at a control's
/// glass edge at full strength. The sidebar's shipped ramp answers the
/// traffic lights the same way and accepts the same tradeoff: faint ink under
/// the chrome rather than an empty band beneath it.
///
/// One vertical gradient covers the full width, even though the group
/// occupies only its trailing 70pt. A mask that also varied along x would
/// fade one line of body text unevenly across its own length, which reads as
/// a smudge rather than as a dissolve, and it would put a second dimension
/// into the one place that has to stay cheap: the mask over the scrolling
/// viewport.
///
/// The SHAPE is the sidebar's shipped curve: seven ink stops tracking a
/// smoothstep, whose slope leaves zero and returns to zero, so no join in the
/// perceptible band changes slope by more than 1.33x. The seven alphas are a
/// smoothstep sampled at eighths, which is the same set of numbers the
/// sidebar carries, so both columns dissolve on one curve and differ only in
/// reach.
///
/// `reach` is where content is opaque again, and `contentInset` keeps a
/// resting row out of the ramp. The transcript's own frame keeps its full
/// height, so rows still travel under the chrome and dissolve on the way;
/// its scroll CONTENT stops short, so the first turn comes to rest at or
/// below `reach`, where no amount of scrolling can leave a readable row
/// inside the ramp.
enum ChatTranscriptTopEdge {
    /// The window's top safe-area inset: the band the system lays its
    /// titlebar and toolbar controls out in.
    static let chromeDepth: CGFloat = 52

    /// The depth at which content is fully opaque again.
    static let reach: CGFloat = chromeDepth + 32

    /// The transcript's top content inset.
    ///
    /// A turn row opens with an empty half-gap band before its first ink, so
    /// the row may start that much higher than `reach` and still rest with
    /// every glyph at full opacity.
    ///
    /// This is a FLOOR, not an exact landing. The resolved table style adds a
    /// document inset of its own above row 0 — 10pt, measured on the Mac — and
    /// AppKit owns that number, so the first ink rests at or below `reach` and
    /// never above it. The inset deliberately does not subtract it: an inset
    /// derived from a runtime table style would move whenever the style
    /// resolved differently, and it can only ever move the first row DOWN,
    /// away from the chrome.
    static let contentInset: CGFloat = reach - MessageTypography.turnGap / 2

    /// One continuous gradient. Stacked opacity bands would step and seam,
    /// and a second mask would be a second compositing group.
    ///
    /// Clear at the window's own top edge, opaque at `reach`, and with no flat
    /// stretch between them: a second zero-alpha stop is exactly what put an
    /// empty band back over the titlebar. The stops carry fractions rather
    /// than points because the curve is a smoothstep sampled at eighths, and
    /// eighths keep it a smoothstep if the reach ever moves.
    /// Defended by transcriptTopEdgeDissolvesFromTheWindowTop.
    static var ramp: Gradient {
        Gradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black.opacity(0.06), location: 1 / 8),
            .init(color: .black.opacity(0.18), location: 2 / 8),
            .init(color: .black.opacity(0.34), location: 3 / 8),
            .init(color: .black.opacity(0.52), location: 4 / 8),
            .init(color: .black.opacity(0.70), location: 5 / 8),
            .init(color: .black.opacity(0.85), location: 6 / 8),
            .init(color: .black.opacity(0.96), location: 7 / 8),
            .init(color: .black, location: 1)
        ])
    }
}

private struct ChatTranscriptTopEdgeMask: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                gradient: ChatTranscriptTopEdge.ramp,
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: ChatTranscriptTopEdge.reach)
            Color.black
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Rule 4 of the progressive edge: a mask that hit-tests would swallow
        // the scrolling, clicks and focus it sits over.
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


