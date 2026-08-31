import Foundation
import HermternalCore
import Testing

@Test("capability decoding requires the exact purge endpoint contract")
func capabilityDecodeRequiresExactContract() throws {
    let data = Data("""
    {"features":{"session_purge":true},"endpoints":{"session_purge":{"method":"POST","path":"/api/sessions/purge","max_batch":500}}}
    """.utf8)
    let snapshot = try GatewayCapabilityModule.decode(data: data)
    #expect(snapshot.sessionPurge?.method == "POST")
    #expect(snapshot.sessionPurge?.path == "/api/sessions/purge")
    #expect(snapshot.sessionPurge?.maxBatch == 500)
}

@Test("capability decoding represents omitted and malformed purge capability")
func capabilityDecodeRepresentsOmittedAndMalformed() throws {
    let omitted = try GatewayCapabilityModule.decode(data: Data("""
    {"features":{"session_purge":false},"endpoints":{}}
    """.utf8))
    #expect(omitted.sessionPurge == nil)

    let malformed = Data("""
    {"features":{"session_purge":true},"endpoints":{"session_purge":{"method":"DELETE","path":"/api/sessions/x","max_batch":500}}}
    """.utf8)
    #expect(throws: GatewayCapabilityError.malformedSessionPurgeEndpoint) {
        try GatewayCapabilityModule.decode(data: malformed)
    }
}

@Test("purge confirmation is exact and never normalized")
func purgeConfirmationIsExact() {
    #expect(SessionPurgeConfirmation.isExact("delete"))
    #expect(!SessionPurgeConfirmation.isExact(" delete"))
    #expect(!SessionPurgeConfirmation.isExact("DELETE"))
}

@Test("purge policy de-duplicates targets and blocks the active stream")
func purgePolicyDeduplicatesAndGuardsActive() {
    let plan = SessionPurgePolicy.plan(
        selectedChatIDs: ["a", "a", "missing"],
        selectedFolderIDs: [],
        mode: .chatsOnly,
        membership: [:],
        visibleChatIDs: ["a"],
        activeSessionID: "a",
        isStreaming: true
    )
    #expect(plan.chatIDs == ["a"])
    #expect(plan.blockedByActiveStream)
}

@Test("purge policy keeps a folder when any contained target fails")
func purgePolicyPartialFolderKeepsMembership() {
    let result = SessionPurgeResult(
        object: "hermes.session.purge_result",
        complete: false,
        purged: ["ok"],
        retainedBranches: [],
        failed: [SessionPurgeFailure(id: "failed", code: "busy", message: "active")]
    )
    let reconciliation = SessionPurgePolicy.reconcile(
        requestedIDs: ["ok", "failed"],
        result: result,
        folderIDs: ["folder"],
        membership: ["ok": "folder", "failed": "folder"]
    )
    #expect(reconciliation.successfulIDs == Set(["ok"]))
    #expect(reconciliation.failedIDs == Set(["failed"]))
}

@Test("purge plan expands complete active and archived membership once")
func purgePlanCapturesArchivedMembershipAndCounts() {
    let active = ChatSession(from: .object([
        "id": .string("active"),
        "profile": .string("default")
    ]))
    let archived = ChatSession(from: .object([
        "id": .string("archived"),
        "archived": .bool(true),
        "profile": .string("default")
    ]))
    var membership = ["active": "folder", "archived": "folder"]
    let plan = SessionPurgePolicy.plan(
        selectedChatIDs: [],
        selectedFolderIDs: ["folder"],
        mode: .foldersAndChats,
        membership: membership,
        visibleChatIDs: [active.id, archived.id],
        activeSessionID: nil,
        isStreaming: false,
        authoritativeSessions: [active, archived]
    )
    membership["archived"] = "other"
    #expect(plan.chatIDs == ["active", "archived"])
    #expect(plan.sessions.map(\.id) == ["active", "archived"])
    #expect(plan.chatCount == 2)
    #expect(plan.folderCount == 1)
    #expect(plan.confirmationCount == 2)
    #expect(plan.folderMembership["archived"] == "folder")
}

@Test("Purge plan uses explicit folders without inferring containing folders")
func purgePlanHonorsExplicitFolderTargets() {
    let selectedChat = ChatSession(from: .object([
        "id": .string("selected-chat"),
        "profile": .string("default")
    ]))
    let folderChat = ChatSession(from: .object([
        "id": .string("folder-chat"),
        "profile": .string("default")
    ]))
    let unrelatedChat = ChatSession(from: .object([
        "id": .string("unrelated"),
        "profile": .string("default")
    ]))
    let plan = SessionPurgePolicy.plan(
        selectedChatIDs: ["selected-chat"],
        selectedFolderIDs: ["selected-folder"],
        mode: .foldersAndChats,
        membership: [
            "selected-chat": "unselected-containing-folder",
            "folder-chat": "selected-folder",
            "unrelated": "unselected-containing-folder"
        ],
        visibleChatIDs: ["selected-chat", "folder-chat", "unrelated"],
        activeSessionID: nil,
        isStreaming: false,
        authoritativeSessions: [selectedChat, folderChat, unrelatedChat]
    )

    #expect(plan.folderIDs == ["selected-folder"])
    #expect(plan.chatIDs == ["selected-chat", "folder-chat"])
    #expect(plan.folderCount == 1)
    #expect(plan.chatCount == 2)
    #expect(plan.confirmationCount == 2)
}

@Test("empty folder plan has no gateway chat target")
func emptyFolderPlanIsValid() {
    let plan = SessionPurgePolicy.plan(
        selectedChatIDs: [],
        selectedFolderIDs: ["empty"],
        mode: .foldersAndChats,
        membership: [:],
        visibleChatIDs: [],
        activeSessionID: nil,
        isStreaming: false
    )
    #expect(plan.isEmpty == false)
    #expect(plan.chatCount == 0)
    #expect(plan.folderCount == 1)
    #expect(plan.chatIDs.isEmpty)
}

@Test("purge phases reject a second start while active")
func purgePhasesRejectReentryEvents() {
    #expect(SessionPurgePolicy.canAccept(.idle, .beginPrepare))
    #expect(!SessionPurgePolicy.canAccept(.idle, .confirm))
    #expect(!SessionPurgePolicy.canAccept(.idle, .cancel))

    #expect(!SessionPurgePolicy.canAccept(.preparing, .beginPrepare))
    #expect(SessionPurgePolicy.canAccept(.preparing, .prepareSucceeded))
    #expect(SessionPurgePolicy.canAccept(.preparing, .prepareFailed))
    #expect(SessionPurgePolicy.canAccept(.preparing, .cancel))
    #expect(!SessionPurgePolicy.canAccept(.preparing, .confirm))

    let plan = SessionPurgePolicy.plan(
        selectedChatIDs: ["chat"],
        selectedFolderIDs: [],
        mode: .chatsOnly,
        membership: [:],
        visibleChatIDs: ["chat"],
        activeSessionID: nil,
        isStreaming: false
    )
    #expect(!SessionPurgePolicy.canAccept(.confirming(plan), .beginPrepare))
    #expect(SessionPurgePolicy.canAccept(.confirming(plan), .confirm))
    #expect(SessionPurgePolicy.canAccept(.confirming(plan), .cancel))
    #expect(!SessionPurgePolicy.canAccept(.confirming(plan), .executionFinished))

    #expect(!SessionPurgePolicy.canAccept(.executing(plan), .beginPrepare))
    #expect(!SessionPurgePolicy.canAccept(.executing(plan), .confirm))
    #expect(!SessionPurgePolicy.canAccept(.executing(plan), .cancel))
    #expect(SessionPurgePolicy.canAccept(.executing(plan), .executionFinished))
    #expect(!SessionPurgePhase.preparing.allowsNewCommand)
    #expect(SessionPurgePhase.idle.allowsNewCommand)
    #expect(SessionPurgePhase.preparing.showsProgress)
    #expect(SessionPurgePhase.executing(plan).showsProgress)
    #expect(!SessionPurgePhase.confirming(plan).showsProgress)
}
