import CryptoKit
import Foundation
import HermternalCore
import Observation
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import os.lock

/// Immutable identity captured by every asynchronous composer operation.
///
/// A session can retain its chat id while the mounted composer is replaced;
/// generation distinguishes those mounts and prevents a stale picker/send
/// from writing into the newly mounted route.
struct ComposerRouteToken: Equatable, Hashable, Sendable {
    let identity: String
    let generation: UInt64
}

/// The chat the composer writes to.
///
/// The composer owns no session state. The caller owns the chat and pushes
/// one value here, so every composer control reports gateway truth.
struct ComposerRoute: Equatable, Sendable {
    /// Stable identity of the open chat. Draft text, attachment files, and the
    /// model menu are all scoped to this value.
    let identity: String
    /// Distinguishes mounts of the same chat identity.
    let generation: UInt64
    /// The gateway session id. It is nil until the gateway creates the chat.
    let liveSessionID: String?
    let runtime: SessionRuntimeSnapshot
    let isAwaitingReply: Bool
    let isReadOnly: Bool

    var token: ComposerRouteToken {
        ComposerRouteToken(identity: identity, generation: generation)
    }

    init(
        identity: String,
        generation: UInt64 = 0,
        liveSessionID: String? = nil,
        runtime: SessionRuntimeSnapshot = SessionRuntimeSnapshot(
            model: nil,
            provider: nil,
            reasoning: nil,
            isRunning: false
        ),
        isAwaitingReply: Bool = false,
        isReadOnly: Bool = false
    ) {
        self.identity = identity
        self.generation = generation
        self.liveSessionID = liveSessionID
        self.runtime = runtime
        self.isAwaitingReply = isAwaitingReply
        self.isReadOnly = isReadOnly
    }
}

/// The prompt transport seam for one composer turn.
///
/// HermternalCore owns the model, attachment, speech, and audio interfaces.
/// It owns no prompt transport, so the app layer supplies this one interface.
@MainActor
protocol ComposerTurnRouting: AnyObject {
    /// Returns the gateway session id of the expected chat, and creates the
    /// chat when it does not exist yet. Implementations must reject a stale
    /// route rather than silently retargeting the request.
    func prepareSession(expectedRoute: ComposerRouteToken) async throws -> String
    /// Submits one prompt, including any gateway file references.
    func submit(text: String, sessionID: String) async throws
    /// Interrupts the running turn.
    func stop() async
}

/// One user selection that can become an attachment.
enum ComposerAttachmentSource: Sendable {
    /// A file picker result. Access is security scoped, so the file is copied.
    case picked(URL)
    /// An application-owned temporary file, such as a photo import. It is
    /// descriptor-validated and copied, then removed after success.
    case temporary(URL)

    var url: URL {
        switch self {
        case let .picked(url), let .temporary(url): return url
        }
    }
}

/// A short message about one refused or failed composer action.
struct ComposerNotice: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String

    init(_ message: String) { self.message = message }
}

/// Cumulative file bytes read for the attachment that is staging now.
struct ComposerStagingProgress: Equatable, Sendable {
    let id: UUID
    var bytesSent: Int
    let bytesTotal: Int
}

/// Load state of one gateway backed menu.
enum ComposerLoadState<Value: Equatable & Sendable>: Equatable, Sendable {
    case notLoaded
    case loading
    case loaded(Value)
    case failed(String)
}

enum ComposerDictationStatus: Equatable, Sendable {
    case idle
    case preparing
    case installingModel(locale: String)
    case listening
    case unavailable(reason: String)
}

enum ComposerRecordingStatus: Equatable, Sendable {
    case idle
    case requestingPermission
    case recording
    case finishing
    case unavailable(reason: String)
}

/// The model value shown by the model menu, including a requested value that
/// the gateway has accepted but not yet reported back.
struct ComposerModelSelection: Equatable, Sendable {
    let current: String?
    let provider: String?
    let pending: String?
    let pendingProvider: String?
    let isDeferredToNextTurn: Bool

    init(
        current: String?,
        provider: String?,
        pending: String?,
        pendingProvider: String? = nil,
        isDeferredToNextTurn: Bool
    ) {
        self.current = current
        self.provider = provider
        self.pending = pending
        self.pendingProvider = pendingProvider
        self.isDeferredToNextTurn = isDeferredToNextTurn
    }

    var displayName: String? { pending ?? current }
}

/// The reasoning values the current model accepts.
struct ComposerReasoningOptions: Equatable, Sendable {
    let current: ReasoningSetting?
    let pending: ReasoningSetting?
    let choices: [ReasoningSetting]
    /// Non-nil when reasoning cannot change, with the gateway reported reason.
    let unavailableReason: String?

    var displayValue: ReasoningSetting? { pending ?? current }
}

private enum ComposerOperationError: Error, Sendable {
    case staleRoute
    case invalidReference
    case invalidTransaction
    case uncertainTransaction
}

private enum ComposerFileAdmissionError: Error, Sendable {
    case notRegular
    case package
    case unreadable
    case tooLarge
    case copyFailed
    case cancelled

    var userMessage: String {
        switch self {
        case .tooLarge: return "The attachment exceeds the composer size limit."
        case .notRegular, .package, .unreadable:
            return "Only readable regular files can be attached."
        case .copyFailed: return "The attachment could not be copied safely."
        case .cancelled: return "The attachment import was cancelled."
        }
    }

    var logCode: String {
        switch self {
        case .notRegular: return "not_regular"
        case .package: return "package"
        case .unreadable: return "unreadable"
        case .tooLarge: return "too_large"
        case .copyFailed: return "copy_failed"
        case .cancelled: return "cancelled"
        }
    }
}

/// Main-actor state and behaviour of the message composer.
///
/// The composer holds one draft per chat, copies every attachment to disk
/// before it enters a draft, and holds no attachment bytes. Model and
/// reasoning values come from the gateway snapshot of the open chat only.
/// Dictation and audio recording share the microphone, so the state machine
/// allows one of them at a time.
@MainActor
@Observable
final class ComposerModel {
    /// The number of chats that keep an unsent draft in memory. Older drafts
    /// are dropped with their attachment copies, so disk use stays bounded.
    private static let retainedDraftCount = 12

    @ObservationIgnored private let runtime: any SessionRuntimeControlling
    @ObservationIgnored private let attachmentStaging: any AttachmentStaging
    @ObservationIgnored private let dictation: (any SpeechDictating)?
    @ObservationIgnored private let recorder: (any AudioRecording)?
    @ObservationIgnored private let files: ComposerDraftFiles
    @ObservationIgnored private weak var turn: (any ComposerTurnRouting)?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var dictationTask: Task<Void, Never>?
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    @ObservationIgnored private var recordingTicker: Task<Void, Never>?
    @ObservationIgnored private var inventoryTask: Task<Void, Never>?
    @ObservationIgnored private var runtimeTask: Task<Void, Never>?
    @ObservationIgnored private var startupSweepTask: Task<Void, Never>?
    @ObservationIgnored private var isUnmounted = false
    @ObservationIgnored private var drafts: [String: ComposerDraft] = [:]
    @ObservationIgnored private var draftOrder: [String] = []
    @ObservationIgnored private var outgoingByRoute: [ComposerRouteToken: [ComposerAttachment]] = [:]
    @ObservationIgnored private var progressByRoute: [ComposerRouteToken: ComposerStagingProgress] = [:]
    @ObservationIgnored private var submittingRoutes: Set<ComposerRouteToken> = []
    private(set) var route: ComposerRoute
    private var draft = ComposerDraft()
    private(set) var editorMode: ComposerEditorMode = .wysiwyg
    private(set) var editorError: MarkdownParseError?
    /// Attachments that left the active draft with a send and are still going
    /// out. Backing state is route keyed so another chat never displays them.
    private(set) var outgoing: [ComposerAttachment] = []
    private(set) var density: ComposerControlDensity = .full
    private(set) var inventory: ComposerLoadState<ModelInventory> = .notLoaded
    private(set) var stagingProgress: ComposerStagingProgress?
    private(set) var isSubmitting = false
    private(set) var dictationStatus: ComposerDictationStatus = .idle
    private(set) var recordingStatus: ComposerRecordingStatus = .idle
    private(set) var recordingElapsed: Duration = .zero
    private(set) var notice: ComposerNotice?
    private var pendingModel: String?
    private var pendingModelProvider: String?
    private var pendingModelIsDeferred = false
    private var pendingReasoning: ReasoningSetting?

    init(
        route: ComposerRoute,
        runtime: any SessionRuntimeControlling,
        attachmentStaging: any AttachmentStaging,
        turn: (any ComposerTurnRouting)?,
        dictation: (any SpeechDictating)? = nil,
        recorder: (any AudioRecording)? = nil,
        files: ComposerDraftFiles = ComposerDraftFiles()
    ) {
        self.route = route
        self.runtime = runtime
        self.attachmentStaging = attachmentStaging
        self.turn = turn
        self.dictation = dictation
        self.recorder = recorder
        self.files = files
        if dictation == nil {
            dictationStatus = .unavailable(reason: "Dictation is not available in this build.")
        }
        if recorder == nil {
            recordingStatus = .unavailable(reason: "Audio recording is not available in this build.")
        }
        startupSweepTask = Task { [weak self] in
            guard let self else { return }
            let succeeded = await files.sweepNonPersistedDrafts()
            guard !succeeded else { return }
            self.notice = ComposerNotice("Some temporary composer files could not be cleaned up.")
            Log.error("composer.lifecycle code=startup_sweep_failed")
        }
    }

    // MARK: - Draft
    /// The exact Markdown source. The model never normalizes editor input.
    var text: String {
        get { draft.text }
        set { updateEditorSource(newValue) }
    }

    /// Updates source while retaining the current editing representation.
    func updateEditorSource(_ source: String) {
        draft.text = source
        editorError = editorMode == .source ? MarkdownDocument.parse(source).error : nil
    }

    /// Changes between WYSIWYG and exact Source representations.
    @discardableResult
    func setEditorMode(_ requested: ComposerEditorMode) -> Bool {
        guard requested != editorMode else {
            return editorError == nil
        }
        if requested == .wysiwyg {
            let parsed = MarkdownDocument.parse(draft.text)
            guard parsed.error == nil else {
                editorError = parsed.error
                return false
            }
        }
        editorMode = requested
        editorError = requested == .source
            ? MarkdownDocument.parse(draft.text).error
            : nil
        return editorError == nil
    }

    /// Applies a native Format menu operation to a source selection.
    @discardableResult
    func applyEditorFormat(
        _ format: ComposerEditorFormat,
        selectedRange: Range<Int>
    ) -> Range<Int> {
        let edit = ComposerEditorFormatter.apply(
            format,
            source: draft.text,
            selectedRange: selectedRange
        )
        updateEditorSource(edit.source)
        return edit.selectedRange
    }

    var attachments: [ComposerAttachment] { draft.attachments }

    var attachmentSlotsLeft: Int {
        max(0, ComposerAttachmentLimits.maximumItems - draft.attachments.count)
    }

    // MARK: - Route

    /// Applies the current chat. A new chat identity swaps the draft, so text
    func update(route newRoute: ComposerRoute) {
        if newRoute.token != route.token {
            cancelDictation()
            cancelRecording()
        }
        if newRoute.identity != route.identity {
            store(draft, for: route.identity)
            draft = takeDraft(for: newRoute.identity)
            editorMode = .wysiwyg
            editorError = nil
            inventory = .notLoaded
            pendingModel = nil
            pendingModelProvider = nil
            pendingModelIsDeferred = false
            pendingReasoning = nil
            notice = nil
        }
        route = newRoute
        outgoing = outgoingByRoute[newRoute.token] ?? []
        stagingProgress = progressByRoute[newRoute.token]
        isSubmitting = submittingRoutes.contains(newRoute.token)
        // The gateway is the authority. A reported value retires the request
        // only when the provider+model pair is the same identity.
        if let pendingModel,
           newRoute.runtime.model == pendingModel,
           newRoute.runtime.provider == pendingModelProvider {
            self.pendingModel = nil
            pendingModelProvider = nil
            pendingModelIsDeferred = false
        }
        if let pendingReasoning, newRoute.runtime.reasoning == pendingReasoning {
            self.pendingReasoning = nil
        }
    }

    /// Recomputes the control density for the measured composer width.
    ///
    /// `ComposerControlLayout` carries the hysteresis, so a window drag over
    /// a breakpoint changes the band one time. The assignment happens only on
    /// a real band change, so a width report that keeps the band invalidates
    /// no view and costs one comparison.
    func updateWidth(_ availableWidth: Double) {
        guard !isUnmounted else { return }
        let next = ComposerControlLayout.density(
            availableWidth: availableWidth,
            previous: density
        )
        if next != density { density = next }
    }

    /// Records a picker failure without exposing framework paths or NSError
    /// text to either the user or the log.
    func reportSelectionFailure(target: ComposerRouteToken? = nil) {
        if let target, target != route.token { return }
        Log.error("composer.selection code=picker_failed")
        notice = ComposerNotice("The selected item could not be attached.")
    }

    func dismissNotice() {
        notice = nil
    }

    // MARK: - Status

    var activity: ComposerActivity {
        if recordingStatus == .recording { return .recording(elapsed: recordingElapsed) }
        if dictationStatus == .listening { return .dictating }
        if let stagingProgress {
            return .staging(
                itemID: stagingProgress.id,
                bytesSent: stagingProgress.bytesSent,
                bytesTotal: stagingProgress.bytesTotal
            )
        }
        if isSubmitting { return .submitting }
        if route.isAwaitingReply { return .streaming }
        return .idle
    }

    /// One line that names work in flight. It is nil when nothing is running,
    /// so no indicator can claim progress that does not exist.
    var statusDescription: String? {
        switch activity {
        case .idle:
            return nil
        case let .recording(elapsed):
            return "Recording \(elapsed.formatted(.time(pattern: .minuteSecond)))"
        case .dictating:
            return "Listening"
        case let .staging(itemID, bytesSent, bytesTotal):
            let name = (outgoing + draft.attachments)
                .first { $0.id == itemID }?.displayName ?? "attachment"
            let sent = bytesSent.composerByteSize
            let total = bytesTotal.composerByteSize
            return "Sending \(name), \(sent) of \(total)"
        case .submitting:
            return "Sending"
        case .streaming:
            return nil
        }
    }

    var primaryAction: ComposerPrimaryAction {
        if route.isAwaitingReply { return .stop }
        return .send(isEnabled: sendRejection == nil && !isSubmitting)
    }

    /// The reason the send control is off, in the words of the send policy.
    var sendDisabledReason: String? {
        if isSubmitting { return "The last message is still going out." }
        guard let rejection = sendRejection else { return nil }
        switch rejection {
        case .emptyDraft:
            return "Type a message or attach a file."
        case .awaitingReply:
            return "Hermes is still replying."
        case .readOnlyTranscript:
            return "This transcript is read only."
        case let .oversizeAttachment(id, limit):
            let name = draft.attachments.first { $0.id == id }?.displayName ?? "An attachment"
            return "\(name) is above the \(limit.composerByteSize) limit."
        case let .tooManyAttachments(limit):
            return "The composer accepts at most \(limit) attachments."
        case .invalidRoute:
            return "The attachments belong to another chat."
        }
    }

    private var sendRejection: ComposerSendRejection? {
        let decision = ComposerSendPolicy.decide(
            draft: draft,
            isAwaitingReply: route.isAwaitingReply,
            isReadOnlyTranscript: route.isReadOnly
        )
        if case let .rejected(reason) = decision { return reason }
        return nil
    }

    var canAttach: Bool { !route.isReadOnly && attachmentSlotsLeft > 0 }

    var canDictate: Bool {
        guard dictation != nil, !route.isReadOnly else { return false }
        if case .unavailable = dictationStatus { return false }
        return recordingStatus == .idle || dictationStatus == .listening
    }

    var canRecord: Bool {
        guard recorder != nil, !route.isReadOnly, attachmentSlotsLeft > 0 else { return false }
        if case .unavailable = recordingStatus { return false }
        return dictationStatus == .idle || recordingStatus == .recording
    }

    func submit() {
        guard !isUnmounted, sendTask == nil else { return }
        let decision = ComposerSendPolicy.decide(
            draft: draft,
            isAwaitingReply: route.isAwaitingReply,
            isReadOnlyTranscript: route.isReadOnly
        )
        guard case let .send(submission) = decision else {
            if case let .rejected(rejection) = decision { report(rejection) }
            return
        }
        guard let turn else {
            notice = ComposerNotice("The composer is not connected to a chat.")
            return
        }

        // Capture the complete route before the first suspension point.
        let submitted = draft
        let target = route.token
        draft = ComposerDraft()
        outgoingByRoute[target] = submitted.attachments
        outgoing = submitted.attachments
        notice = nil
        submittingRoutes.insert(target)
        isSubmitting = true
        sendTask = Task { [weak self] in
            await self?.performSend(
                submission,
                submitted: submitted,
                target: target,
                turn: turn
            )
        }
    }

    func stop() {
        guard let turn else { return }
        Task { await turn.stop() }
    }

    /// Shows a refused send only when the composer does not show the reason
    /// already. An empty draft and a running reply are both visible states.
    private func report(_ rejection: ComposerSendRejection) {
        switch rejection {
        case .emptyDraft, .awaitingReply:
            return
        case .readOnlyTranscript, .oversizeAttachment, .tooManyAttachments, .invalidRoute:
            if let reason = sendDisabledReason { notice = ComposerNotice(reason) }
        }
    }

    private func performSend(
        _ submission: ComposerSubmission,
        submitted: ComposerDraft,
        target: ComposerRouteToken,
        turn: any ComposerTurnRouting
    ) async {
        var transaction: (any AttachmentStagingTransaction)?
        defer {
            submittingRoutes.remove(target)
            progressByRoute.removeValue(forKey: target)
            outgoingByRoute.removeValue(forKey: target)
            if route.token == target {
                isSubmitting = false
                stagingProgress = nil
                outgoing = []
            }
            sendTask = nil
        }
        do {
            let sessionID = try await turn.prepareSession(expectedRoute: target)
            guard !isUnmounted, route.token == target else { throw ComposerOperationError.staleRoute }
            try Task.checkCancellation()
            guard !submission.staging.isEmpty else {
                guard route.token == target else { throw ComposerOperationError.staleRoute }
                let text = ComposerSendPolicy.submissionText(
                    trimmed: submission.text,
                    fileReferences: []
                )
                try await turn.submit(text: text, sessionID: sessionID)
                guard route.token == target else { throw ComposerOperationError.staleRoute }
                return
            }

            let stagedTransaction = try await attachmentStaging.stageBatch(
                submission.staging,
                sessionID: sessionID,
                routeIdentity: target.identity,
                progress: { [weak self] id, bytes in
                    let total = submission.staging.first { $0.attachment.id == id }?.attachment.byteCount ?? 0
                    Task { @MainActor in
                        self?.advanceStaging(
                            id: id,
                            bytesSent: bytes,
                            total: total,
                            target: target
                        )
                    }
                }
            )
            transaction = stagedTransaction
            guard route.token == target else { throw ComposerOperationError.staleRoute }
            let receipt = await stagedTransaction.snapshot()
            guard receipt.sessionID == sessionID, receipt.routeIdentity == target.identity else {
                throw ComposerOperationError.invalidTransaction
            }

            var references: [String] = []
            references.reserveCapacity(submission.staging.count)
            for step in submission.staging {
                guard let item = receipt.items.first(where: { $0.id == step.attachment.id }) else {
                    throw ComposerOperationError.invalidTransaction
                }
                guard item.sessionID == sessionID,
                      item.routeIdentity == target.identity else {
                    throw ComposerOperationError.invalidTransaction
                }
                switch item.outcome {
                case .staged, .committed:
                    if let reference = item.serverReference {
                        guard Self.isSafeReference(reference) else {
                            throw ComposerOperationError.invalidReference
                        }
                        references.append(reference)
                    }
                case .rolledBack:
                    throw ComposerOperationError.invalidTransaction
                case .outcomeUnknown:
                    throw ComposerOperationError.uncertainTransaction
                }
            }
            progressByRoute.removeValue(forKey: target)
            if route.token == target { stagingProgress = nil }
            let text = ComposerSendPolicy.submissionText(
                trimmed: submission.text,
                fileReferences: references
            )
            guard !isUnmounted, route.token == target else { throw ComposerOperationError.staleRoute }
            try await turn.submit(text: text, sessionID: sessionID)
            guard !isUnmounted, route.token == target else { throw ComposerOperationError.staleRoute }
            let committed = try await stagedTransaction.commit()
            guard committed.state == .committed else {
                throw ComposerOperationError.uncertainTransaction
            }
            transaction = nil
            files.discard(submitted.attachments)
        } catch is CancellationError {
            await compensate(transaction)
            restore(submitted, routeIdentity: target.identity, notice: nil)
        } catch ComposerOperationError.staleRoute {
            await compensate(transaction)
            restore(submitted, routeIdentity: target.identity, notice: nil)
        } catch ComposerOperationError.uncertainTransaction {
            await compensate(transaction)
            Log.error("composer.send code=outcome_unknown")
            restore(
                submitted,
                routeIdentity: target.identity,
                notice: ComposerNotice("The message outcome could not be confirmed; it was not retried.")
            )
        } catch ComposerOperationError.invalidReference {
            await compensate(transaction)
            Log.error("composer.send code=invalid_reference")
            restore(
                submitted,
                routeIdentity: target.identity,
                notice: ComposerNotice("The message could not be sent because an attachment reference was invalid.")
            )
        } catch let error as AttachmentStagingBatchFailure {
            switch error.reason {
            case .outcomeUnknown, .residual:
                Log.error("composer.send code=staging_uncertain")
                restore(
                    submitted,
                    routeIdentity: target.identity,
                    notice: ComposerNotice("The message outcome could not be confirmed; it was not retried.")
                )
            case .rejected:
                Log.error("composer.send code=staging_rejected")
                restore(
                    submitted,
                    routeIdentity: target.identity,
                    notice: ComposerNotice("The attachment could not be sent.")
                )
            }
        } catch {
            await compensate(transaction)
            Log.error("composer.send code=failed")
            restore(
                submitted,
                routeIdentity: target.identity,
                notice: ComposerNotice("The message could not be sent.")
            )
        }
    }

    private func compensate(_ transaction: (any AttachmentStagingTransaction)?) async {
        guard let transaction else { return }
        switch await transaction.rollback() {
        case .complete:
            return
        case .residual:
            Log.error("composer.send code=rollback_residual")
            if route.token == ComposerRouteToken(
                identity: transaction.routeIdentity,
                generation: route.generation
            ) {
                notice = ComposerNotice("The message could not be sent safely; try again later.")
            }
        }
    }

    private static func isSafeReference(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_096 else { return false }
        return trimmed.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private func advanceStaging(
        id: UUID,
        bytesSent: Int,
        total: Int,
        target: ComposerRouteToken
    ) {
        guard !isUnmounted, target == route.token else { return }
        var progress = progressByRoute[target]
        if progress?.id != id {
            progress = ComposerStagingProgress(id: id, bytesSent: 0, bytesTotal: total)
        }
        let totalFallback = progress?.bytesTotal ?? total
        let boundedBytes = min(bytesSent, totalFallback)
        guard var progress else { return }
        progress.bytesSent = boundedBytes
        progressByRoute[target] = progress
        stagingProgress = progress
    }

    /// Puts a failed submission back in the chat that produced it, before any
    /// newer edit that the user made while the send was in flight.
    private func restore(
        _ submitted: ComposerDraft,
        routeIdentity: String,
        notice failure: ComposerNotice?
    ) {
        mutateDraft(for: routeIdentity) { current in
            current = ComposerSendPolicy.restore(submitted, into: current)
        }
        if routeIdentity == route.identity, let failure { notice = failure }
    }

    // MARK: - Attachments

    /// Copies each selection into the chat draft directory, then adds it to
    /// the draft. No selection is read into memory.
    /// Adopts selections for the route captured before the picker opened.
    /// Imports never retarget to whatever route happens to be mounted after
    /// their asynchronous file operation completes.
    func attach(_ sources: [ComposerAttachmentSource], target: ComposerRouteToken) {
        guard !sources.isEmpty else { return }
        guard !isUnmounted else {
            discard(sources)
            return
        }
        let capacity = attachmentSlotsLeft
        guard capacity > 0 else {
            notice = ComposerNotice(
                "The composer accepts at most \(ComposerAttachmentLimits.maximumItems) attachments."
            )
            discard(sources)
            return
        }
        let accepted = Array(sources.prefix(capacity))
        if accepted.count < sources.count {
            notice = ComposerNotice(
                "Only \(accepted.count) of \(sources.count) files fit. The composer accepts "
                    + "at most \(ComposerAttachmentLimits.maximumItems) attachments."
            )
            discard(Array(sources.dropFirst(capacity)))
        }
        // Imports run one after another, so two pickers cannot pass the limit.
        // Cancel the old chain: unmount cancellation must stop every import.
        importTask?.cancel()
        let previous = importTask
        importTask = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            await self.ingest(accepted, target: target)
        }
    }

    func removeAttachment(_ id: UUID) {
        guard let index = draft.attachments.firstIndex(where: { $0.id == id }) else { return }
        let removed = draft.attachments.remove(at: index)
        files.discard([removed])
    }

    private func ingest(_ sources: [ComposerAttachmentSource], target: ComposerRouteToken) async {
        for source in sources {
            guard !isUnmounted, route.token == target else {
                discard([source])
                continue
            }
            let existing = draft.attachments
            guard existing.count < ComposerAttachmentLimits.maximumItems else {
                discard([source])
                notice = ComposerNotice(
                    "The composer accepts at most \(ComposerAttachmentLimits.maximumItems) attachments."
                )
                continue
            }
            let used = existing.reduce(into: 0) { $0 += $1.byteCount }
            let remaining = ComposerAttachmentLimits.totalBytes > used
                ? ComposerAttachmentLimits.totalBytes - used
                : 0
            let itemLimit = ComposerDraftFiles.limit(for: source.url)
            let maximumBytes = min(itemLimit, remaining)
            guard maximumBytes > 0 else {
                discard([source])
                notice = ComposerNotice("The attachment exceeds the composer size limit.")
                continue
            }
            do {
                let attachment = try await files.adopt(
                    source,
                    target: target,
                    maximumBytes: maximumBytes
                )
                guard !isUnmounted, route.token == target else {
                    files.discard([attachment])
                    continue
                }
                mutateDraft(for: target.identity) { $0.attachments.append(attachment) }
            } catch let error as ComposerFileAdmissionError {
                Log.error("composer.attachment code=\(error.logCode)")
                discard([source])
                notice = ComposerNotice(error.userMessage)
            } catch {
                Log.error("composer.attachment code=adopt_failed")
                discard([source])
                notice = ComposerNotice("The attachment could not be added.")
            }
        }
    }

    /// Returns the reason an attachment cannot join the draft, or nil.
    private func refusal(for attachment: ComposerAttachment, routeIdentity: String) -> String? {
        let existing = draftValue(for: routeIdentity).attachments
        guard existing.count < ComposerAttachmentLimits.maximumItems else {
            return "The composer accepts at most \(ComposerAttachmentLimits.maximumItems) attachments."
        }
        let ceiling = ComposerAttachmentLimits.ceiling(for: attachment.kind)
        guard attachment.byteCount <= ceiling else {
            return "\(attachment.displayName) is \(attachment.byteCount.composerByteSize)"
                + ", above the \(ceiling.composerByteSize) limit."
        }
        let total = existing.reduce(attachment.byteCount) { $0 + $1.byteCount }
        guard total <= ComposerAttachmentLimits.totalBytes else {
            let limit = ComposerAttachmentLimits.totalBytes.composerByteSize
            return "\(attachment.displayName) puts the attachments above the \(limit) total limit."
        }
        return nil
    }

    private func discard(_ sources: [ComposerAttachmentSource]) {
        let temporary = sources.compactMap { source -> URL? in
            guard case let .temporary(url) = source else { return nil }
            return url
        }
        files.discardFiles(temporary)
    }

    // MARK: - Model and reasoning menus

    var modelSelection: ComposerModelSelection {
        ComposerModelSelection(
            current: route.runtime.model,
            provider: route.runtime.provider,
            pending: pendingModel,
            pendingProvider: pendingModelProvider,
            isDeferredToNextTurn: pendingModelIsDeferred
        )
    }

    var canChangeRuntime: Bool {
        route.liveSessionID != nil && !route.isReadOnly && runtimeTask == nil
    }

    /// The reason the model and reasoning menus cannot change a value.
    var runtimeDisabledReason: String? {
        if route.isReadOnly { return "This transcript is read only." }
        if route.liveSessionID == nil { return "The model can change after the chat starts." }
        if runtimeTask != nil { return "The last change is still going out." }
        return nil
    }

    var reasoningOptions: ComposerReasoningOptions {
        let capabilities = currentModelCapabilities()
        if let capabilities, !capabilities.supportsReasoning {
            let name = route.runtime.model ?? "This model"
            return ComposerReasoningOptions(
                current: route.runtime.reasoning,
                pending: pendingReasoning,
                choices: [],
                unavailableReason: "\(name) does not support reasoning."
            )
        }
        var choices: [ReasoningSetting] = ReasoningEffort.allCases.map { .effort($0) }
        // The gateway reports whether a model can turn reasoning off. When it
        // does not report the flag, the choice stays, and the gateway rejects
        // it if the model needs reasoning.
        if capabilities?.canDisableReasoning != false { choices.insert(.off, at: 0) }
        return ComposerReasoningOptions(
            current: route.runtime.reasoning,
            pending: pendingReasoning,
            choices: choices,
            unavailableReason: nil
        )
    }

    /// Loads the model list of the open chat. The menu calls this when it
    /// opens, so a chat that never opens the menu makes no gateway call.
    func loadModels(refresh: Bool = false) {
        if !refresh, inventory != .notLoaded { return }
        guard !isUnmounted, inventoryTask == nil else { return }
        let sessionID = route.liveSessionID
        let routeToken = route.token
        inventory = .loading
        inventoryTask = Task { [weak self] in
            defer { self?.inventoryTask = nil }
            do {
                let result = try await self?.runtime.modelInventory(
                    sessionID: sessionID,
                    refresh: refresh
                )
                guard let self, self.route.token == routeToken, let result else { return }
                self.inventory = .loaded(result)
            } catch {
                guard let self, self.route.token == routeToken else { return }
                Log.error("composer.models code=load_failed")
                self.inventory = .failed("Models could not be loaded.")
            }
        }
    }

    func selectModel(_ name: String, provider: String?) {
        guard let sessionID = route.liveSessionID, canChangeRuntime else { return }
        pendingModel = name
        pendingModelProvider = provider
        pendingModelIsDeferred = false
        let routeToken = route.token
        runtimeTask = Task { [weak self] in
            defer { self?.runtimeTask = nil }
            do {
                let outcome = try await self?.runtime.setModel(
                    name,
                    provider: provider,
                    sessionID: sessionID
                )
                guard let self, self.route.token == routeToken, let outcome else { return }
                self.pendingModel = outcome.appliedValue
                self.pendingModelProvider = provider
                self.pendingModelIsDeferred = outcome.isDeferredToNextTurn
            } catch {
                guard let self, self.route.token == routeToken else { return }
                Log.error("composer.model code=change_failed")
                self.pendingModel = nil
                self.pendingModelProvider = nil
                self.pendingModelIsDeferred = false
                self.notice = ComposerNotice("The model could not be changed.")
            }
        }
    }

    func selectReasoning(_ setting: ReasoningSetting) {
        guard let sessionID = route.liveSessionID, canChangeRuntime else { return }
        pendingReasoning = setting
        let routeToken = route.token
        runtimeTask = Task { [weak self] in
            defer { self?.runtimeTask = nil }
            do {
                try await self?.runtime.setReasoning(setting, sessionID: sessionID)
            } catch {
                guard let self, self.route.token == routeToken else { return }
                Log.error("composer.reasoning code=change_failed")
                self.pendingReasoning = nil
                self.notice = ComposerNotice("Reasoning could not be changed.")
            }
        }
    }


    private func currentModelCapabilities() -> ModelCapabilities? {
        guard case let .loaded(inventory) = inventory, let model = route.runtime.model else {
            return nil
        }
        let provider = inventory.providers.first { $0.slug == route.runtime.provider }
            ?? inventory.providers.first { $0.isCurrent }
        return provider?.capabilities[model]
    }

    // MARK: - Dictation

    func toggleDictation() {
        if dictationStatus == .listening {
            guard let dictation else { return }
            Task { await dictation.stop() }
            return
        }
        guard canDictate, dictationTask == nil, let dictation else { return }
        let target = route.token
        dictationTask = Task { [weak self] in
            await self?.runDictation(dictation, target: target)
        }
    }

    private func runDictation(_ dictation: any SpeechDictating, target: ComposerRouteToken) async {
        defer {
            dictationTask = nil
            if dictationStatus == .listening || dictationStatus == .preparing {
                dictationStatus = .idle
            }
        }
        dictationStatus = .preparing
        switch await dictation.availability() {
        case .available:
            break
        case let .needsModelInstall(locale):
            dictationStatus = .installingModel(locale: locale)
        case .unsupportedLocale:
            dictationStatus = .unavailable(reason: "Dictation is unavailable for this language.")
            return
        case .permissionDenied:
            dictationStatus = .unavailable(reason: "Dictation needs microphone access in System Settings.")
            return
        case .unavailable:
            dictationStatus = .unavailable(reason: "Dictation is unavailable right now.")
            return
        }
        do {
            try await dictation.prepare()
            guard route.token == target, !Task.isCancelled else { return }
            var assembler = DictationAssembler(base: draft.text, insertionOffset: draft.text.count)
            let updates = try await dictation.start()
            dictationStatus = .listening
            for try await update in updates {
                guard route.token == target, !Task.isCancelled else { return }
                draft.text = assembler.apply(update)
            }
            if route.token == target { draft.text = assembler.finish() }
        } catch is CancellationError {
            return
        } catch {
            guard route.token == target else { return }
            Log.error("composer.dictation code=failed")
            dictationStatus = .unavailable(reason: "Dictation could not start.")
        }
    }

    private func cancelDictation() {
        guard let dictation, dictationTask != nil else { return }
        dictationTask?.cancel()
        dictationTask = nil
        if dictationStatus == .listening || dictationStatus == .preparing {
            dictationStatus = .idle
        }
        Task { await dictation.cancel() }
    }

    // MARK: - Audio recording

    func toggleRecording() {
        switch recordingStatus {
        case .recording:
            guard let recorder, recordingTask == nil else { return }
            let target = route.token
            recordingTask = Task { [weak self] in
                await self?.finishRecording(recorder, target: target)
            }
        case .idle:
            guard canRecord, recordingTask == nil, let recorder else { return }
            let target = route.token
            recordingTask = Task { [weak self] in
                await self?.beginRecording(recorder, target: target)
            }
        case .requestingPermission, .finishing, .unavailable:
            return
        }
    }

    private func beginRecording(_ recorder: any AudioRecording, target: ComposerRouteToken) async {
        defer { recordingTask = nil }
        recordingStatus = .requestingPermission
        guard await recorder.requestPermission() else {
            recordingStatus = .unavailable(reason: "Recording needs microphone access in System Settings.")
            return
        }
        do {
            let directory = try await files.directory(for: target.identity)
            try await recorder.start(into: directory)
        } catch {
            Log.error("composer.recording code=start_failed")
            recordingStatus = .idle
            notice = ComposerNotice("Recording could not start.")
            return
        }
        guard route.token == target, !Task.isCancelled else {
            await recorder.cancel()
            recordingStatus = .idle
            return
        }
        recordingElapsed = .zero
        recordingStatus = .recording
        startRecordingTicker(target: target)
    }

    private func finishRecording(_ recorder: any AudioRecording, target: ComposerRouteToken) async {
        defer { recordingTask = nil }
        recordingTicker?.cancel()
        recordingTicker = nil
        recordingStatus = .finishing
        do {
            let result = try await recorder.stop()
            let attachment = ComposerAttachment(
                kind: .audioRecording,
                displayName: result.fileURL.lastPathComponent,
                byteCount: result.byteCount,
                fileURL: result.fileURL,
                duration: result.duration,
                routeIdentity: target.identity
            )
            guard route.token == target, !Task.isCancelled else {
                files.discard([attachment])
                recordingStatus = .idle
                recordingElapsed = .zero
                return
            }
            recordingStatus = .idle
            recordingElapsed = .zero
            if let reason = refusal(for: attachment, routeIdentity: target.identity) {
                files.discard([attachment])
                notice = ComposerNotice(reason)
                return
            }
            mutateDraft(for: target.identity) { $0.attachments.append(attachment) }
        } catch {
            Log.error("composer.recording code=finish_failed")
            recordingStatus = .idle
            recordingElapsed = .zero
            notice = ComposerNotice("The recording could not be saved.")
        }
    }

    private func startRecordingTicker(target: ComposerRouteToken) {
        recordingTicker?.cancel()
        let start = ContinuousClock.now
        recordingTicker = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.recordingStatus == .recording,
                      self.route.token == target, !Task.isCancelled else { return }
                self.recordingElapsed = clock.now - start
                if self.recordingElapsed >= .seconds(240) {
                    self.toggleRecording()
                    return
                }
            }
        }
    }

    private func cancelRecording() {
        guard let recorder,
              recordingStatus == .recording || recordingStatus == .requestingPermission
        else { return }
        recordingTicker?.cancel()
        recordingTicker = nil
        recordingTask?.cancel()
        recordingTask = nil
        recordingStatus = .idle
        recordingElapsed = .zero
        Task { await recorder.cancel() }
    }

    /// Called when the view mounts again after an idempotent shutdown.
    func activate() {
        isUnmounted = false
    }

    /// Idempotent teardown for the mounted view. Volatile sends and imports
    /// must not survive an unmount, and microphone owners are always released.
    func shutdown() {
        isUnmounted = true
        importTask?.cancel()
        importTask = nil
        inventoryTask?.cancel()
        inventoryTask = nil
        runtimeTask?.cancel()
        runtimeTask = nil
        sendTask?.cancel()
        sendTask = nil
        if let outgoing = outgoingByRoute.removeValue(forKey: route.token) {
            files.discard(outgoing)
        }
        progressByRoute.removeValue(forKey: route.token)
        submittingRoutes.remove(route.token)
        outgoing = []
        stagingProgress = nil
        isSubmitting = false
        cancelDictation()
        cancelRecording()
        startupSweepTask?.cancel()
        startupSweepTask = nil

    }

    // MARK: - Escape

    /// Handles one Escape key press, most recent action first. It returns
    /// false when the composer has nothing to cancel, so the caller can give
    /// the key to the find bar, which the caller owns.
    func handleEscape() -> Bool {
        if recordingStatus == .recording || recordingStatus == .requestingPermission {
            cancelRecording()
            return true
        }
        if dictationTask != nil {
            cancelDictation()
            return true
        }
        if let sendTask {
            sendTask.cancel()
            return true
        }
        if notice != nil {
            notice = nil
            return true
        }
        return false
    }

    // MARK: - Per-chat drafts

    private func draftValue(for routeIdentity: String) -> ComposerDraft {
        routeIdentity == route.identity ? draft : (drafts[routeIdentity] ?? ComposerDraft())
    }

    private func mutateDraft(for routeIdentity: String, _ body: (inout ComposerDraft) -> Void) {
        if routeIdentity == route.identity {
            body(&draft)
            return
        }
        var stored = drafts[routeIdentity] ?? ComposerDraft()
        body(&stored)
        store(stored, for: routeIdentity)
    }

    private func store(_ value: ComposerDraft, for routeIdentity: String) {
        guard !value.isEmpty else {
            drafts.removeValue(forKey: routeIdentity)
            draftOrder.removeAll { $0 == routeIdentity }
            return
        }
        drafts[routeIdentity] = value
        draftOrder.removeAll { $0 == routeIdentity }
        draftOrder.append(routeIdentity)
        while draftOrder.count > Self.retainedDraftCount {
            let evicted = draftOrder.removeFirst()
            if let dropped = drafts.removeValue(forKey: evicted) {
                files.discard(dropped.attachments)
            }
        }
    }

    private func takeDraft(for routeIdentity: String) -> ComposerDraft {
        draftOrder.removeAll { $0 == routeIdentity }
        return drafts.removeValue(forKey: routeIdentity) ?? ComposerDraft()
    }
}

/// Forwards staging progress to the main actor at a bounded rate.
///
/// The staging interface reports every chunk it reads. One main-actor hop per
/// chunk would add thousands of hops for a large file, so this reporter
/// forwards on a byte threshold and on the final byte.
private final class StagingProgressReporter: Sendable {
    private let threshold: Int
    private let total: Int
    private let lastReported = OSAllocatedUnfairLock(initialState: 0)
    private let forward: @Sendable (Int) -> Void

    init(total: Int, forward: @escaping @Sendable (Int) -> Void) {
        self.total = total
        // 50 updates for a large file, and never more often than 256 KiB.
        self.threshold = max(256 * 1024, total / 50)
        self.forward = forward
    }

    var report: @Sendable (Int) -> Void {
        { [self] bytes in
            let shouldForward = lastReported.withLock { previous -> Bool in
                guard bytes >= total || bytes - previous >= threshold else { return false }
                previous = bytes
                return true
            }
            guard shouldForward else { return }
            forward(bytes)
        }
    }
}

/// On-disk home for composer attachments.
///
/// Every selection is admitted from an already-open descriptor and copied to
/// an exclusive 0600 partial before an atomic rename. No source path is
/// trusted after admission.
struct ComposerDraftFiles: Sendable {
    let root: URL

    init(root: URL = ComposerDraftFiles.defaultRoot()) {
        self.root = root
    }

    static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return caches.appending(
            path: "\(AppIdentity.bundleID)/composer-drafts",
            directoryHint: .isDirectory
        )
    }

    func directory(for routeIdentity: String) async throws -> URL {
        let root = self.root
        return try await Task.detached(priority: .userInitiated) {
            try Self.makeDirectory(root: root, routeIdentity: routeIdentity)
        }.value
    }

    func adopt(
        _ source: ComposerAttachmentSource,
        target: ComposerRouteToken,
        maximumBytes: Int
    ) async throws -> ComposerAttachment {
        let root = self.root
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard !target.identity.isEmpty, maximumBytes > 0 else {
                throw ComposerFileAdmissionError.unreadable
            }
            let directory = try Self.makeDirectory(root: root, routeIdentity: target.identity)
            let origin = source.url
            var isScoped = false
            if case .picked = source { isScoped = origin.startAccessingSecurityScopedResource() }
            defer { if isScoped { origin.stopAccessingSecurityScopedResource() } }

            let sourceFD = origin.path.withCString {
                open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard sourceFD >= 0 else { throw ComposerFileAdmissionError.unreadable }
            defer { close(sourceFD) }
            var sourceStat = stat()
            guard fstat(sourceFD, &sourceStat) == 0 else {
                throw ComposerFileAdmissionError.unreadable
            }
            guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
                throw ComposerFileAdmissionError.notRegular
            }
            if (try? origin.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                throw ComposerFileAdmissionError.package
            }
            let sourceSize = Int64(sourceStat.st_size)
            guard sourceSize >= 0, sourceSize <= Int64(maximumBytes) else {
                throw ComposerFileAdmissionError.tooLarge
            }

            let itemDirectory = directory.appending(
                path: UUID().uuidString,
                directoryHint: .isDirectory
            )
            let manager = FileManager.default
            try manager.createDirectory(
                at: itemDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let name = Self.fileName(for: origin)
            let destination = itemDirectory.appending(path: name)
            let partial = itemDirectory.appending(path: ".\(UUID().uuidString).partial")
            do {
                let destinationFD = partial.path.withCString {
                    open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
                }
                guard destinationFD >= 0 else {
                    throw ComposerFileAdmissionError.copyFailed
                }
                var copied = 0
                var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                defer { close(destinationFD) }
                while true {
                    try Task.checkCancellation()
                    let count = buffer.withUnsafeMutableBytes {
                        read(sourceFD, $0.baseAddress, $0.count)
                    }
                    if count < 0 { throw ComposerFileAdmissionError.unreadable }
                    if count == 0 { break }
                    guard copied <= maximumBytes - count else {
                        throw ComposerFileAdmissionError.tooLarge
                    }
                    let written = buffer.withUnsafeBytes {
                        write(destinationFD, $0.baseAddress, count)
                    }
                    guard written == count else { throw ComposerFileAdmissionError.copyFailed }
                    copied += count
                }
                guard copied <= maximumBytes else {
                    throw ComposerFileAdmissionError.tooLarge
                }
                guard chmod(partial.path, mode_t(0o600)) == 0 else {
                    throw ComposerFileAdmissionError.copyFailed
                }
                try manager.moveItem(at: partial, to: destination)
                if case .temporary = source {
                    // The temporary file is app-owned; remove it only after the
                    // destination is complete and atomically visible.
                    try? manager.removeItem(at: origin)
                    let originFolder = origin.deletingLastPathComponent()
                    if UUID(uuidString: originFolder.lastPathComponent) != nil {
                        try? manager.removeItem(at: originFolder)
                    }
                }
                return ComposerAttachment(
                    kind: Self.kind(for: destination),
                    displayName: name,
                    byteCount: copied,
                    fileURL: destination,
                    routeIdentity: target.identity
                )
            } catch {
                try? manager.removeItem(at: partial)
                try? manager.removeItem(at: itemDirectory)
                if error is CancellationError {
                    throw ComposerFileAdmissionError.cancelled
                }
                if let error = error as? ComposerFileAdmissionError { throw error }
                throw ComposerFileAdmissionError.copyFailed
            }
        }.value
    }

    func discard(_ attachments: [ComposerAttachment]) {
        discardFiles(attachments.map(\.fileURL))
    }

    func discardFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            for url in urls {
                let parent = url.deletingLastPathComponent()
                let isItemFolder = UUID(uuidString: parent.lastPathComponent) != nil
                try? manager.removeItem(at: isItemFolder ? parent : url)
            }
        }
    }

    func sweepNonPersistedDrafts() async -> Bool {
        let root = self.root
        return await Task.detached(priority: .utility) {
            do {
                let manager = FileManager.default
                try manager.createDirectory(
                    at: root,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                var rootStat = stat()
                guard root.path.withCString({ lstat($0, &rootStat) }) == 0,
                      (rootStat.st_mode & S_IFMT) != S_IFLNK else {
                    return false
                }
                let attributes = try manager.attributesOfItem(atPath: root.path)
                guard let owner = attributes[.ownerAccountID] as? NSNumber,
                      owner.uint32Value == geteuid() else {
                    return false
                }
                guard chmod(root.path, mode_t(0o700)) == 0 else { return false }
                let entries = try manager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isSymbolicLinkKey],
                    options: []
                )
                for entry in entries where !Self.isBackup(entry) {
                    try manager.removeItem(at: entry)
                }
                return true
            } catch {
                return false
            }
        }.value
    }

    private static func isBackup(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == "backup" || name == ".backup" || name.hasPrefix("backup-")
    }

    fileprivate static func makeDirectory(root: URL, routeIdentity: String) throws -> URL {
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) {
            var rootStat = stat()
            guard root.path.withCString({ lstat($0, &rootStat) }) == 0,
                  (rootStat.st_mode & S_IFMT) == S_IFDIR else {
                throw ComposerFileAdmissionError.unreadable
            }
        }
        let directory = root.appending(
            path: folderName(for: routeIdentity),
            directoryHint: .isDirectory
        )
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var directoryStat = stat()
        guard directory.path.withCString({ lstat($0, &directoryStat) }) == 0,
              (directoryStat.st_mode & S_IFMT) == S_IFDIR else {
            throw ComposerFileAdmissionError.unreadable
        }
        _ = chmod(directory.path, mode_t(0o700))
        return directory
    }

    /// Computes the pre-copy ceiling from the filename's declared kind.
    fileprivate static func limit(for url: URL) -> Int {
        ComposerAttachmentLimits.ceiling(for: kind(for: url))
    }

    private static func folderName(for routeIdentity: String) -> String {
        let digest = SHA256.hash(data: Data(routeIdentity.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileName(for url: URL) -> String {
        let scalars = url.lastPathComponent.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\"
        }
        let name = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { return "attachment" }
        return String(name.prefix(120))
    }

    private static func kind(for url: URL) -> ComposerAttachment.Kind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        return .file
    }
}

extension Int {
    /// A file size for one composer message. `ByteCountFormatStyle` takes an
    /// `Int64`, and every composer size is a file size.
    var composerByteSize: String {
        Int64(self).formatted(.byteCount(style: .file))
    }
}
