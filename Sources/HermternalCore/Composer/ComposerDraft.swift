import Foundation

/// Attachment metadata for a composer draft. Payload bytes remain on disk;
/// send policy validation rejects non-file-backed or cross-route values.
public struct ComposerAttachment: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case image
        case pdf
        case file
        case audioRecording
    }

    public let id: UUID
    public let kind: Kind
    public let displayName: String
    public let byteCount: Int
    public let fileURL: URL
    public let duration: Duration?
    public let routeIdentity: String

    public init(
        id: UUID = UUID(),
        kind: Kind,
        displayName: String,
        byteCount: Int,
        fileURL: URL,
        duration: Duration? = nil,
        routeIdentity: String
    ) {
        precondition(byteCount >= 0, "Attachment byte count cannot be negative")
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.byteCount = byteCount
        self.fileURL = fileURL
        self.duration = duration
        self.routeIdentity = routeIdentity
    }
}

public struct ComposerDraft: Equatable, Sendable {
    public var text: String
    public var attachments: [ComposerAttachment]

    public init(text: String = "", attachments: [ComposerAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    /// A draft is route-scoped when every attachment belongs to the same
    /// non-empty route and remains file-backed. Empty drafts are valid for any
    /// route because they carry no transferable state.
    public var isRouteScoped: Bool {
        guard let first = attachments.first else { return true }
        guard first.fileURL.isFileURL, !first.routeIdentity.isEmpty else { return false }
        return attachments.allSatisfy {
            $0.fileURL.isFileURL && $0.routeIdentity == first.routeIdentity
        }
    }

    public var routeIdentity: String? {
        guard isRouteScoped else { return nil }
        return attachments.first?.routeIdentity
    }
}

public enum ComposerAttachmentLimits {
    public static let perItemBytes = 50 * 1024 * 1024
    public static let totalBytes = 100 * 1024 * 1024
    public static let imageBytes = 25 * 1024 * 1024
    public static let pdfBytes = 50 * 1024 * 1024
    public static let maximumItems = 8

    public static func ceiling(for kind: ComposerAttachment.Kind) -> Int {
        switch kind {
        case .image: return min(perItemBytes, imageBytes)
        case .pdf: return min(perItemBytes, pdfBytes)
        case .file, .audioRecording: return perItemBytes
        }
    }
}
