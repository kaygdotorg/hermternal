import Foundation
import HermternalCore
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The gateway-facing implementation of the composer runtime seams.
///
/// GatewayClient owns the WebSocket. This adapter only translates the small,
/// typed composer interface into gateway calls and keeps file work off the
/// caller's actor. GatewayClient has no upload-progress API, so progress means
/// bytes read from the local file. It does not mean bytes accepted by the
/// WebSocket or gateway.
public actor GatewayRuntimeAdapter: SessionRuntimeControlling, AttachmentStaging {
    private let gateway: GatewayClient
    /// Last successful `model.options` payload, keyed by live session id.
    /// An empty key stores the catalog from a call with no session id.
    private var inventoryCache: [String: ModelInventory] = [:]
    /// In-flight inventory loads. Cancel must drop the parked task.
    private var inventoryInFlight: [String: Task<ModelInventory, Error>] = [:]
    private var inventoryInFlightIDs: [String: UUID] = [:]

    public init(gateway: GatewayClient) {
        self.gateway = gateway
    }

    // MARK: SessionRuntimeControlling

    /// Loads the model catalog. A nil session id omits `session_id` on the wire.
    ///
    /// Browse prefetch uses that catalog path. Warming chats does not resume sessions.
    public func modelInventory(sessionID: String?, refresh: Bool) async throws -> ModelInventory {
        let cacheKey = sessionID ?? ""
        if !refresh, let cached = inventoryCache[cacheKey] {
            return cached
        }
        if !refresh, let inflight = inventoryInFlight[cacheKey] {
            return try await inflight.value
        }

        let requestID = UUID()
        inventoryInFlightIDs[cacheKey] = requestID
        let gateway = self.gateway
        let task = Task<ModelInventory, Error> {
            var params: [String: Any] = [:]
            if let sessionID, !sessionID.isEmpty { params["session_id"] = sessionID }
            if refresh { params["refresh"] = true }
            let response = try await gateway.call("model.options", params: params)
            let payload = Self.unwrapModelOptions(response)
            return try ModelInventory.decode(payload)
        }
        inventoryInFlight[cacheKey] = task
        do {
            // Honour cancellation so a parked inventory load does not hold the next caller.
            let inventory = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if inventoryInFlightIDs[cacheKey] == requestID {
                inventoryCache[cacheKey] = inventory
                inventoryInFlight[cacheKey] = nil
                inventoryInFlightIDs[cacheKey] = nil
            }
            return inventory
        } catch {
            if inventoryInFlightIDs[cacheKey] == requestID {
                inventoryInFlight[cacheKey] = nil
                inventoryInFlightIDs[cacheKey] = nil
            }
            throw error
        }
    }

    public func setModel(
        _ model: String,
        provider: String?,
        sessionID: String
    ) async throws -> ModelSwitchOutcome {
        guard !model.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw GatewayRuntimeAdapterError.invalidValue(method: "config.set", field: "model")
        }
        guard !sessionID.isEmpty else {
            throw GatewayRuntimeAdapterError.invalidValue(method: "config.set", field: "session_id")
        }

        let normalizedProvider = provider?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let wireValue: String
        if let normalizedProvider, !normalizedProvider.isEmpty {
            wireValue = "\(model) --provider \(normalizedProvider)"
        } else {
            wireValue = model
        }
        let params: [String: Any] = [
            "key": "model",
            "value": wireValue,
            "session_id": sessionID
        ]
        let response = try await gateway.call("config.set", params: params)
        let outcome = try Self.decodeModelSwitchOutcome(response, requested: model)
        inventoryCache.removeValue(forKey: sessionID)
        inventoryInFlight[sessionID]?.cancel()
        inventoryInFlight.removeValue(forKey: sessionID)
        inventoryInFlightIDs.removeValue(forKey: sessionID)
        return outcome
    }

    public func setReasoning(_ setting: ReasoningSetting, sessionID: String) async throws {
        guard !sessionID.isEmpty else {
            throw GatewayRuntimeAdapterError.invalidValue(method: "config.set", field: "session_id")
        }
        _ = try await gateway.call(
            "config.set",
            params: [
                "key": "reasoning",
                "value": setting.wireValue,
                "session_id": sessionID
            ]
        )
    }

    /// Projects the same metadata shape from create/resume responses or a
    /// session.info event. No RPC is issued because session.info is push-only.
    public nonisolated static func decodeRuntimeSnapshot(
        from info: JSONValue?
    ) -> SessionRuntimeSnapshot {
        SessionRuntimeSnapshot.decode(info)
    }


    // MARK: AttachmentStaging

    public func stageBatch(
        _ steps: [ComposerStagingStep],
        sessionID: String,
        routeIdentity: String,
        progress: @escaping @Sendable (UUID, Int) -> Void,
        reusing receipts: [AttachmentStagingReceipt]
    ) async throws -> any AttachmentStagingTransaction {
        guard !sessionID.isEmpty, !routeIdentity.isEmpty else {
            throw AttachmentStagingBatchFailure(
                reason: .rejected, batch: nil, compensation: nil
            )
        }
        let transaction = GatewayAttachmentTransaction(
            gateway: gateway,
            sessionID: sessionID,
            routeIdentity: routeIdentity
        )
        do {
            try Self.validate(steps: steps, routeIdentity: routeIdentity)
            let expectedIDs = Set(steps.map { $0.attachment.id })
            guard Set(receipts.map(\.id)).isSubset(of: expectedIDs),
                  receipts.allSatisfy({ receipt in
                      guard let step = steps.first(where: { $0.attachment.id == receipt.id }) else {
                          return false
                      }
                      return receipt.deterministicName
                          == ComposerSendPolicy.deterministicAttachmentName(for: step.attachment)
                  })
            else {
                throw AttachmentStagingError.invalidReceipt
            }
            for receipt in receipts {
                _ = try await transaction.reuse(receipt)
            }
            for step in steps {
                try Task.checkCancellation()
                _ = try await transaction.stage(step, progress: {
                    progress(step.attachment.id, $0)
                })
            }
            return transaction
        } catch is CancellationError {
            let result = await transaction.rollback()
            if case .complete = result { throw CancellationError() }
            throw Self.batchFailure(
                reason: .residual, result: result
            )
        } catch let error as AttachmentStagingBatchFailure {
            throw error
        } catch {
            let result = await transaction.rollback()
            let reason: AttachmentStagingFailureReason
            if let adapterError = error as? GatewayRuntimeAdapterError,
               case .outcomeUnknown(id: _) = adapterError {
                reason = .outcomeUnknown
            } else {
                switch result {
                case .complete: reason = .rejected
                case .residual: reason = .residual
                }
            }
            throw Self.batchFailure(reason: reason, result: result)
        }
    }

    private static func batchFailure(
        reason: AttachmentStagingFailureReason,
        result: AttachmentCompensationResult
    ) -> AttachmentStagingBatchFailure {
        let batch: AttachmentStagingBatchReceipt
        switch result {
        case .complete(let value), .residual(let value, unsupported: _, unknown: _):
            batch = value
        }
        return AttachmentStagingBatchFailure(
            reason: reason, batch: batch, compensation: result
        )
    }

    // MARK: Validation and decoding

    fileprivate static func validate(_ attachment: ComposerAttachment) throws {
        let limit = ComposerAttachmentLimits.ceiling(for: attachment.kind)
        guard attachment.byteCount <= limit else {
            throw GatewayRuntimeAdapterError.attachmentTooLarge(
                id: attachment.id,
                limit: limit,
                actual: attachment.byteCount
            )
        }
    }

    fileprivate static func validate(
        steps: [ComposerStagingStep],
        routeIdentity: String
    ) throws {
        guard steps.count <= ComposerAttachmentLimits.maximumItems else {
            throw GatewayRuntimeAdapterError.tooManyAttachments(
                limit: ComposerAttachmentLimits.maximumItems
            )
        }
        var total = 0
        for step in steps {
            let attachment = step.attachment
            try validate(attachment)
            guard attachment.routeIdentity == routeIdentity else {
                throw GatewayRuntimeAdapterError.invalidValue(method: "attach", field: "route")
            }
            let addition = total.addingReportingOverflow(attachment.byteCount)
            guard !addition.overflow, addition.partialValue <= ComposerAttachmentLimits.totalBytes else {
                throw GatewayRuntimeAdapterError.totalAttachmentLimitExceeded(
                    limit: ComposerAttachmentLimits.totalBytes
                )
            }
            total = addition.partialValue
        }
    }

    private static func unwrapModelOptions(_ value: JSONValue) -> JSONValue {
        guard case .object(let fields) = value else { return value }
        if let options = fields["options"] { return unwrapModelOptions(options) }
        if let result = fields["result"] { return unwrapModelOptions(result) }
        return value
    }

    private static func decodeModelSwitchOutcome(
        _ value: JSONValue,
        requested: String
    ) throws -> ModelSwitchOutcome {
        if case .string(let applied) = value {
            return ModelSwitchOutcome(appliedValue: applied, isDeferredToNextTurn: false)
        }
        guard case .object(let fields) = value else {
            throw GatewayRuntimeAdapterError.malformedResponse(method: "config.set")
        }
        let applied = fields["value"]?.stringValue
            ?? fields["model"]?.stringValue
            ?? fields["applied_value"]?.stringValue
            ?? requested
        let deferred = fields["deferred"]?.boolValue
            ?? fields["is_deferred"]?.boolValue
            ?? false
        return ModelSwitchOutcome(appliedValue: applied, isDeferredToNextTurn: deferred)
    }

    /// Reads and encodes in a detached task. No-follow semantics equivalent to
    /// `O_NOFOLLOW` are provided by lstat plus descriptor identity comparison;
    /// fstat before/after reading also detects replacement, growth, or shrink.
    fileprivate static func base64Payload(
        for attachment: ComposerAttachment,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> String {
        let url = attachment.fileURL
        let expected = attachment.byteCount
        let limit = ComposerAttachmentLimits.ceiling(for: attachment.kind)
        guard expected <= limit else {
            throw GatewayRuntimeAdapterError.attachmentTooLarge(
                id: attachment.id, limit: limit, actual: expected
            )
        }
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
#if canImport(Darwin)
            let lstatResult: Int32
            var pathIdentity = stat()
            lstatResult = url.withUnsafeFileSystemRepresentation {
                Darwin.lstat($0, &pathIdentity)
            }
#else
            let lstatResult: Int32
            var pathIdentity = stat()
            lstatResult = url.withUnsafeFileSystemRepresentation {
                Glibc.lstat($0, &pathIdentity)
            }
#endif
            guard lstatResult == 0,
                  Int32(pathIdentity.st_mode) & Int32(S_IFMT) == Int32(S_IFREG)
            else {
                throw GatewayRuntimeAdapterError.fileUnreadable(id: attachment.id)
            }
            let handle: FileHandle
            do {
                // lstat rejects a symlink, while FileHandle opens the path.
                // The descriptor identity is compared to lstat immediately
                // below, closing the path-swap race without a C open wrapper.
                handle = try FileHandle(forReadingFrom: url)
            } catch {
                throw GatewayRuntimeAdapterError.fileUnreadable(id: attachment.id)
            }
            let fd = handle.fileDescriptor
            var before = stat()
            guard fstat(fd, &before) == 0,
                  Int32(before.st_mode) & Int32(S_IFMT) == Int32(S_IFREG),
                  before.st_dev == pathIdentity.st_dev,
                  before.st_ino == pathIdentity.st_ino
            else {
                throw GatewayRuntimeAdapterError.fileChanged(id: attachment.id)
            }
            let beforeSize = Int(before.st_size)
            guard beforeSize >= 0 else {
                throw GatewayRuntimeAdapterError.fileUnreadable(id: attachment.id)
            }
            guard beforeSize == expected else {
                throw GatewayRuntimeAdapterError.fileChanged(id: attachment.id)
            }
            var encoded = String()
            encoded.reserveCapacity(min(
                GatewayRuntimeAdapterLimits.transientEncodedBytes,
                ((beforeSize + 2) / 3) * 4
            ))
            var bytesRead = 0
            while let chunk = try handle.read(upToCount: 65_535), !chunk.isEmpty {
                try Task.checkCancellation()
                let encodedChunk = chunk.base64EncodedString()
                guard encoded.utf8.count + encodedChunk.utf8.count
                    <= GatewayRuntimeAdapterLimits.transientEncodedBytes
                else {
                    throw GatewayRuntimeAdapterError.transientPayloadTooLarge(
                        id: attachment.id,
                        limit: GatewayRuntimeAdapterLimits.transientEncodedBytes
                    )
                }
                encoded.append(encodedChunk)
                bytesRead += chunk.count
                guard bytesRead <= limit else {
                    throw GatewayRuntimeAdapterError.attachmentTooLarge(
                        id: attachment.id, limit: limit, actual: bytesRead
                    )
                }
                progress(bytesRead)
            }
            var after = stat()
            guard fstat(fd, &after) == 0 else {
                throw GatewayRuntimeAdapterError.fileChanged(id: attachment.id)
            }
            guard before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino,
                  before.st_size == after.st_size,
                  bytesRead == expected
            else {
                throw GatewayRuntimeAdapterError.fileChanged(id: attachment.id)
            }
            return encoded
        }.value
    }
}
private enum GatewayRuntimeAdapterLimits {
    /// JSONSerialization and URLSession both retain the frame while sending;
    /// admit a smaller encoded item than the raw attachment ceiling.
    static let transientEncodedBytes = 16 * 1024 * 1024
}

private actor GatewayAttachmentTransaction: AttachmentStagingTransaction {
    let transactionID = UUID()
    let sessionID: String
    let routeIdentity: String
    private let gateway: GatewayClient
    private var items: [UUID: AttachmentStagingReceipt] = [:]
    private var state: AttachmentStagingTransactionState = .open

    init(gateway: GatewayClient, sessionID: String, routeIdentity: String) {
        self.gateway = gateway
        self.sessionID = sessionID
        self.routeIdentity = routeIdentity
    }

    func snapshot() async -> AttachmentStagingBatchReceipt {
        receipt()
    }

    func stage(
        _ step: ComposerStagingStep,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> AttachmentStagingReceipt {
        guard state == .open else {
            throw GatewayRuntimeAdapterError.transactionClosed
        }
        let attachment = step.attachment
        let name = ComposerSendPolicy.deterministicAttachmentName(for: attachment)
        if let existing = items[attachment.id] {
            guard existing.deterministicName == name else {
                throw GatewayRuntimeAdapterError.invalidValue(method: "attach", field: "attachment_id")
            }
            return existing
        }
        let payload = try await GatewayRuntimeAdapter.base64Payload(
            for: attachment,
            progress: progress
        )
        let staged: AttachmentStagingReceipt
        do {
            switch step {
            case .imageBytes:
                let response = try await gateway.call(
                    "image.attach_bytes",
                    params: [
                        "session_id": sessionID,
                        "content_base64": payload,
                        "filename": name
                    ]
                )
                guard let path = response["path"]?.stringValue,
                      !path.isEmpty,
                      path.utf8.count <= 4_096,
                      path.unicodeScalars.allSatisfy({
                          !CharacterSet.controlCharacters.contains($0)
                      })
                else {
                    throw GatewayRuntimeAdapterError.outcomeUnknown(id: attachment.id)
                }
                staged = AttachmentStagingReceipt(
                    id: attachment.id, sessionID: sessionID, routeIdentity: routeIdentity,
                    deterministicName: name, serverReference: nil, serverPath: path,
                    outcome: .staged, rollbackSupport: .supported
                )
            case .pdf:
                do {
                    _ = try await gateway.call(
                        "pdf.attach",
                        params: [
                            "session_id": sessionID,
                            "content_base64": payload,
                            "filename": name
                        ]
                    )
                    staged = AttachmentStagingReceipt(
                        id: attachment.id, sessionID: sessionID, routeIdentity: routeIdentity,
                        deterministicName: name, serverReference: nil, serverPath: nil,
                        outcome: .staged,
                        rollbackSupport: .unsupported(reason: "gateway has no pdf.detach")
                    )
                } catch GatewayError.rpc(let code, _) where code == 5028 {
                    staged = try await attachGeneric(attachment, name: name, base64: payload)
                }
            case .file:
                staged = try await attachGeneric(attachment, name: name, base64: payload)
            }
        } catch GatewayError.outcomeUnknownAfterSend {
            state = .outcomeUnknown
            throw GatewayRuntimeAdapterError.outcomeUnknown(id: attachment.id)
        } catch GatewayRuntimeAdapterError.outcomeUnknown(id: _) {
            state = .outcomeUnknown
            throw GatewayRuntimeAdapterError.outcomeUnknown(id: attachment.id)
        }
        items[attachment.id] = staged
        return staged
    }

    func reuse(_ receipt: AttachmentStagingReceipt) async throws -> AttachmentStagingReceipt {
        guard state == .open else {
            throw GatewayRuntimeAdapterError.transactionClosed
        }
        guard receipt.sessionID == sessionID,
              receipt.routeIdentity == routeIdentity,
              receipt.outcome == .staged,
              receipt.serverReference.map(ComposerSendPolicy.validatedReferenceText) != nil
                || receipt.serverReference == nil
        else {
            throw AttachmentStagingError.invalidReceipt
        }
        if let existing = items[receipt.id] {
            guard existing == receipt else { throw AttachmentStagingError.invalidReceipt }
            return existing
        }
        items[receipt.id] = receipt
        return receipt
    }

    func commit() async throws -> AttachmentStagingBatchReceipt {
        guard state == .open else {
            throw GatewayRuntimeAdapterError.transactionClosed
        }
        state = .committed
        items = items.mapValues { item in
            AttachmentStagingReceipt(
                id: item.id, sessionID: item.sessionID, routeIdentity: item.routeIdentity,
                deterministicName: item.deterministicName, serverReference: item.serverReference,
                serverPath: item.serverPath, outcome: .committed,
                rollbackSupport: item.rollbackSupport
            )
        }
        return receipt()
    }

    func rollback() async -> AttachmentCompensationResult {
        guard state != .compensated, state != .committed else {
            return .complete(receipt())
        }
        var unsupported: [UUID] = []
        var unknown: [UUID] = []
        for item in items.values {
            guard item.outcome != .rolledBack else { continue }
            switch item.rollbackSupport {
            case .unsupported:
                unsupported.append(item.id)
            case .supported:
                guard let path = item.serverPath, !path.isEmpty else {
                    unknown.append(item.id)
                    continue
                }
                do {
                    _ = try await gateway.call(
                        "image.detach",
                        params: ["session_id": sessionID, "path": path]
                    )
                    items[item.id] = AttachmentStagingReceipt(
                        id: item.id, sessionID: item.sessionID, routeIdentity: item.routeIdentity,
                        deterministicName: item.deterministicName, serverReference: item.serverReference,
                        serverPath: item.serverPath, outcome: .rolledBack,
                        rollbackSupport: item.rollbackSupport
                    )
                } catch GatewayError.outcomeUnknownAfterSend {
                    unknown.append(item.id)
                } catch {
                    unknown.append(item.id)
                }
            }
        }
        if unsupported.isEmpty && unknown.isEmpty {
            state = .compensated
            return .complete(receipt())
        }
        state = unknown.isEmpty ? .residual : .outcomeUnknown
        return .residual(receipt(), unsupported: unsupported, unknown: unknown)
    }

    private func attachGeneric(
        _ attachment: ComposerAttachment,
        name: String,
        base64: String
    ) async throws -> AttachmentStagingReceipt {
        let mime = UTType(filenameExtension: attachment.fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = try await gateway.call(
            "file.attach",
            params: [
                "session_id": sessionID,
                "data_url": "data:\(mime);base64,\(base64)",
                "name": name
            ]
        )
        guard let raw = response["ref_text"]?.stringValue,
              let reference = ComposerSendPolicy.validatedReferenceText(raw)
        else {
            throw GatewayRuntimeAdapterError.outcomeUnknown(id: attachment.id)
        }
        return AttachmentStagingReceipt(
            id: attachment.id, sessionID: sessionID, routeIdentity: routeIdentity,
            deterministicName: name, serverReference: reference, serverPath: nil,
            outcome: .staged,
            rollbackSupport: .unsupported(reason: "gateway has no file.detach")
        )
    }

    private func receipt() -> AttachmentStagingBatchReceipt {
        AttachmentStagingBatchReceipt(
            transactionID: transactionID, sessionID: sessionID,
            routeIdentity: routeIdentity, items: items.values.sorted { $0.id.uuidString < $1.id.uuidString },
            state: state
        )
    }
}

public enum GatewayRuntimeAdapterError: LocalizedError, Equatable, Sendable {
    case invalidValue(method: String, field: String)
    case malformedResponse(method: String)
    case attachmentTooLarge(id: UUID, limit: Int, actual: Int)
    case transientPayloadTooLarge(id: UUID, limit: Int)
    case tooManyAttachments(limit: Int)
    case totalAttachmentLimitExceeded(limit: Int)
    case fileUnreadable(id: UUID)
    case fileChanged(id: UUID)
    case outcomeUnknown(id: UUID)
    case transactionClosed
    case compensationIncomplete(original: String, result: AttachmentCompensationResult)

    public var errorDescription: String? {
        switch self {
        case let .invalidValue(method, field):
            return "Gateway call \(method) requires a valid \(field)."
        case let .malformedResponse(method):
            return "Gateway returned malformed data for \(method)."
        case let .attachmentTooLarge(_, limit, actual):
            return "Attachment is \(actual) bytes, above the \(limit)-byte limit."
        case let .transientPayloadTooLarge(_, limit):
            return "Attachment exceeds the \(limit)-byte transient gateway frame limit."
        case let .tooManyAttachments(limit):
            return "The composer supports at most \(limit) attachments."
        case let .totalAttachmentLimitExceeded(limit):
            return "Attachments exceed the \(limit)-byte total limit."
        case .fileUnreadable:
            return "The attachment file could not be read."
        case .fileChanged:
            return "The attachment changed while it was being staged."
        case .outcomeUnknown:
            return "Attachment staging was sent but its gateway outcome is unknown."
        case .transactionClosed:
            return "The attachment transaction is already closed."
        case .compensationIncomplete:
            return "Attachment staging failed and left a server-side residual."
        }
    }
}
