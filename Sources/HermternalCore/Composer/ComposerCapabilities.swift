import Foundation

public protocol SessionRuntimeControlling: Sendable {
    func modelInventory(sessionID: String?, refresh: Bool) async throws -> ModelInventory
    func setModel(_ model: String, provider: String?, sessionID: String) async throws -> ModelSwitchOutcome
    func setReasoning(_ setting: ReasoningSetting, sessionID: String) async throws
}

/// The outcome of one server-side attachment effect.
public enum AttachmentStagingOutcome: Equatable, Sendable {
    case staged
    case committed
    case rolledBack
    /// The transport was interrupted after the operation was sent. This is
    /// intentionally distinct from `rolledBack`: retrying may duplicate data.
    case outcomeUnknown
}

public enum AttachmentRollbackSupport: Equatable, Sendable {
    case supported
    case unsupported(reason: String)
}

/// A completed per-item receipt. Every receipt is bound to both the route and
/// live session that produced it, and can therefore be safely reused only in
/// that same transaction context.
public struct AttachmentStagingReceipt: Equatable, Sendable {
    public let id: UUID
    public let sessionID: String
    public let routeIdentity: String
    public let deterministicName: String
    public let serverReference: String?
    public let serverPath: String?
    public let outcome: AttachmentStagingOutcome
    public let rollbackSupport: AttachmentRollbackSupport

    public init(
        id: UUID,
        sessionID: String,
        routeIdentity: String,
        deterministicName: String,
        serverReference: String?,
        serverPath: String?,
        outcome: AttachmentStagingOutcome,
        rollbackSupport: AttachmentRollbackSupport
    ) {
        self.id = id
        self.sessionID = sessionID
        self.routeIdentity = routeIdentity
        self.deterministicName = deterministicName
        self.serverReference = serverReference
        self.serverPath = serverPath
        self.outcome = outcome
        self.rollbackSupport = rollbackSupport
    }
}

public enum AttachmentStagingTransactionState: Equatable, Sendable {
    case open
    case committed
    case compensated
    /// A known server effect has no upstream detach operation.
    case residual
    /// The transport interrupted an effect and its existence is unknown.
    case outcomeUnknown
}

public struct AttachmentStagingBatchReceipt: Equatable, Sendable {
    public let transactionID: UUID
    public let sessionID: String
    public let routeIdentity: String
    public let items: [AttachmentStagingReceipt]
    public let state: AttachmentStagingTransactionState

    public init(
        transactionID: UUID,
        sessionID: String,
        routeIdentity: String,
        items: [AttachmentStagingReceipt],
        state: AttachmentStagingTransactionState
    ) {
        self.transactionID = transactionID
        self.sessionID = sessionID
        self.routeIdentity = routeIdentity
        self.items = items
        self.state = state
    }
}

public enum AttachmentCompensationResult: Equatable, Sendable {
    case complete(AttachmentStagingBatchReceipt)
    case residual(AttachmentStagingBatchReceipt, unsupported: [UUID], unknown: [UUID])
}

public enum AttachmentStagingError: LocalizedError, Equatable, Sendable {
    case invalidRoute
    case invalidReceipt
    case unsupported(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoute: return "Attachment staging requires a route and session."
        case .invalidReceipt: return "The attachment receipt does not belong to this route."
        case .unsupported(let reason): return reason
        }
    }
}

public protocol AttachmentStagingTransaction: Sendable {
    var transactionID: UUID { get }
    var sessionID: String { get }
    var routeIdentity: String { get }
    func snapshot() async -> AttachmentStagingBatchReceipt
    func reuse(_ receipt: AttachmentStagingReceipt) async throws -> AttachmentStagingReceipt
    func commit() async throws -> AttachmentStagingBatchReceipt
    func rollback() async -> AttachmentCompensationResult
}

public enum AttachmentStagingFailureReason: Equatable, Sendable {
    case rejected
    case residual
    case outcomeUnknown
}

/// Stable transport-independent failure returned by a batch provider. The
/// receipt/compensation fields preserve exactly what may still exist server
/// side, so callers never infer safety from a localized transport error.
public struct AttachmentStagingBatchFailure: LocalizedError, Equatable, Sendable {
    public let reason: AttachmentStagingFailureReason
    public let batch: AttachmentStagingBatchReceipt?
    public let compensation: AttachmentCompensationResult?

    public init(
        reason: AttachmentStagingFailureReason,
        batch: AttachmentStagingBatchReceipt?,
        compensation: AttachmentCompensationResult?
    ) {
        self.reason = reason
        self.batch = batch
        self.compensation = compensation
    }

    public var errorDescription: String? {
        switch reason {
        case .rejected: return "Attachment staging was rejected."
        case .residual: return "Attachment staging left a server-side residual."
        case .outcomeUnknown: return "Attachment staging outcome is unknown."
        }
    }
}

public protocol AttachmentStaging: Sendable {
    /// Stages serially and returns a transaction whose completed receipts can
    /// be committed, compensated, or reused after cancellation/retry.
    func stageBatch(
        _ steps: [ComposerStagingStep],
        sessionID: String,
        routeIdentity: String,
        progress: @escaping @Sendable (UUID, Int) -> Void,
        reusing receipts: [AttachmentStagingReceipt]
    ) async throws -> any AttachmentStagingTransaction
}

public extension AttachmentStaging {
    func stageBatch(
        _ steps: [ComposerStagingStep],
        sessionID: String,
        routeIdentity: String,
        progress: @escaping @Sendable (UUID, Int) -> Void
    ) async throws -> any AttachmentStagingTransaction {
        try await stageBatch(
            steps,
            sessionID: sessionID,
            routeIdentity: routeIdentity,
            progress: progress,
            reusing: []
        )
    }
}

public enum DictationAvailability: Equatable, Sendable {
    case available
    case needsModelInstall(locale: String)
    case unsupportedLocale(String)
    case permissionDenied
    case unavailable(reason: String)
}

public struct DictationUpdate: Equatable, Sendable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public protocol SpeechDictating: Sendable {
    func availability() async -> DictationAvailability
    func prepare() async throws
    func start() async throws -> AsyncThrowingStream<DictationUpdate, any Error>
    func stop() async
    func cancel() async
}

public struct AudioRecordingResult: Equatable, Sendable {
    public let fileURL: URL
    public let duration: Duration
    public let byteCount: Int

    public init(fileURL: URL, duration: Duration, byteCount: Int) {
        self.fileURL = fileURL
        self.duration = duration
        self.byteCount = byteCount
    }
}

public protocol AudioRecording: Sendable {
    func requestPermission() async -> Bool
    func start(into directory: URL) async throws
    func stop() async throws -> AudioRecordingResult
    func cancel() async
}
