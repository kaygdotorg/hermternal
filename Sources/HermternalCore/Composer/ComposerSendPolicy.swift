import Foundation

public enum ComposerStagingStep: Equatable, Sendable {
    case imageBytes(ComposerAttachment)
    case pdf(ComposerAttachment)
    case file(ComposerAttachment)

    public var attachment: ComposerAttachment {
        switch self {
        case let .imageBytes(value), let .pdf(value), let .file(value): return value
        }
    }
}

public struct ComposerSubmission: Equatable, Sendable {
    public let text: String
    public let staging: [ComposerStagingStep]
    public let clearsDraftImmediately: Bool

    public init(text: String, staging: [ComposerStagingStep], clearsDraftImmediately: Bool = true) {
        self.text = text
        self.staging = staging
        self.clearsDraftImmediately = clearsDraftImmediately
    }
}

public enum ComposerSendRejection: Equatable, Sendable {
    case emptyDraft
    case awaitingReply
    case readOnlyTranscript
    case oversizeAttachment(id: UUID, limit: Int)
    case tooManyAttachments(limit: Int)
    case invalidRoute
}

public enum ComposerSendDecision: Equatable, Sendable {
    case send(ComposerSubmission)
    case rejected(ComposerSendRejection)
}

public enum ComposerSendPolicy {
    public static func decide(
        draft: ComposerDraft,
        isAwaitingReply: Bool,
        isReadOnlyTranscript: Bool
    ) -> ComposerSendDecision {
        if isReadOnlyTranscript { return .rejected(.readOnlyTranscript) }
        if isAwaitingReply { return .rejected(.awaitingReply) }
        guard !draft.isEmpty else { return .rejected(.emptyDraft) }
        guard draft.isRouteScoped else { return .rejected(.invalidRoute) }
        guard draft.attachments.count <= ComposerAttachmentLimits.maximumItems else {
            return .rejected(.tooManyAttachments(limit: ComposerAttachmentLimits.maximumItems))
        }

        var total = 0
        for attachment in draft.attachments {
            let limit = ComposerAttachmentLimits.ceiling(for: attachment.kind)
            if attachment.byteCount > limit {
                return .rejected(.oversizeAttachment(id: attachment.id, limit: limit))
            }
            // byteCount is non-negative by construction; still use checked
            // addition so malformed values can never wrap the total ceiling.
            let addition = total.addingReportingOverflow(attachment.byteCount)
            guard !addition.overflow else {
                return .rejected(.oversizeAttachment(id: attachment.id,
                                                      limit: ComposerAttachmentLimits.totalBytes))
            }
            total = addition.partialValue
            if total > ComposerAttachmentLimits.totalBytes {
                return .rejected(.oversizeAttachment(id: attachment.id,
                                                      limit: ComposerAttachmentLimits.totalBytes))
            }
        }

        let ordered = stagingSteps(for: draft.attachments)
        return .send(ComposerSubmission(
            text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
            staging: ordered,
            clearsDraftImmediately: true
        ))
    }

    /// Appends each gateway file reference on its own line. This is also valid
    /// for attachment-only sends: the references become the complete prompt.
    public static func submissionText(trimmed: String, fileReferences: [String]) -> String {
        let body = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let references = fileReferences.compactMap {
            validatedReferenceText($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !references.isEmpty else { return body }
        guard !body.isEmpty else { return references.joined(separator: "\n") }
        return ([body] + references).joined(separator: "\n")
    }

    /// Returns a stable, gateway-safe name. User-controlled display names are
    /// never used as an identity or idempotency key.
    public static func deterministicAttachmentName(for attachment: ComposerAttachment) -> String {
        let ext = attachment.fileURL.pathExtension
        let safeExtension = ext.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122)
        } ? ext.lowercased() : ""
        let base = "attachment-\(attachment.id.uuidString.lowercased())"
        return safeExtension.isEmpty ? base : "\(base).\(safeExtension)"
    }

    /// Validates the only reference syntax accepted from a gateway response.
    /// A reference is a single-line, bounded, relative file path.
    public static func validatedReferenceText(_ value: String) -> String? {
        let reference = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference == value,
              reference.hasPrefix("@file:"),
              reference.utf8.count <= 512
        else { return nil }
        let path = String(reference.dropFirst(6))
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("//") else { return nil }
        guard path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
        }) else { return nil }
        guard path.unicodeScalars.allSatisfy({
            switch $0.value {
            case 45, 46, 47, 48...57, 65...90, 95, 97...122: return true
            default: return false
            }
        }) else { return nil }
        return reference
    }

    /// Restores the submitted values before any newer edits. Attachments are
    /// de-duplicated by stable occurrence id while preserving both sequences.
    public static func restore(_ draft: ComposerDraft, into current: ComposerDraft) -> ComposerDraft {
        let restoredText: String
        let oldText = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldText.isEmpty { restoredText = current.text }
        else if newText.isEmpty { restoredText = draft.text }
        else { restoredText = draft.text + "\n" + current.text }

        var attachments = draft.attachments
        let ids = Set(attachments.map(\.id))
        attachments.append(contentsOf: current.attachments.filter { !ids.contains($0.id) })
        return ComposerDraft(text: restoredText, attachments: attachments)
    }

    private static func stagingSteps(for attachments: [ComposerAttachment]) -> [ComposerStagingStep] {
        // Gateway staging is intentionally grouped by method: image bytes,
        // PDF, then generic file. Filtering each group preserves user order.
        let images = attachments.compactMap { attachment -> ComposerStagingStep? in
            guard attachment.kind == .image else { return nil }
            return .imageBytes(attachment)
        }
        let pdfs = attachments.compactMap { attachment -> ComposerStagingStep? in
            guard attachment.kind == .pdf else { return nil }
            return .pdf(attachment)
        }
        let files = attachments.compactMap { attachment -> ComposerStagingStep? in
            guard attachment.kind == .file || attachment.kind == .audioRecording else { return nil }
            return .file(attachment)
        }
        return images + pdfs + files
    }
}

public enum ComposerPrimaryAction: Equatable, Sendable {
    case send(isEnabled: Bool)
    case stop
}

public enum ComposerActivity: Equatable, Sendable {
    case idle
    case staging(itemID: UUID, bytesSent: Int, bytesTotal: Int)
    case submitting
    case streaming
    case recording(elapsed: Duration)
    case dictating
}
