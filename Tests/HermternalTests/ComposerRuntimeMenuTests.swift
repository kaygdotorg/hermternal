import Foundation
import HermternalCore
import Observation
import Testing
@testable import Hermternal

private let runtimeMenuInventory = ModelInventory(providers: [
    .init(
        slug: "test",
        name: "Test Provider",
        isCurrent: true,
        models: ["alpha", "beta"],
        capabilities: [
            "alpha": ModelCapabilities(
                supportsFast: true,
                supportsReasoning: true,
                canDisableReasoning: true
            ),
            "beta": ModelCapabilities(
                supportsFast: true,
                supportsReasoning: false
            )
        ]
    )
])

@Test("Runtime menu eligibility uses writable routes")
@MainActor
func runtimeMenuEligibilityTruthTable() async {
    let runtime = RuntimeMenuSpy()
    let cases: [(route: ComposerRoute, eligible: Bool, reason: String?)] = [
        (
            ComposerRoute(identity: "runtime-menu-eligibility-durable", liveSessionID: nil),
            true,
            nil
        ),
        (
            ComposerRoute(identity: "new", liveSessionID: nil),
            true,
            nil
        ),
        (
            ComposerRoute(identity: "runtime-menu-eligibility-read-only", liveSessionID: nil, isReadOnly: true),
            false,
            "This transcript is read only."
        )
    ]

    for entry in cases {
        let model = makeRuntimeMenuModel(route: entry.route, runtime: runtime)
        #expect(model.canChangeRuntime == entry.eligible)
        #expect(model.runtimeDisabledReason == entry.reason)
    }

    let durableWithDraft = makeRuntimeMenuModel(
        route: ComposerRoute(identity: "runtime-menu-draft", liveSessionID: nil),
        runtime: runtime
    )
    durableWithDraft.text = "Unsent draft"
    #expect(durableWithDraft.canChangeRuntime)

    let pendingRuntime = RuntimeMenuSpy(blockModelChanges: true)
    let pendingCompletion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let pending = makeRuntimeMenuModel(
        route: ComposerRoute(identity: "runtime-menu-pending", liveSessionID: "live"),
        runtime: pendingRuntime,
        operationCompletion: pendingCompletion
    )
    pending.selectModel("alpha", provider: "test")
    await pendingRuntime.waitForModelChange()
    #expect(!pending.canChangeRuntime)
    #expect(pending.runtimeDisabledReason == "The last change is still going out.")
    await pendingRuntime.releaseModelChange()
    await pendingCompletion.wait()

    let unsupportedRuntime = RuntimeMenuSpy()
    let unsupportedCompletion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let unsupported = makeRuntimeMenuModel(
        route: ComposerRoute(
            identity: "runtime-menu-unsupported",
            liveSessionID: "live",
            runtime: SessionRuntimeSnapshot(
                model: "beta",
                provider: "test",
                reasoning: nil,
                isRunning: false
            )
        ),
        runtime: unsupportedRuntime,
        operationCompletion: unsupportedCompletion
    )
    unsupported.loadModels()
    await unsupportedRuntime.waitForInventory()
    await unsupportedCompletion.wait()
    #expect(unsupported.reasoningOptions.unavailableReason == "beta does not support reasoning.")
}

@Test("A new chat prepares a live session for model menus")
@MainActor
func newChatPreparesLiveSessionForRuntimeMenus() async {
    let runtime = RuntimeMenuSpy()
    let turn = RuntimeMenuTurnSpy(sessionID: "live-new", blocksPreparation: true)
    let operationCompletion = RuntimeMenuOperationCompletion(expectedCount: 2)
    let route = ComposerRoute(identity: "new", generation: 3, liveSessionID: nil)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: runtime,
        turn: turn,
        operationCompletion: operationCompletion
    )

    #expect(model.canChangeRuntime)
    #expect(model.runtimeDisabledReason == nil)

    model.loadModels()
    model.selectModel("alpha", provider: "test")

    await turn.waitForPreparation()
    #expect(turn.prepareRequests == [route.token])

    turn.finishPreparation()
    await runtime.waitForInventory()
    await runtime.waitForModelChange()
    await operationCompletion.wait()

    #expect(turn.prepareRequests == [route.token])
    #expect(await runtime.inventorySessionIDs() == ["live-new"])
    #expect(await runtime.modelSessionIDs() == ["live-new"])
    #expect(model.inventory == .loaded(runtimeMenuInventory))
    #expect(model.modelSelection.pending == "alpha")
    #expect(model.canChangeRuntime)
}

@Test("Send publishes the user turn before session preparation")
@MainActor
func sendPublishesUserTurnBeforePreparation() async {
    let turn = RuntimeMenuTurnSpy(sessionID: "live", blocksPreparation: true)
    let completion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let route = ComposerRoute(identity: "publish-before-prepare", generation: 4)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: completion
    )

    model.text = "Hello bubble"
    model.submit()

    #expect(turn.publishedTexts == ["Hello bubble"])
    #expect(turn.publishedRoutes == [route.token])
    #expect(model.text.isEmpty)

    turn.finishPreparation()
    await turn.waitForSubmission()
    await completion.wait()
    #expect(turn.rolledBackRoutes.isEmpty)
}

@Test("Send rolls back the published turn when preparation fails")
@MainActor
func sendRollsBackPublishedTurnOnPreparationFailure() async {
    let turn = RuntimeMenuTurnSpy(
        sessionID: "live",
        prepareFailure: .unroutableFrame("Composer route changed.")
    )
    let completion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let route = ComposerRoute(identity: "rollback-on-prepare", generation: 5)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: completion
    )

    model.text = "Keep this draft"
    model.submit()
    await completion.wait()

    #expect(turn.publishedTexts == ["Keep this draft"])
    #expect(turn.rolledBackRoutes == [route.token])
    #expect(model.text == "Keep this draft")
    #expect(turn.submissionSessionIDs.isEmpty)
}

@Test("Escape during an in-flight send restores the draft")
@MainActor
func escapeDuringInFlightSendRestoresDraft() async {
    let turn = RuntimeMenuTurnSpy(sessionID: "live", blocksPreparation: true)
    let completion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let route = ComposerRoute(identity: "escape-during-send", generation: 6)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: completion
    )
    _ = model.mount()
    model.text = "please cancel me"
    model.submit()
    #expect(turn.publishedTexts == ["please cancel me"])
    #expect(model.text.isEmpty)
    #expect(model.isSubmitting)
    #expect(model.handleEscape())
    #expect(model.text == "please cancel me")
    #expect(!model.isSubmitting)
    #expect(turn.rolledBackRoutes == [route.token])

    turn.finishPreparation()
    await completion.wait()
    #expect(model.text == "please cancel me")
    #expect(!model.isSubmitting)
    #expect(turn.submissionSessionIDs.isEmpty)
}

@Test("Shutdown during an in-flight send does not restore into later text")
@MainActor
func shutdownDuringInFlightSendDoesNotRestoreIntoLaterText() async {
    let turn = RuntimeMenuTurnSpy(sessionID: "live", blocksPreparation: true)
    let completion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let route = ComposerRoute(identity: "shutdown-during-send", generation: 7)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: completion
    )
    _ = model.mount()
    model.text = "overlap"
    model.submit()
    #expect(turn.publishedTexts == ["overlap"])
    model.shutdown()
    model.text = "after shutdown"
    model.submit()
    turn.finishPreparation()
    await completion.wait()
    #expect(model.text == "after shutdown")
    #expect(!model.isSubmitting)
}

@Test("Adopting the new chat keeps the in-flight send")
@MainActor
func adoptingNewChatKeepsInFlightSend() async {
    let turn = RuntimeMenuTurnSpy(sessionID: "live", blocksPreparation: true)
    let completion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let newRoute = ComposerRoute(identity: "new", generation: 1, liveSessionID: "live")
    let adopted = ComposerRoute(identity: "live", generation: 2, liveSessionID: "live")
    let model = makeRuntimeMenuModel(
        route: newRoute,
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: completion
    )

    model.text = "First prompt"
    model.submit()
    #expect(turn.publishedTexts == ["First prompt"])

    await turn.waitForPreparation()
    model.update(route: adopted)
    #expect(model.text.isEmpty)

    turn.finishPreparation()
    await turn.waitForSubmission()
    await completion.wait()

    #expect(turn.rolledBackRoutes.isEmpty)
    #expect(turn.submissionSessionIDs == ["live"])
    #expect(model.text.isEmpty)
}

@Test("Adopting the new chat keeps inventory and pending model")
@MainActor
func adoptingNewChatKeepsInventoryAndPendingModel() async {
    let runtime = RuntimeMenuSpy()
    let completion = RuntimeMenuOperationCompletion(expectedCount: 2)
    let newRoute = ComposerRoute(identity: "new", generation: 1, liveSessionID: "live")
    let adopted = ComposerRoute(identity: "live", generation: 2, liveSessionID: "live")
    let model = makeRuntimeMenuModel(
        route: newRoute,
        runtime: runtime,
        operationCompletion: completion
    )

    _ = model.mount()
    model.selectModel("alpha", provider: "test")
    await runtime.waitForInventory()
    await runtime.waitForModelChange()
    await completion.wait()
    #expect(model.inventory == .loaded(runtimeMenuInventory))
    #expect(model.modelSelection.pending == "alpha")

    model.update(route: adopted)
    #expect(model.inventory == .loaded(runtimeMenuInventory))
    #expect(model.modelSelection.pending == "alpha")
    #expect(await runtime.inventorySessionIDs() == ["live"])
}

@Test("Mount prefetches inventory and restores it from cache")
@MainActor
func mountPrefetchesAndCachesInventory() async {
    let runtime = RuntimeMenuSpy()
    let turn = RuntimeMenuTurnSpy(sessionID: "prepared-live")
    let completion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let route = ComposerRoute(
        identity: "prefetch-inventory",
        generation: 6,
        liveSessionID: "live",
        runtime: SessionRuntimeSnapshot(
            model: "alpha",
            provider: "test",
            reasoning: .effort(.medium),
            isRunning: false
        )
    )
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: runtime,
        turn: turn,
        operationCompletion: completion
    )

    #expect(model.inventory == .notLoaded)
    #expect(model.reasoningOptions.choices == [.effort(.medium)])
    #expect(model.reasoningOptions.unavailableReason == nil)

    let firstMount = model.mount()
    await runtime.waitForInventory()
    await completion.wait()

    #expect(model.inventory == .loaded(runtimeMenuInventory))
    #expect(model.reasoningOptions.choices.contains(.off))
    #expect(model.reasoningOptions.choices.contains(.effort(.medium)))
    #expect(model.reasoningOptions.current == .effort(.medium))
    #expect(turn.prepareRequests.isEmpty)
    model.loadModels()
    #expect(turn.prepareRequests.isEmpty)

    model.unmount(firstMount)
    model.update(route: ComposerRoute(identity: "other-prefetch", generation: 7, liveSessionID: "other"))
    #expect(model.inventory == .notLoaded)

    model.update(route: route)
    _ = model.mount()
    #expect(model.inventory == .loaded(runtimeMenuInventory))
    #expect(await runtime.inventorySessionIDs() == ["live"])
    #expect(turn.prepareRequests.isEmpty)
}

@Test("Browse prefetch loads inventory without preparing a session")
@MainActor
func browsePrefetchDoesNotPrepareSession() async {
    let runtime = RuntimeMenuSpy()
    let turn = RuntimeMenuTurnSpy(sessionID: "prepared-live")
    let completion = RuntimeMenuOperationCompletion(expectedCount: 3)
    let first = ComposerRoute(identity: "browse-first", generation: 30)
    let second = ComposerRoute(identity: "browse-second", generation: 31)
    let model = makeRuntimeMenuModel(
        route: first,
        runtime: runtime,
        turn: turn,
        operationCompletion: completion
    )

    _ = model.mount()
    await runtime.waitForInventory()
    await completion.wait(for: 1)
    #expect(turn.prepareRequests.isEmpty)
    #expect(await runtime.inventorySessionIDs() == [nil])
    #expect(model.inventory == .loaded(runtimeMenuInventory))
    model.loadModels()
    #expect(turn.prepareRequests.isEmpty)

    model.update(route: second)
    await runtime.waitForInventory(count: 2)
    await completion.wait(for: 2)
    #expect(turn.prepareRequests.isEmpty)
    #expect(await runtime.inventorySessionIDs() == [nil, nil])
    #expect(model.inventory == .loaded(runtimeMenuInventory))

    model.text = "Send now"
    model.submit()
    await turn.waitForSubmission()
    await completion.wait()
    #expect(turn.prepareRequests == [second.token])
    #expect(turn.submissionSessionIDs == ["prepared-live"])
}

@Test("Concurrent inventory, model, and send share preparation")
@MainActor
func concurrentInventoryModelAndSendSharePreparation() async {
    let runtime = RuntimeMenuSpy()
    let turn = RuntimeMenuTurnSpy(sessionID: "live", blocksPreparation: true)
    let operationCompletion = RuntimeMenuOperationCompletion(expectedCount: 3)
    let route = ComposerRoute(identity: "runtime-menu-concurrent-model", generation: 7)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: runtime,
        turn: turn,
        operationCompletion: operationCompletion
    )

    model.text = "Message"
    model.loadModels()
    model.selectModel("alpha", provider: "test")
    model.submit()

    await turn.waitForPreparation()
    #expect(turn.prepareRequests == [route.token])

    turn.finishPreparation()
    await runtime.waitForInventory()
    await runtime.waitForModelChange()
    await turn.waitForSubmission()
    await operationCompletion.wait()

    #expect(turn.prepareRequests == [route.token])
    #expect(await runtime.inventorySessionIDs() == ["live"])
    #expect(await runtime.modelSessionIDs() == ["live"])
    #expect(turn.submissionSessionIDs == ["live"])
}

@Test("Concurrent inventory, reasoning, and send share preparation")
@MainActor
func concurrentInventoryReasoningAndSendSharePreparation() async {
    let runtime = RuntimeMenuSpy()
    let turn = RuntimeMenuTurnSpy(sessionID: "live", blocksPreparation: true)
    let operationCompletion = RuntimeMenuOperationCompletion(expectedCount: 3)
    let route = ComposerRoute(identity: "runtime-menu-concurrent-reasoning", generation: 8)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: runtime,
        turn: turn,
        operationCompletion: operationCompletion
    )

    model.text = "Message"
    model.loadModels()
    model.selectReasoning(.effort(.high))
    model.submit()

    await turn.waitForPreparation()
    #expect(turn.prepareRequests == [route.token])

    turn.finishPreparation()
    await runtime.waitForInventory()
    await runtime.waitForReasoningChange()
    await turn.waitForSubmission()
    await operationCompletion.wait()

    #expect(turn.prepareRequests == [route.token])
    #expect(await runtime.inventorySessionIDs() == ["live"])
    #expect(await runtime.reasoningSessionIDs() == ["live"])
    #expect(turn.submissionSessionIDs == ["live"])
}

@Test("Runtime selections retain their route token")
@MainActor
func runtimeSelectionsRejectRouteChanges() async {
    let staleModelRuntime = RuntimeMenuSpy()
    let staleModelTurn = RuntimeMenuTurnSpy(sessionID: "live", blocksPreparation: true)
    let staleModelCompletion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let staleModel = makeRuntimeMenuModel(
        route: ComposerRoute(identity: "runtime-menu-stale-model-first", generation: 1),
        runtime: staleModelRuntime,
        turn: staleModelTurn,
        operationCompletion: staleModelCompletion
    )

    staleModel.selectModel("alpha", provider: "test")
    await staleModelTurn.waitForPreparation()
    staleModel.update(route: ComposerRoute(identity: "runtime-menu-stale-model-second", generation: 2))
    staleModelTurn.finishPreparation()
    await staleModelCompletion.wait()

    #expect(await staleModelRuntime.modelSessionIDs().isEmpty)

    let staleReasoningRuntime = RuntimeMenuSpy()
    let staleReasoningTurn = RuntimeMenuTurnSpy(sessionID: "live", blocksPreparation: true)
    let staleReasoningCompletion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let staleReasoning = makeRuntimeMenuModel(
        route: ComposerRoute(identity: "runtime-menu-stale-reasoning-first", generation: 1),
        runtime: staleReasoningRuntime,
        turn: staleReasoningTurn,
        operationCompletion: staleReasoningCompletion
    )

    staleReasoning.selectReasoning(.effort(.high))
    await staleReasoningTurn.waitForPreparation()
    staleReasoning.update(route: ComposerRoute(identity: "runtime-menu-stale-reasoning-second", generation: 2))
    staleReasoningTurn.finishPreparation()
    await staleReasoningCompletion.wait()

    #expect(await staleReasoningRuntime.reasoningSessionIDs().isEmpty)
}

@Test("A read-only transition blocks runtime requests after preparation")
@MainActor
func readOnlyRouteRejectsRuntimeRequestsAfterPreparation() async {
    let modelRuntime = RuntimeMenuSpy()
    let modelTurn = RuntimeMenuTurnSpy(sessionID: "live", blocksPreparation: true)
    let modelCompletion = RuntimeMenuOperationCompletion(expectedCount: 3)
    let modelRoute = ComposerRoute(identity: "runtime-menu-read-only-model", generation: 9)
    let model = makeRuntimeMenuModel(
        route: modelRoute,
        runtime: modelRuntime,
        turn: modelTurn,
        operationCompletion: modelCompletion
    )

    model.text = "Message"
    model.loadModels()
    model.selectModel("alpha", provider: "test")
    model.submit()

    await modelTurn.waitForPreparation()
    model.update(route: ComposerRoute(identity: "runtime-menu-read-only-model", generation: 9, isReadOnly: true))
    modelTurn.finishPreparation()
    await modelCompletion.wait()

    #expect(modelTurn.prepareRequests == [modelRoute.token])
    #expect(await modelRuntime.inventorySessionIDs().isEmpty)
    #expect(await modelRuntime.modelSessionIDs().isEmpty)
    #expect(await modelRuntime.reasoningSessionIDs().isEmpty)
    #expect(modelTurn.submissionSessionIDs.isEmpty)

    let reasoningRuntime = RuntimeMenuSpy()
    let reasoningTurn = RuntimeMenuTurnSpy(sessionID: "live", blocksPreparation: true)
    let reasoningCompletion = RuntimeMenuOperationCompletion(expectedCount: 3)
    let reasoningRoute = ComposerRoute(identity: "runtime-menu-read-only-reasoning", generation: 10)
    let reasoning = makeRuntimeMenuModel(
        route: reasoningRoute,
        runtime: reasoningRuntime,
        turn: reasoningTurn,
        operationCompletion: reasoningCompletion
    )

    reasoning.text = "Message"
    reasoning.loadModels()
    reasoning.selectReasoning(.effort(.high))
    reasoning.submit()

    await reasoningTurn.waitForPreparation()
    reasoning.update(route: ComposerRoute(identity: "runtime-menu-read-only-reasoning", generation: 10, isReadOnly: true))
    reasoningTurn.finishPreparation()
    await reasoningCompletion.wait()

    #expect(reasoningTurn.prepareRequests == [reasoningRoute.token])
    #expect(await reasoningRuntime.inventorySessionIDs().isEmpty)
    #expect(await reasoningRuntime.modelSessionIDs().isEmpty)
    #expect(await reasoningRuntime.reasoningSessionIDs().isEmpty)
    #expect(reasoningTurn.submissionSessionIDs.isEmpty)
}

@Test("A replacement preparation invalidates old consumers after read-only toggle")
@MainActor
func replacementPreparationInvalidatesOldConsumers() async {
    let runtime = RuntimeMenuSpy()
    let turn = RuntimeMenuTurnSpy(sessionID: "live", blocksPreparation: true)
    let completion = RuntimeMenuOperationCompletion(expectedCount: 4)
    let route = ComposerRoute(identity: "runtime-menu-replacement", generation: 11)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: runtime,
        turn: turn,
        operationCompletion: completion
    )

    model.text = "Old message"
    model.loadModels()
    model.selectModel("alpha", provider: "test")
    model.submit()
    await turn.waitForPreparation()

    model.update(route: ComposerRoute(identity: "runtime-menu-replacement", generation: 11, isReadOnly: true))
    model.update(route: route)
    model.loadModels()
    await turn.waitForPreparation(count: 2)

    turn.finishPreparation()
    await completion.wait(for: 3)

    #expect(model.text == "Old message")
    #expect(await runtime.inventorySessionIDs().isEmpty)
    #expect(await runtime.modelSessionIDs().isEmpty)
    #expect(await runtime.reasoningSessionIDs().isEmpty)
    #expect(turn.submissionSessionIDs.isEmpty)

    turn.finishPreparation()
    await runtime.waitForInventory()
    await completion.wait()
}

@Test("A same-token invalidation restores a staged draft before acceptance")
@MainActor
func sameTokenInvalidationRestoresDraftAndCompensatesAttachmentStaging() async throws {
    let directory = try runtimeMenuTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "attachment.txt")
    try Data("Temporary attachment".utf8).write(to: source)

    let route = ComposerRoute(identity: "backup-runtime-menu-preaccept", generation: 12)
    let transaction = RuntimeMenuAttachmentTransaction(
        sessionID: "live",
        routeIdentity: route.identity,
        blocksSnapshot: true
    )
    let turn = RuntimeMenuTurnSpy(sessionID: "live")
    let operationCompletion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: operationCompletion,
        attachmentStaging: RuntimeMenuAttachmentStaging(transaction: transaction),
        draftStorage: RuntimeMenuDraftStorage(root: directory)
    )

    model.text = "Draft text"
    let ingestion = try #require(
        model.attach([ComposerAttachmentSource.temporary(source)], target: route.token)
    )
    await ingestion.value
    let attachment = try #require(model.attachments.first)
    #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path))

    model.submit()
    await transaction.waitForSnapshot()
    model.update(
        route: ComposerRoute(
            identity: route.identity,
            generation: route.generation,
            isReadOnly: true
        )
    )
    #expect(model.route.token == route.token)
    await transaction.releaseSnapshot()
    await transaction.waitForCompensation()
    await operationCompletion.wait()

    #expect(model.text == "Draft text")
    #expect(model.attachments.map { (restored: ComposerAttachment) in restored.id } == [attachment.id])
    #expect(await transaction.compensationCount() == 1)
    #expect(await transaction.commitCount() == 0)
    #expect(turn.submissionSessionIDs.isEmpty)
}

@Test("A superseded pre-acceptance send preserves its draft without clearing replacement state")
@MainActor
func supersededPreacceptanceSendPreservesDraftAndReplacementState() async throws {
    let directory = try runtimeMenuTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "attachment.txt")
    let replacementSource = directory.appending(path: "replacement.txt")
    try Data("Temporary attachment".utf8).write(to: source)
    try Data("Replacement attachment".utf8).write(to: replacementSource)

    let route = ComposerRoute(identity: "replacement-preaccept", generation: 21)
    let transaction = RuntimeMenuAttachmentTransaction(
        sessionID: "live",
        routeIdentity: route.identity,
        blocksSnapshot: true
    )
    let turn = RuntimeMenuTurnSpy(sessionID: "live")
    let completion = RuntimeMenuOperationCompletion(expectedCount: 2)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: completion,
        attachmentStaging: RuntimeMenuAttachmentStaging(transaction: transaction),
        draftStorage: RuntimeMenuDraftStorage(root: directory)
    )

    model.text = "A draft"
    let ingestion = try #require(
        model.attach([ComposerAttachmentSource.temporary(source)], target: route.token)
    )
    await ingestion.value
    let attachment = try #require(model.attachments.first)
    model.submit()
    await transaction.waitForSnapshot()

    model.update(route: ComposerRoute(
        identity: route.identity,
        generation: route.generation,
        isReadOnly: true
    ))
    model.update(route: route)
    model.text = "B replacement"
    model.submit()
    await turn.waitForSubmission()
    await transaction.releaseSnapshot()
    await transaction.waitForCompensation()
    await completion.wait()

    #expect(model.text.isEmpty)
    #expect(model.attachments.isEmpty)
    #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path))
    #expect(await transaction.compensationCount() == 1)
    #expect(turn.submissionSessionIDs == ["live"])
    model.text = "C draft"
    let replacementIngestion = try #require(
        model.attach([ComposerAttachmentSource.temporary(replacementSource)], target: route.token)
    )
    await replacementIngestion.value
    let replacementAttachment = try #require(model.attachments.first)
    model.update(route: ComposerRoute(identity: "other-replacement", generation: 22))
    model.update(route: route)
    #expect(model.text.contains("A draft"))
    #expect(model.text.contains("C draft"))
    #expect(Set(model.attachments.map(\.id)) == Set([attachment.id, replacementAttachment.id]))
}

@Test("An accepted attachment submit never restores a draft")
@MainActor
func acceptedAttachmentSubmitDoesNotRestoreDraftAfterReadOnlyTransition() async throws {
    let directory = try runtimeMenuTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "attachment.txt")
    try Data("Temporary attachment".utf8).write(to: source)

    let route = ComposerRoute(identity: "backup-runtime-menu-accepted", generation: 13)
    let transaction = RuntimeMenuAttachmentTransaction(
        sessionID: "live",
        routeIdentity: route.identity,
        blocksCommit: true
    )
    let turn = RuntimeMenuTurnSpy(sessionID: "live")
    let operationCompletion = RuntimeMenuOperationCompletion(expectedCount: 2)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: operationCompletion,
        attachmentStaging: RuntimeMenuAttachmentStaging(transaction: transaction),
        draftStorage: RuntimeMenuDraftStorage(root: directory)
    )

    model.text = "Accepted text"
    let ingestion = try #require(
        model.attach([ComposerAttachmentSource.temporary(source)], target: route.token)
    )
    await ingestion.value
    let attachment = try #require(model.attachments.first)
    #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path))

    model.submit()
    await turn.waitForSubmission()
    await transaction.waitForCommit()
    model.update(
        route: ComposerRoute(
            identity: route.identity,
            generation: route.generation,
            isReadOnly: true
        )
    )
    #expect(model.route.token == route.token)
    model.update(route: route)
    model.text = "Replacement text"
    model.submit()
    await transaction.releaseCommit()
    await transaction.waitForCommitCompletion()
    await operationCompletion.wait()

    #expect(model.text.isEmpty)
    #expect(model.attachments.isEmpty)
    #expect(model.outgoing.isEmpty)
    #expect(!model.isSubmitting)
    #expect(!FileManager.default.fileExists(atPath: attachment.fileURL.path))
    #expect(await transaction.commitCount() == 1)
    #expect(await transaction.compensationCount() == 0)
    #expect(turn.submissionSessionIDs == ["live", "live"])
}

@Test("An unknown gateway submit outcome restores the draft without retrying")
@MainActor
func unknownGatewaySubmitOutcomeRestoresDraftWithoutRetrying() async {
    let route = ComposerRoute(identity: "gateway-outcome-unknown", generation: 25)
    let turn = RuntimeMenuTurnSpy(
        sessionID: "live",
        submitFailure: .outcomeUnknownAfterSend
    )
    let completion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: completion
    )

    model.text = "May have been delivered"
    model.submit()
    await turn.waitForSubmission()
    await completion.wait()

    #expect(turn.submissionSessionIDs == ["live"])
    #expect(model.text == "May have been delivered")
    #expect(model.notice?.message == "The message may have been sent and was not retried.")
}

@Test("A pre-send route change restores the draft with no-send notice")
@MainActor
func preSendRouteChangeRestoresDraftWithNoSendNotice() async {
    let route = ComposerRoute(identity: "gateway-route-changed", generation: 26)
    let turn = RuntimeMenuTurnSpy(
        sessionID: "live",
        submitFailure: .unroutableFrame("route changed")
    )
    let completion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: completion
    )

    model.text = "Not sent"
    model.submit()
    await turn.waitForSubmission()
    await completion.wait()

    #expect(turn.submissionSessionIDs == ["live"])
    #expect(model.text == "Not sent")
    #expect(model.notice?.message == "The chat changed before the message was sent.")
}

@Test("An uncertain preparation restores the draft without submitting the prompt")
@MainActor
func uncertainPreparationRestoresDraftWithoutSubmittingPrompt() async {
    let route = ComposerRoute(identity: "gateway-preparation-unknown", generation: 27)
    let turn = RuntimeMenuTurnSpy(
        sessionID: "live",
        prepareFailure: .outcomeUnknownAfterSend
    )
    let completion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: completion
    )

    model.text = "Not submitted"
    model.submit()
    await turn.waitForPreparation()
    await completion.wait()

    #expect(turn.submissionSessionIDs.isEmpty)
    #expect(model.text == "Not submitted")
    #expect(model.notice?.message == "The chat setup could not be confirmed; the message was not sent.")
}

@Test("An inactive route restores its send notice when remounted")
@MainActor
func inactiveRouteRestoresSendNoticeWhenRemounted() async {
    let routeA = ComposerRoute(identity: "gateway-notice-source", generation: 28)
    let routeB = ComposerRoute(identity: "gateway-notice-destination", generation: 29)
    let remountedRouteA = ComposerRoute(identity: routeA.identity, generation: 30)
    let turn = RuntimeMenuTurnSpy(
        sessionID: "live",
        blocksPreparation: true,
        prepareFailure: .outcomeUnknownAfterSend
    )
    let completion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let model = makeRuntimeMenuModel(
        route: routeA,
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: completion
    )

    model.text = "Restore with notice"
    model.submit()
    await turn.waitForPreparation()
    model.update(route: routeB)
    turn.finishPreparation()
    await completion.wait()

    #expect(turn.submissionSessionIDs.isEmpty)
    #expect(model.notice == nil)
    model.update(route: remountedRouteA)
    #expect(model.text == "Restore with notice")
    #expect(model.notice?.message == "The chat setup could not be confirmed; the message was not sent.")
}

@Test("Accepted attachment failures discard staged drafts")
@MainActor
func acceptedAttachmentFailuresDiscardStagedDrafts() async throws {
    let directory = try runtimeMenuTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cases: [(name: String, commitOutcome: RuntimeMenuCommitOutcome)] = [
        ("generic", .failure),
        ("uncertain", .residual)
    ]

    for entry in cases {
        let caseDirectory = directory.appending(path: entry.name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
        let source = caseDirectory.appending(path: "\(entry.name).txt")
        try Data("Temporary attachment".utf8).write(to: source)
        let route = ComposerRoute(identity: "accepted-\(entry.name)-failure", generation: 24)
        let transaction = RuntimeMenuAttachmentTransaction(
            sessionID: "live",
            routeIdentity: route.identity,
            commitOutcome: entry.commitOutcome
        )
        let turn = RuntimeMenuTurnSpy(sessionID: "live")
        let completion = RuntimeMenuOperationCompletion(expectedCount: 1)
        let model = makeRuntimeMenuModel(
            route: route,
            runtime: RuntimeMenuSpy(),
            turn: turn,
            operationCompletion: completion,
            attachmentStaging: RuntimeMenuAttachmentStaging(transaction: transaction),
            draftStorage: RuntimeMenuDraftStorage(root: caseDirectory)
        )

        model.text = "Accepted text"
        let ingestion = try #require(
            model.attach([ComposerAttachmentSource.temporary(source)], target: route.token)
        )
        await ingestion.value
        let attachment = try #require(model.attachments.first)
        model.submit()
        await turn.waitForSubmission()
        await transaction.waitForCommit()
        await completion.wait()

        #expect(model.text.isEmpty)
        #expect(model.attachments.isEmpty)
        #expect(!model.isSubmitting)
        #expect(!FileManager.default.fileExists(atPath: attachment.fileURL.path))
        #expect(await transaction.commitCount() == 1)
        #expect(await transaction.compensationCount() == 0)
    }
}

@Test("A cross-token invalidation restores only the sending route")
@MainActor
func crossTokenInvalidationRestoresDraftAndCompensatesAttachmentStaging() async throws {
    let directory = try runtimeMenuTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "attachment.txt")
    try Data("Temporary attachment".utf8).write(to: source)

    let routeA = ComposerRoute(identity: "backup-runtime-menu-cross-a", generation: 14)
    let routeB = ComposerRoute(identity: "backup-runtime-menu-cross-b", generation: 15)
    let transaction = RuntimeMenuAttachmentTransaction(
        sessionID: "live",
        routeIdentity: routeA.identity,
        blocksSnapshot: true
    )
    let turn = RuntimeMenuTurnSpy(sessionID: "live")
    let operationCompletion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let model = makeRuntimeMenuModel(
        route: routeA,
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: operationCompletion,
        attachmentStaging: RuntimeMenuAttachmentStaging(transaction: transaction),
        draftStorage: RuntimeMenuDraftStorage(root: directory)
    )

    model.text = "Route A draft"
    let ingestion = try #require(
        model.attach([ComposerAttachmentSource.temporary(source)], target: routeA.token)
    )
    await ingestion.value
    let attachment = try #require(model.attachments.first)
    #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path))

    model.submit()
    await transaction.waitForSnapshot()
    model.update(route: routeB)
    model.text = "Route B draft"
    #expect(model.route.token == routeB.token)
    await transaction.releaseSnapshot()
    await operationCompletion.wait()

    #expect(await transaction.compensationCount() == 1)
    #expect(await transaction.commitCount() == 0)
    #expect(turn.submissionSessionIDs.isEmpty)
    #expect(model.text == "Route B draft")
    #expect(model.attachments.isEmpty)

    model.update(route: routeA)
    #expect(model.text == "Route A draft")
    #expect(model.attachments.map { (restored: ComposerAttachment) in restored.id } == [attachment.id])
}

@Test("Models that share a draft root use one startup sweep")
@MainActor
func sharedDraftRootUsesOneStartupSweepBeforeImports() async throws {
    let directory = try runtimeMenuTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstSource = directory.appending(path: "first.txt")
    let secondSource = directory.appending(path: "second.txt")
    try Data("First attachment".utf8).write(to: firstSource)
    try Data("Second attachment".utf8).write(to: secondSource)

    let sweep = RuntimeMenuSweepGate()
    let draftRoot = directory.appending(path: "drafts", directoryHint: .isDirectory)
    let firstStorage = RuntimeMenuDraftStorage(
        root: directory,
        files: ComposerDraftFiles(
            root: draftRoot,
            startupSweepOperation: { _ in await sweep.run() }
        )
    )
    let firstRoute = ComposerRoute(identity: "shared-sweep-first", generation: 16)
    let firstModel = makeRuntimeMenuModel(
        route: firstRoute,
        runtime: RuntimeMenuSpy(),
        draftStorage: firstStorage
    )

    await sweep.waitForStart()

    let secondStorage = RuntimeMenuDraftStorage(
        root: directory,
        files: ComposerDraftFiles(root: draftRoot)
    )
    let secondRoute = ComposerRoute(identity: "shared-sweep-second", generation: 17)
    let secondModel = makeRuntimeMenuModel(
        route: secondRoute,
        runtime: RuntimeMenuSpy(),
        draftStorage: secondStorage
    )
    let firstImport = try #require(
        firstModel.attach([ComposerAttachmentSource.temporary(firstSource)], target: firstRoute.token)
    )
    let secondImport = try #require(
        secondModel.attach([ComposerAttachmentSource.temporary(secondSource)], target: secondRoute.token)
    )

    await sweep.release()
    await firstImport.value
    await secondImport.value

    let firstAttachment = try #require(firstModel.attachments.first)
    let secondAttachment = try #require(secondModel.attachments.first)
    #expect(FileManager.default.fileExists(atPath: firstAttachment.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: secondAttachment.fileURL.path))
    #expect(await sweep.startCount() == 1)
}


@Test("A leased draft root survives startup sweep cache eviction pressure")
func leasedDraftRootSurvivesSweepCachePressure() async throws {
    let directory = try runtimeMenuTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "shared", directoryHint: .isDirectory)
    let sweep = RuntimeMenuSweepGate()
    let first = ComposerDraftFiles(
        root: root,
        startupSweepOperation: { _ in await sweep.run() }
    )
    let firstSweep = first.startStartupSweep()
    await sweep.waitForStart()
    await sweep.release()
    _ = await firstSweep.value

    for index in 0..<16 {
        await completeRuntimeMenuSweep(
            at: directory.appending(path: "pressure-\(index)", directoryHint: .isDirectory)
        )
    }

    let second = ComposerDraftFiles(root: root)
    _ = await second.startStartupSweep().value
    #expect(await sweep.startCount() == 1)
}

@Test("Shutdown cancels a recorder while it starts")
@MainActor
func shutdownCancelsStartingRecorder() async {
    let recorder = RuntimeMenuRecordingSpy()
    let model = makeRuntimeMenuModel(
        route: ComposerRoute(identity: "shutdown-recorder", generation: 18),
        runtime: RuntimeMenuSpy(),
        dictation: RuntimeMenuDictationSpy(),
        recorder: recorder
    )

    model.toggleRecording()
    await recorder.waitForStart()
    #expect(model.recordingStatus == .requestingPermission)

    model.shutdown()
    await recorder.waitForCancel()
    #expect(model.recordingStatus == .idle)
}

@Test("An out-of-order unmount does not block submit")
@MainActor
func outOfOrderUnmountDoesNotBlockSubmit() async {
    let turn = RuntimeMenuTurnSpy(sessionID: "live")
    let completion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let model = makeRuntimeMenuModel(
        route: ComposerRoute(identity: "mount-token-submit", generation: 3),
        runtime: RuntimeMenuSpy(),
        turn: turn,
        operationCompletion: completion
    )

    let stale = model.mount()
    let live = model.mount()
    model.unmount(stale)

    model.text = "Still send"
    model.submit()
    await turn.waitForSubmission()
    await completion.wait()

    #expect(stale != live)
    #expect(turn.submissionSessionIDs == ["live"])

    model.unmount(live)
    model.text = "After live unmount"
    model.submit()
    #expect(turn.submissionSessionIDs == ["live"])
}

@Test("A canceled runtime change cannot clear its replacement")
@MainActor
func canceledRuntimeChangeKeepsReplacementOwned() async {
    let runtime = RuntimeMenuSpy(blockModelChanges: true)
    let turn = RuntimeMenuTurnSpy(sessionID: "live")
    let completion = RuntimeMenuOperationCompletion(expectedCount: 1)
    let route = ComposerRoute(identity: "runtime-owner", generation: 19, liveSessionID: "live")
    let model = makeRuntimeMenuModel(
        route: route,
        runtime: runtime,
        turn: turn,
        operationCompletion: completion
    )

    model.selectModel("first", provider: nil)
    await runtime.waitForModelChange()

    model.update(route: ComposerRoute(
        identity: route.identity,
        generation: route.generation,
        liveSessionID: "live",
        isReadOnly: true
    ))
    model.update(route: route)
    model.selectModel("second", provider: nil)
    await runtime.waitForModelChange(count: 2)

    await runtime.releaseModelChange()
    model.selectModel("third", provider: nil)
    #expect(await runtime.modelSessionIDs() == ["live", "live"])

    await runtime.releaseModelChange()
    await completion.wait()
    #expect(model.modelSelection.pending == "second")
}

@Test("Route changes cancel runtime menu work without disturbing its replacement")
@MainActor
func routeChangesCancelRuntimeMenuWorkWithoutDisturbingReplacement() async {
    let runtime = RuntimeMenuSpy(blockInventory: true, blockModelChanges: true)
    let completion = RuntimeMenuOperationCompletion(expectedCount: 4)
    let routeA = ComposerRoute(identity: "runtime-route-a", generation: 20, liveSessionID: "a")
    let routeB = ComposerRoute(identity: "runtime-route-b", generation: 21, liveSessionID: "b")
    let model = makeRuntimeMenuModel(
        route: routeA,
        runtime: runtime,
        operationCompletion: completion
    )

    model.loadModels()
    model.selectModel("alpha", provider: "test")
    await runtime.waitForInventory()
    await runtime.waitForModelChange()

    model.update(route: routeB)
    #expect(model.canChangeRuntime)
    model.loadModels()
    model.selectModel("beta", provider: "test")
    await runtime.waitForInventory(count: 2)
    await runtime.waitForModelChange(count: 2)
    #expect(model.modelSelection.pending == "beta")

    await runtime.releaseInventory()
    await runtime.releaseModelChange()
    await completion.wait(for: 2)

    #expect(await runtime.inventoryCancellationStates() == [true])
    #expect(await runtime.modelCancellationStates() == [true])
    #expect(model.inventory == .notLoaded)
    #expect(!model.canChangeRuntime)

    await runtime.releaseInventory()
    await runtime.releaseModelChange()
    await completion.wait()

    #expect(await runtime.inventorySessionIDs() == ["a", "b"])
    #expect(await runtime.modelSessionIDs() == ["a", "b"])
    #expect(model.inventory == .loaded(runtimeMenuInventory))
    #expect(model.modelSelection.pending == "beta")
    #expect(model.canChangeRuntime)
}

@MainActor
private func makeRuntimeMenuModel(
    route: ComposerRoute,

    runtime: RuntimeMenuSpy,
    turn: RuntimeMenuTurnSpy? = nil,
    operationCompletion: RuntimeMenuOperationCompletion? = nil,
    attachmentStaging: any AttachmentStaging = RuntimeMenuAttachmentStaging(),
    dictation: (any SpeechDictating)? = nil,
    recorder: (any AudioRecording)? = nil,
    draftStorage: RuntimeMenuDraftStorage = .init()
) -> ComposerModel {
    let operationDidFinish: @MainActor () -> Void = { [draftStorage] in
        draftStorage.keepAlive()
        operationCompletion?.finish()
    }
    return ComposerModel(
        route: route,
        runtime: runtime,
        attachmentStaging: attachmentStaging,
        turn: turn,
        operationDidFinish: operationDidFinish,
        dictation: dictation,
        recorder: recorder,
        files: draftStorage.files
    )
}

private func completeRuntimeMenuSweep(at root: URL) async {
    let files = ComposerDraftFiles(root: root)
    _ = await files.startStartupSweep().value
}





private func runtimeMenuTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HermternalComposerRuntimeMenu-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private final class RuntimeMenuDraftStorage {
    let files: ComposerDraftFiles
    private let root: URL

    init(root: URL? = nil, files: ComposerDraftFiles? = nil) {
        let root = root ?? FileManager.default.temporaryDirectory.appending(
            path: "HermterminalComposerRuntimeMenuDraft-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        self.root = root
        self.files = files ?? ComposerDraftFiles(
            root: root.appending(path: "drafts", directoryHint: .isDirectory)
        )
    }

    func keepAlive() {}

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor RuntimeMenuSweepGate {
    private var started = false
    private var released = false
    private var starts = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func run() async -> Bool {
        started = true
        starts += 1
        resume(&startWaiters)
        guard !released else { return true }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
        return true
    }

    func waitForStart() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            if started {
                continuation.resume()
            } else {
                startWaiters.append(continuation)
            }
        }
    }

    func release() {
        released = true
        resume(&releaseWaiters)
    }

    func startCount() -> Int { starts }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let activeWaiters = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in activeWaiters {
            waiter.resume()
        }
    }
}

private actor RuntimeMenuDictationSpy: SpeechDictating {
    func availability() async -> DictationAvailability { .available }

    func prepare() async throws {}

    func start() async throws -> AsyncThrowingStream<DictationUpdate, any Error> {
        throw CancellationError()
    }

    func stop() async {}

    func cancel() async {}
}

private actor RuntimeMenuRecordingSpy: AudioRecording {
    private var started = false
    private var startReleased = false
    private var startReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    func requestPermission() async -> Bool { true }
    func start(into _: URL) async throws {
        started = true
        resume(&startWaiters)
        guard !startReleased else { return }
        await withCheckedContinuation { continuation in
            if startReleased {
                continuation.resume()
            } else {
                startReleaseWaiters.append(continuation)
            }
        }
    }

    func stop() async throws -> AudioRecordingResult {
        throw CancellationError()
    }
    func cancel() async {
        cancelled = true
        startReleased = true
        resume(&startReleaseWaiters)
        resume(&cancelWaiters)
    }

    func waitForStart() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            if started {
                continuation.resume()
            } else {
                startWaiters.append(continuation)
            }
        }
    }

    func waitForCancel() async {
        guard !cancelled else { return }
        await withCheckedContinuation { continuation in
            if cancelled {
                continuation.resume()
            } else {
                cancelWaiters.append(continuation)
            }
        }
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let activeWaiters = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in activeWaiters {
            waiter.resume()
        }
    }
}

@MainActor
private final class RuntimeMenuOperationCompletion {
    private let expectedCount: Int
    private var completedCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func finish() {
        completedCount += 1
        resumeWaiters()
    }

    func wait() async {
        await wait(for: expectedCount)
    }

    func wait(for count: Int) async {
        guard completedCount < count else { return }
        await withCheckedContinuation { continuation in
            if completedCount >= count {
                continuation.resume()
            } else {
                waiters.append((count, continuation))
            }
        }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { completedCount >= $0.count }
        waiters.removeAll { completedCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

private struct RuntimeMenuAttachmentStaging: AttachmentStaging {
    let transaction: RuntimeMenuAttachmentTransaction

    init(
        transaction: RuntimeMenuAttachmentTransaction = RuntimeMenuAttachmentTransaction(
            sessionID: "live",
            routeIdentity: "runtime-menu"
        )
    ) {
        self.transaction = transaction
    }

    func stageBatch(
        _ steps: [ComposerStagingStep],
        sessionID: String,
        routeIdentity: String,
        progress: @escaping @Sendable (UUID, Int) -> Void,
        reusing _: [AttachmentStagingReceipt]
    ) async throws -> any AttachmentStagingTransaction {
        guard transaction.sessionID == sessionID,
              transaction.routeIdentity == routeIdentity else {
            throw AttachmentStagingError.invalidRoute
        }
        await transaction.stage(steps)
        for step in steps {
            progress(step.attachment.id, step.attachment.byteCount)
        }
        return transaction
    }
}

private enum RuntimeMenuCommitOutcome: Sendable {
    case committed
    case failure
    case residual
}

private actor RuntimeMenuAttachmentTransaction: AttachmentStagingTransaction {
    let transactionID = UUID()
    let sessionID: String
    let routeIdentity: String
    private let blocksSnapshot: Bool
    private let blocksCommit: Bool
    private let commitOutcome: RuntimeMenuCommitOutcome
    private var items: [AttachmentStagingReceipt] = []
    private var state: AttachmentStagingTransactionState = .open
    private var snapshotReached = false
    private var snapshotReleased = false
    private var commitReached = false
    private var commitReleased = false
    private var commitCompleted = false
    private var compensationReached = false
    private var commits = 0
    private var compensations = 0
    private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var compensationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        sessionID: String,
        routeIdentity: String,
        blocksSnapshot: Bool = false,
        blocksCommit: Bool = false,
        commitOutcome: RuntimeMenuCommitOutcome = .committed
    ) {
        self.sessionID = sessionID
        self.routeIdentity = routeIdentity
        self.blocksSnapshot = blocksSnapshot
        self.blocksCommit = blocksCommit
        self.commitOutcome = commitOutcome
    }

    func stage(_ steps: [ComposerStagingStep]) {
        items = steps.map { step in
            let attachment = step.attachment
            return AttachmentStagingReceipt(
                id: attachment.id,
                sessionID: sessionID,
                routeIdentity: routeIdentity,
                deterministicName: ComposerSendPolicy.deterministicAttachmentName(for: attachment),
                serverReference: "attachment-\(attachment.id.uuidString)",
                serverPath: nil,
                outcome: .staged,
                rollbackSupport: .supported
            )
        }
    }

    func snapshot() async -> AttachmentStagingBatchReceipt {
        snapshotReached = true
        resume(&snapshotWaiters)
        if blocksSnapshot, !snapshotReleased {
            await withCheckedContinuation { continuation in
                if snapshotReleased {
                    continuation.resume()
                } else {
                    snapshotReleaseWaiters.append(continuation)
                }
            }
        }
        return batchReceipt(state: state)
    }

    func reuse(_ receipt: AttachmentStagingReceipt) async throws -> AttachmentStagingReceipt {
        guard receipt.sessionID == sessionID, receipt.routeIdentity == routeIdentity else {
            throw AttachmentStagingError.invalidReceipt
        }
        return receipt
    }

    func commit() async throws -> AttachmentStagingBatchReceipt {
        guard state == .open else { throw AttachmentStagingError.invalidReceipt }
        commits += 1
        commitReached = true
        resume(&commitWaiters)
        if blocksCommit, !commitReleased {
            await withCheckedContinuation { continuation in
                if commitReleased {
                    continuation.resume()
                } else {
                    commitReleaseWaiters.append(continuation)
                }
            }
        }
        switch commitOutcome {
        case .committed:
            state = .committed
        case .failure:
            throw AttachmentStagingError.invalidReceipt
        case .residual:
            state = .residual
        }
        commitCompleted = true
        resume(&commitCompletionWaiters)
        return batchReceipt(state: state)
    }

    func rollback() async -> AttachmentCompensationResult {
        compensations += 1
        compensationReached = true
        resume(&compensationWaiters)
        state = .compensated
        return .complete(batchReceipt(state: state))
    }

    func waitForSnapshot() async {
        guard !snapshotReached else { return }
        await withCheckedContinuation { continuation in
            if snapshotReached {
                continuation.resume()
            } else {
                snapshotWaiters.append(continuation)
            }
        }
    }

    func releaseSnapshot() {
        snapshotReleased = true
        resume(&snapshotReleaseWaiters)
    }

    func waitForCommit() async {
        guard !commitReached else { return }
        await withCheckedContinuation { continuation in
            if commitReached {
                continuation.resume()
            } else {
                commitWaiters.append(continuation)
            }
        }
    }

    func releaseCommit() {
        commitReleased = true
        resume(&commitReleaseWaiters)
    }

    func waitForCommitCompletion() async {
        guard !commitCompleted else { return }
        await withCheckedContinuation { continuation in
            if commitCompleted {
                continuation.resume()
            } else {
                commitCompletionWaiters.append(continuation)
            }
        }
    }

    func waitForCompensation() async {
        guard !compensationReached else { return }
        await withCheckedContinuation { continuation in
            if compensationReached {
                continuation.resume()
            } else {
                compensationWaiters.append(continuation)
            }
        }
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let activeWaiters = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in activeWaiters {
            waiter.resume()
        }
    }

    func commitCount() -> Int { commits }

    func compensationCount() -> Int { compensations }

    private func batchReceipt(
        state: AttachmentStagingTransactionState
    ) -> AttachmentStagingBatchReceipt {
        let outcome: AttachmentStagingOutcome
        switch state {
        case .open, .residual, .outcomeUnknown:
            outcome = .staged
        case .committed:
            outcome = .committed
        case .compensated:
            outcome = .rolledBack
        }
        let receipts = items.map { item in
            AttachmentStagingReceipt(
                id: item.id,
                sessionID: item.sessionID,
                routeIdentity: item.routeIdentity,
                deterministicName: item.deterministicName,
                serverReference: item.serverReference,
                serverPath: item.serverPath,
                outcome: outcome,
                rollbackSupport: item.rollbackSupport
            )
        }
        return AttachmentStagingBatchReceipt(
            transactionID: transactionID,
            sessionID: sessionID,
            routeIdentity: routeIdentity,
            items: receipts,
            state: state
        )
    }
}

private actor RuntimeMenuSpy: SessionRuntimeControlling {
    private let inventory: ModelInventory
    private let blockInventory: Bool
    private let blockModelChanges: Bool
    private var inventorySessions: [String?] = []
    private var modelSessions: [String] = []
    private var reasoningSessions: [String] = []
    private var inventoryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var inventoryReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var inventoryCancellationResults: [Bool] = []
    private var pendingInventoryReleases = 0
    private var modelChangeWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var reasoningChangeWaiters: [CheckedContinuation<Void, Never>] = []
    private var modelChangeReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var modelCancellationResults: [Bool] = []
    private var pendingModelChangeReleases = 0

    init(
        inventory: ModelInventory = runtimeMenuInventory,
        blockInventory: Bool = false,
        blockModelChanges: Bool = false
    ) {
        self.inventory = inventory
        self.blockInventory = blockInventory
        self.blockModelChanges = blockModelChanges
    }

    func modelInventory(sessionID: String?, refresh _: Bool) async throws -> ModelInventory {
        inventorySessions.append(sessionID)
        resumeInventoryWaiters()
        if blockInventory {
            await withCheckedContinuation { continuation in
                if pendingInventoryReleases > 0 {
                    pendingInventoryReleases -= 1
                    continuation.resume()
                } else {
                    inventoryReleaseWaiters.append(continuation)
                }
            }
        }
        inventoryCancellationResults.append(Task.isCancelled)
        return inventory
    }

    func setModel(
        _ model: String,
        provider _: String?,
        sessionID: String
    ) async throws -> ModelSwitchOutcome {
        modelSessions.append(sessionID)
        resumeModelChangeWaiters()
        if blockModelChanges {
            await withCheckedContinuation { continuation in
                if pendingModelChangeReleases > 0 {
                    pendingModelChangeReleases -= 1
                    continuation.resume()
                } else {
                    modelChangeReleaseWaiters.append(continuation)
                }
            }
        }
        modelCancellationResults.append(Task.isCancelled)
        return ModelSwitchOutcome(appliedValue: model, isDeferredToNextTurn: false)
    }

    func setReasoning(_ setting: ReasoningSetting, sessionID: String) async throws {
        reasoningSessions.append(sessionID)
        resume(&reasoningChangeWaiters)
    }

    func inventorySessionIDs() -> [String?] { inventorySessions }

    func modelSessionIDs() -> [String] { modelSessions }

    func reasoningSessionIDs() -> [String] { reasoningSessions }

    func inventoryCancellationStates() -> [Bool] { inventoryCancellationResults }

    func modelCancellationStates() -> [Bool] { modelCancellationResults }

    func waitForInventory(count: Int = 1) async {
        guard inventorySessions.count < count else { return }
        await withCheckedContinuation { continuation in
            if inventorySessions.count >= count {
                continuation.resume()
            } else {
                inventoryWaiters.append((count, continuation))
            }
        }
    }

    func waitForModelChange(count: Int = 1) async {
        guard modelSessions.count < count else { return }
        await withCheckedContinuation { continuation in
            if modelSessions.count >= count {
                continuation.resume()
            } else {
                modelChangeWaiters.append((count, continuation))
            }
        }
    }

    func waitForReasoningChange() async {
        guard reasoningSessions.isEmpty else { return }
        await withCheckedContinuation { continuation in
            if reasoningSessions.isEmpty {
                reasoningChangeWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    func releaseInventory() {
        guard !inventoryReleaseWaiters.isEmpty else {
            pendingInventoryReleases += 1
            return
        }
        inventoryReleaseWaiters.removeFirst().resume()
    }

    func releaseModelChange() {
        guard !modelChangeReleaseWaiters.isEmpty else {
            pendingModelChangeReleases += 1
            return
        }
        modelChangeReleaseWaiters.removeFirst().resume()
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let activeWaiters = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in activeWaiters {
            waiter.resume()
        }
    }

    private func resumeInventoryWaiters() {
        let ready = inventoryWaiters.filter { inventorySessions.count >= $0.count }
        inventoryWaiters.removeAll { inventorySessions.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func resumeModelChangeWaiters() {
        let ready = modelChangeWaiters.filter { modelSessions.count >= $0.count }
        modelChangeWaiters.removeAll { modelSessions.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

@MainActor
private final class RuntimeMenuTurnSpy: ComposerTurnRouting {
    let sessionID: String
    let blocksPreparation: Bool
    let prepareFailure: GatewayError?
    let submitFailure: GatewayError?
    private(set) var prepareRequests: [ComposerRouteToken] = []
    private(set) var submissionSessionIDs: [String] = []
    private(set) var publishedTexts: [String] = []
    private(set) var publishedRoutes: [ComposerRouteToken] = []
    private(set) var rolledBackRoutes: [ComposerRouteToken] = []
    private var preparationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var preparationReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingPreparationReleases = 0
    private var submissionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        sessionID: String,
        blocksPreparation: Bool = false,
        prepareFailure: GatewayError? = nil,
        submitFailure: GatewayError? = nil
    ) {
        self.sessionID = sessionID
        self.blocksPreparation = blocksPreparation
        self.prepareFailure = prepareFailure
        self.submitFailure = submitFailure
    }

    func prepareSession(expectedRoute: ComposerRouteToken) async throws -> String {
        prepareRequests.append(expectedRoute)
        resumePreparationWaiters()
        if blocksPreparation {
            await withCheckedContinuation { continuation in
                if pendingPreparationReleases > 0 {
                    pendingPreparationReleases -= 1
                    continuation.resume()
                } else {
                    preparationReleaseWaiters.append(continuation)
                }
            }
        }
        if let prepareFailure { throw prepareFailure }
        return sessionID
    }

    func publishUserTurn(text: String, route: ComposerRouteToken) {
        publishedTexts.append(text)
        publishedRoutes.append(route)
    }

    func rollbackUserTurn(route: ComposerRouteToken) {
        rolledBackRoutes.append(route)
    }

    func submit(text _: String, sessionID: String) async throws {
        submissionSessionIDs.append(sessionID)
        let waiters = submissionWaiters
        submissionWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
        if let submitFailure { throw submitFailure }
    }

    func stop() async {}

    func waitForPreparation(count: Int = 1) async {
        guard prepareRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            if prepareRequests.count >= count {
                continuation.resume()
            } else {
                preparationWaiters.append((count, continuation))
            }
        }
    }

    func waitForSubmission() async {
        guard submissionSessionIDs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            if submissionSessionIDs.isEmpty {
                submissionWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    func finishPreparation() {
        guard !preparationReleaseWaiters.isEmpty else {
            pendingPreparationReleases += 1
            return
        }
        preparationReleaseWaiters.removeFirst().resume()
    }

    private func resumePreparationWaiters() {
        let ready = preparationWaiters.filter { prepareRequests.count >= $0.count }
        preparationWaiters.removeAll { prepareRequests.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
