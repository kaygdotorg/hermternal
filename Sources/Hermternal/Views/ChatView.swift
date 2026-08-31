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
        // Keep the composer off the transcript `.id(session:generation)`.
        // That identity changes on every route publication. If the composer
        // is a modifier of that view, SwiftUI can call onDisappear of the
        // old ComposerView after onAppear of the new one, on the same
        // ComposerModel, and the late unmount leaves the live composer dead.
        composerHost
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

    /// Stable host for the composer. The transcript identity lives inside.
    private var composerHost: some View {
        VStack(spacing: 0) {
            transcript
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isReadOnly {
                ComposerView(
                    model: model.composerModel,
                    focusRequest: composerFocusRequest
                )
            }
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
            // Rows travel under the window's own chrome, so the CONTENT
            // dissolves before it reaches the toolbar controls. A `Material`
            // behind those controls could not do this: it is behind-window
            // vibrancy and cannot obscure an in-window sibling.
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
/// `chromeDepth` is the window's top safe-area inset, measured at 52pt on
/// macOS 26.6.2 while the window has toolbar items. The New Chat and Reload
/// group lives inside that band: measured at true 2x on the same build, the
/// group is 70pt wide and 35.5pt tall, 8pt down the window and 10pt in from
/// its trailing edge, so its deepest ink is 43.5pt down. The clear zone
/// covers the WHOLE band rather than the 43.5pt the group occupies today,
/// because AppKit owns that group's height and style, and a system that lays
/// the item out taller must not be able to reintroduce this bug.
///
/// That 52pt is conditional, and the sidebar records the same probe: 52pt
/// while the window has toolbar items, 32pt when it has none. The clear zone
/// takes the larger of the two, because the state that has controls is the
/// only state with ink to protect, and a window with no toolbar items is a
/// signed-out window with no transcript to dissolve.
///
/// Nothing above `chromeDepth` receives ink. An outgoing bubble is trailing
/// aligned, so it travels directly under that group, and the group is opaque:
/// any ink left up there is ink the group cuts. The 28pt reach this replaces
/// released rows to FULL opacity 15.5pt above the group's bottom edge, and
/// the result was a rectangular bite — 71pt of a readable message ending at
/// the pill's edge with no fade at all.
///
/// One vertical gradient covers the full width, even though the group
/// occupies only its trailing 70pt. A mask that also varied along x would
/// fade one line of body text unevenly across its own length, which reads as
/// a smudge rather than as a dissolve, and it would put a second dimension
/// into the one place that has to stay cheap: the mask over the scrolling
/// viewport.
///
/// The SHAPE is the sidebar's shipped curve, and only the distances are this
/// pane's own: seven ink stops every 4pt tracking a smoothstep, whose slope
/// leaves zero and returns to zero, so no join in the perceptible band
/// changes slope by more than 1.33x. The ramp crosses 32pt, which is under
/// two body lines and over one turn gap: long enough that no single line
/// wipes from 0.06 to 0.96 within its own height, short enough that only one
/// turn is ever fading. It is also entirely in open air, below the chrome,
/// which is the same case the sidebar's bottom ramp answers.
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
    /// The ramp view is exactly `reach` tall, so a depth in points converts
    /// to a location on its own. Computed, as the sidebar's ramp is: the mask
    /// is rebuilt when the transcript's own body runs, not when it scrolls,
    /// because AppKit scrolls the rows inside it.
    static var ramp: Gradient {
        Gradient(stops: [
            .init(color: .clear, location: 0),
            // No ink in the chrome band. The seven stops below are spaced
            // every 4pt through the open air under it; the distances have one
            // consumer each, so they sit beside the opacity they carry rather
            // than becoming seven more names.
            .init(color: .clear, location: location(chromeDepth)),
            .init(color: .black.opacity(0.06), location: location(chromeDepth + 4)),
            .init(color: .black.opacity(0.18), location: location(chromeDepth + 8)),
            .init(color: .black.opacity(0.34), location: location(chromeDepth + 12)),
            .init(color: .black.opacity(0.52), location: location(chromeDepth + 16)),
            .init(color: .black.opacity(0.70), location: location(chromeDepth + 20)),
            .init(color: .black.opacity(0.85), location: location(chromeDepth + 24)),
            .init(color: .black.opacity(0.96), location: location(chromeDepth + 28)),
            .init(color: .black, location: 1)
        ])
    }

    private static func location(_ depth: CGFloat) -> CGFloat { depth / reach }
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


