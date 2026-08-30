import Foundation
import HermternalCore
import Testing

private func attachment(
    _ id: String,
    kind: ComposerAttachment.Kind = .file,
    bytes: Int = 1,
    route: String = "session-a"
) -> ComposerAttachment {
    ComposerAttachment(
        id: UUID(uuidString: id)!,
        kind: kind,
        displayName: "item",
        byteCount: bytes,
        fileURL: URL(fileURLWithPath: "/tmp/item-\(id)"),
        routeIdentity: route
    )
}

@Test("composer permits attachment-only sends and trims text")
func attachmentOnlySend() {
    let draft = ComposerDraft(text: "  ", attachments: [attachment("00000000-0000-0000-0000-000000000001")])
    let decision = ComposerSendPolicy.decide(draft: draft, isAwaitingReply: false, isReadOnlyTranscript: false)
    guard case let .send(submission) = decision else {
        Issue.record("Expected attachment-only draft to send")
        return
    }
    #expect(submission.text.isEmpty)
    #expect(submission.staging.count == 1)
    #expect(submission.clearsDraftImmediately)
}

@Test("composer staging groups image, PDF, and file while preserving order")
func stagingOrder() {
    let image = attachment("00000000-0000-0000-0000-000000000001", kind: .image)
    let file = attachment("00000000-0000-0000-0000-000000000002")
    let pdf = attachment("00000000-0000-0000-0000-000000000003", kind: .pdf)
    let secondImage = attachment("00000000-0000-0000-0000-000000000004", kind: .image)
    let draft = ComposerDraft(text: " hello ", attachments: [file, pdf, image, secondImage])
    guard case let .send(submission) = ComposerSendPolicy.decide(
        draft: draft, isAwaitingReply: false, isReadOnlyTranscript: false
    ) else {
        Issue.record("Expected valid draft to send")
        return
    }
    #expect(submission.text == "hello")
    #expect(submission.staging.map { $0.attachment.id } == [image.id, secondImage.id, pdf.id, file.id])
}

@Test("composer enforces item, total, count, and route limits")
func attachmentBoundaries() {
    let tooLargeImage = ComposerDraft(attachments: [attachment(
        "00000000-0000-0000-0000-000000000010", kind: .image,
        bytes: ComposerAttachmentLimits.imageBytes + 1
    )])
    #expect(ComposerSendPolicy.decide(draft: tooLargeImage, isAwaitingReply: false, isReadOnlyTranscript: false)
        == .rejected(.oversizeAttachment(id: tooLargeImage.attachments[0].id, limit: ComposerAttachmentLimits.imageBytes)))

    let atTotal = ComposerDraft(attachments: [
        attachment("00000000-0000-0000-0000-000000000011", bytes: ComposerAttachmentLimits.perItemBytes),
        attachment("00000000-0000-0000-0000-000000000012", bytes: ComposerAttachmentLimits.perItemBytes)
    ])
    guard case .send = ComposerSendPolicy.decide(draft: atTotal, isAwaitingReply: false, isReadOnlyTranscript: false) else {
        Issue.record("Expected exactly-total draft to send")
        return
    }

    let overTotal = ComposerDraft(attachments: atTotal.attachments + [attachment(
        "00000000-0000-0000-0000-000000000013", bytes: 1
    )])
    #expect(ComposerSendPolicy.decide(draft: overTotal, isAwaitingReply: false, isReadOnlyTranscript: false)
        == .rejected(.oversizeAttachment(id: overTotal.attachments[2].id, limit: ComposerAttachmentLimits.totalBytes)))

    let tooMany = ComposerDraft(attachments: (0..<9).map { attachment(
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\($0 + 20)")!.uuidString
    ) })
    #expect(ComposerSendPolicy.decide(draft: tooMany, isAwaitingReply: false, isReadOnlyTranscript: false)
        == .rejected(.tooManyAttachments(limit: ComposerAttachmentLimits.maximumItems)))

    let mixedRoute = ComposerDraft(attachments: [
        attachment("00000000-0000-0000-0000-000000000030"),
        attachment("00000000-0000-0000-0000-000000000031", route: "session-b")
    ])
    #expect(ComposerSendPolicy.decide(draft: mixedRoute, isAwaitingReply: false, isReadOnlyTranscript: false)
        == .rejected(.invalidRoute))

    let emptyRoute = ComposerDraft(attachments: [
        attachment("00000000-0000-0000-0000-000000000032", route: "")
    ])
    #expect(ComposerSendPolicy.decide(draft: emptyRoute, isAwaitingReply: false, isReadOnlyTranscript: false)
        == .rejected(.invalidRoute))

    let nonFile = ComposerAttachment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!,
        kind: .file,
        displayName: "remote",
        byteCount: 1,
        fileURL: URL(string: "https://example.invalid/file")!,
        routeIdentity: "session-a"
    )
    let nonFileDraft = ComposerDraft(attachments: [nonFile])
    #expect(ComposerSendPolicy.decide(draft: nonFileDraft, isAwaitingReply: false, isReadOnlyTranscript: false)
        == .rejected(.invalidRoute))
}

@Test("composer rejects empty, read-only, and awaiting drafts")
func sendRejections() {
    #expect(ComposerSendPolicy.decide(draft: ComposerDraft(), isAwaitingReply: false, isReadOnlyTranscript: false)
        == .rejected(.emptyDraft))
    let draft = ComposerDraft(text: "hello")
    #expect(ComposerSendPolicy.decide(draft: draft, isAwaitingReply: true, isReadOnlyTranscript: false)
        == .rejected(.awaitingReply))
    #expect(ComposerSendPolicy.decide(draft: draft, isAwaitingReply: false, isReadOnlyTranscript: true)
        == .rejected(.readOnlyTranscript))
}

@Test("composer appends file references and restores newer edits")
func referencesAndRestore() {
    #expect(ComposerSendPolicy.submissionText(trimmed: "hello", fileReferences: [" @file:a ", "", "@file:b"]) == "hello\n@file:a\n@file:b")
    #expect(ComposerSendPolicy.submissionText(trimmed: "", fileReferences: ["@file:a"]) == "@file:a")

    let first = attachment("00000000-0000-0000-0000-000000000040")
    let second = attachment("00000000-0000-0000-0000-000000000041")
    let submitted = ComposerDraft(text: "original", attachments: [first])
    let newer = ComposerDraft(text: "new", attachments: [first, second])
    let restored = ComposerSendPolicy.restore(submitted, into: newer)
    #expect(restored.text == "original\nnew")
    #expect(restored.attachments.map(\.id) == [first.id, second.id])
}

@Test("gateway file references are strict and bounded")
func strictReferenceGrammar() {
    #expect(ComposerSendPolicy.validatedReferenceText("@file:uploads/item.txt") == "@file:uploads/item.txt")
    #expect(ComposerSendPolicy.validatedReferenceText("@file:/tmp/item.txt") == nil)
    #expect(ComposerSendPolicy.validatedReferenceText("@file:../item.txt") == nil)
    #expect(ComposerSendPolicy.validatedReferenceText("@file:uploads//item.txt") == nil)
    #expect(ComposerSendPolicy.validatedReferenceText("@file:uploads/item\n.txt") == nil)
    #expect(ComposerSendPolicy.validatedReferenceText("@file:uploads/item with spaces.txt") == nil)
    #expect(ComposerSendPolicy.validatedReferenceText("@file:") == nil)
    #expect(ComposerSendPolicy.validatedReferenceText("@file:" + String(repeating: "a", count: 507)) == nil)
}

@Test("attachment names are deterministic and do not trust display names")
func deterministicAttachmentName() {
    let item = attachment(
        "00000000-0000-0000-0000-000000000099",
        kind: .file
    )
    let name = ComposerSendPolicy.deterministicAttachmentName(for: item)
    #expect(name == "attachment-00000000-0000-0000-0000-000000000099")
    #expect(ComposerSendPolicy.deterministicAttachmentName(for: item) == name)
}

@Test("staging receipts preserve route identity and truthful rollback state")
func stagingReceiptContract() {
    let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!
    let receipt = AttachmentStagingReceipt(
        id: id,
        sessionID: "live-session",
        routeIdentity: "route-token",
        deterministicName: "attachment-\(id.uuidString.lowercased())",
        serverReference: "@file:uploads/a.txt",
        serverPath: nil,
        outcome: .staged,
        rollbackSupport: .unsupported(reason: "gateway has no file.detach")
    )
    #expect(receipt.sessionID == "live-session")
    #expect(receipt.routeIdentity == "route-token")
    #expect(receipt.outcome == .staged)
    #expect(receipt.rollbackSupport == .unsupported(reason: "gateway has no file.detach"))
    let batch = AttachmentStagingBatchReceipt(
        transactionID: UUID(),
        sessionID: receipt.sessionID,
        routeIdentity: receipt.routeIdentity,
        items: [receipt],
        state: .outcomeUnknown
    )
    let result = AttachmentCompensationResult.residual(
        batch, unsupported: [id], unknown: []
    )
    if case .residual(_, let unsupported, let unknown) = result {
        #expect(unsupported == [id])
        #expect(unknown.isEmpty)
    } else {
        Issue.record("Expected residual compensation state")
    }
}

@Test("batch failures expose stable reason without transport details")
func batchFailureContract() {
    let failure = AttachmentStagingBatchFailure(
        reason: .outcomeUnknown,
        batch: nil,
        compensation: nil
    )
    #expect(failure.reason == .outcomeUnknown)
    #expect(failure.batch == nil)
    #expect(failure.compensation == nil)
    #expect(failure.errorDescription == "Attachment staging outcome is unknown.")
}
