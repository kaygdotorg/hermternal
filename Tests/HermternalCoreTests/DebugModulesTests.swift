import HermternalCore
import Testing

@Test("a disabled module performs no measurement work")
func disabledModuleRecordsNothing() {
    let store = InMemoryDebugModuleStateStore(storedMask: 0)
    let controller = DebugModuleController(debugMode: true, store: store)
    let sample = DebugSelectionAggregate(
        publishToVisibleNanoseconds: 42,
        selectionCount: 1,
        publicationCount: 1,
        largestRowCharacterCount: 12
    )

    controller.record(sample, for: .visiblePaint)

    #expect(controller.metrics == nil)
    #expect(store.writeCount == 0)
}
@Test("a disabled frame module allocates no frame storage or work")
func disabledFrameModuleDoesNotAllocateOrRecord() {
    let store = InMemoryDebugModuleStateStore(storedMask: 0)
    let controller = DebugModuleController(debugMode: true, store: store)
    let sample = FrameDeliverySample(
        presentedAtNanoseconds: 10,
        intervalNanoseconds: 8_333_333,
        refreshIntervalNanoseconds: 8_333_333,
        surface: .sidebar,
        gestureLatencyNanoseconds: 2_000_000
    )

    controller.record(sample)

    #expect(controller.frameDeliveryMetrics == nil)
    #expect(controller.frameDeliveryStorageAllocated == false)
    #expect(store.writeCount == 0)
}

@Test("frame delivery statistics preserve cadence, stutter and surface attribution")
func frameDeliveryStatisticsMatchKnownSeries() {
    let controller = DebugModuleController(
        debugMode: true,
        store: InMemoryDebugModuleStateStore(),
        capacity: 16
    )
    for (index, interval) in [UInt64(8), 8, 17, 18, 8, 25].enumerated() {
        controller.record(
            FrameDeliverySample(
                presentedAtNanoseconds: UInt64(index) * 10,
                intervalNanoseconds: interval,
                refreshIntervalNanoseconds: 8,
                surface: index.isMultiple(of: 2) ? .sidebar : .transcript,
                gestureLatencyNanoseconds: index < 3 ? UInt64(index + 1) : nil,
                clickLatencyNanoseconds: index < 3 ? UInt64(index + 4) : nil
            )
        )
    }

    let metrics = controller.frameDeliveryMetrics
    #expect(metrics?.observedRefreshIntervalNanoseconds == 8)
    #expect(metrics?.frameIntervalMedianNanoseconds == 12)
    #expect(metrics?.frameIntervalP90Nanoseconds == 25)
    #expect(metrics?.frameIntervalP99Nanoseconds == 25)
    #expect(metrics?.frameIntervalMaximumNanoseconds == 25)
    #expect(metrics?.intervalsExceedingOneRefreshPeriod == 3)
    #expect(metrics?.intervalsExceedingTwoRefreshPeriods == 3)
    #expect(metrics?.longestConsecutiveLongFrameRun == 2)
    #expect(metrics?.gestureLatencyMedianNanoseconds == 2)
    #expect(metrics?.gestureLatencyP90Nanoseconds == 3)
    #expect(metrics?.gestureLatencyP99Nanoseconds == 3)
    #expect(metrics?.gestureLatencyMaximumNanoseconds == 3)
    #expect(metrics?.clickLatencyMedianNanoseconds == 5)
    #expect(metrics?.clickLatencyP90Nanoseconds == 6)
    #expect(metrics?.clickLatencyP99Nanoseconds == 6)
    #expect(metrics?.clickLatencySamplesNanoseconds == [4, 5, 6])
    #expect(metrics?.clickLatencyMaximumNanoseconds == 6)
    #expect(metrics?.clickSampleCount == 3)
    #expect(metrics?.sidebarFrameCount == 3)
    #expect(metrics?.transcriptFrameCount == 3)
    #expect(metrics?.unattributedFrameCount == 0)
}

 
@Test("a disabled measurement value does not evaluate its producer")
func disabledMeasurementValueDoesNotEvaluateProducer() {
    MeasurementGate.install(mask: 0)
    defer { MeasurementGate.install(mask: 0) }
    var evaluations = 0
    let counted: () -> Int = {
        evaluations += 1
        return 42
    }

    let disabled = MeasurementGate.value(
        for: .mainActorOccupancy,
        counted()
    )

    #expect(disabled == nil)
    #expect(evaluations == 0)

    MeasurementGate.install(mask: DebugModule.mainActorOccupancy.bit)
    let enabled = MeasurementGate.value(
        for: .mainActorOccupancy,
        counted()
    )

    #expect(enabled == 42)
    #expect(evaluations == 1)
}

@Test("a changed toggle persists once and an unchanged toggle does not write")
func togglePersistsExactlyOncePerChange() {
    let store = InMemoryDebugModuleStateStore()
    let controller = DebugModuleController(debugMode: true, store: store)
    #expect(DebugModule.allCases.allSatisfy { controller.isEnabled($0) })
    #expect(store.writeCount == 0)

    controller.setEnabled(false, for: .visiblePaint)
    #expect(MeasurementGate.isEnabled(.visiblePaint) == false)
    #expect(MeasurementGate.isEnabled(.switchPhases))
    #expect(controller.isEnabled(.visiblePaint) == false)

    controller.setEnabled(false, for: .visiblePaint)
    #expect(store.writeCount == 1)

    controller.setEnabled(true, for: .visiblePaint)
    #expect(store.writeCount == 2)
    #expect(controller.isEnabled(.visiblePaint))
}

@Test("omitted capability is unavailable and safe to query")
func omittedCapabilityIsUnavailable() {
    let capability = OmittedDebugModuleCapability()

    #expect(capability.state == .unavailable(reason: "Debug modules capability was omitted"))
    #expect(capability.modules.isEmpty)
    #expect(capability.isEnabled(.switchPhases) == false)
    capability.setEnabled(true, for: .switchPhases)
    capability.record(DebugSelectionAggregate(publishToVisibleNanoseconds: 1), for: .visiblePaint)
    capability.clearMetrics()
    #expect(capability.metrics == nil)
}

@Test("the in-memory capability implements the same toggle and metrics seam")
func inMemoryCapabilityIsAUsableFake() {
    let capability = InMemoryDebugModuleCapability()
    capability.setEnabled(false, for: .visiblePaint)
    capability.record(DebugSelectionAggregate(publishToVisibleNanoseconds: 7), for: .visiblePaint)

    #expect(capability.isEnabled(.visiblePaint) == false)
    #expect(capability.metrics == nil)

    capability.setEnabled(true, for: .visiblePaint)
    capability.record(
        DebugSelectionAggregate(
            publishToVisibleNanoseconds: 7,
            selectionCount: 2,
            publicationCount: 3,
            largestRowCharacterCount: 4
        ),
        for: .visiblePaint
    )
    #expect(capability.metrics?.sampleSize == 1)
}

@Test("the non-debug outer gate ignores a previously enabled persisted mask")
func nonDebugModeHardZerosPersistedMask() {
    let store = InMemoryDebugModuleStateStore(storedMask: DebugModule.allMask)
    let controller = DebugModuleController(debugMode: false, store: store)

    for module in DebugModule.allCases {
        #expect(controller.isEnabled(module) == false)
    }
    #expect(controller.modules.isEmpty)
    #expect(controller.state == .unavailable(reason: "Debug modules require HERMTERNAL_DEBUG=1"))
    #expect(store.writeCount == 0)
    #expect(DebugModule.allCases.allSatisfy { MeasurementGate.isEnabled($0) == false })
}

@Test("a forced launch installs measurement without revealing the Modules pane")
func forceLaunchInstallsAllModulesWithoutPersistence() {
    let store = InMemoryDebugModuleStateStore(storedMask: 0)
    let controller = DebugModuleController(
        debugMode: false,
        forceAllModulesOn: true,
        store: store
    )

    #expect(controller.state == .unavailable(reason: "Debug modules require HERMTERNAL_DEBUG=1"))
    #expect(controller.modules.isEmpty)
    #expect(DebugModule.allCases.allSatisfy { MeasurementGate.isEnabled($0) })
    #expect(store.writeCount == 0)
}

@Test("the metrics ring is bounded by its explicit capacity")
func metricsRingNeverExceedsCapacity() {
    let ring = DebugMetricsRingBuffer(capacity: 3)

    for value in 1...10 {
        ring.append(DebugSelectionAggregate(publishToVisibleNanoseconds: UInt64(value)))
        #expect(ring.count <= 3)
    }

    #expect(ring.count == 3)
    #expect(ring.samples.map(\.publishToVisibleNanoseconds) == [8, 9, 10])
    #expect(ring.capacity == 3)
    #expect(ring.retainedBytesCeiling == 3 * MemoryLayout<DebugSelectionAggregate>.stride)
}


@Test("metrics expose unavailable producer fields instead of zero")
func metricsRespectProducerAvailability() {
    let visibleOnly = DebugModuleMask([DebugModule.visiblePaint])
    let controller = DebugModuleController(
        debugMode: true,
        store: InMemoryDebugModuleStateStore(storedMask: visibleOnly.rawValue)
    )
    controller.record(
        DebugSelectionAggregate(
            publishToVisibleNanoseconds: 11,
            selectionCount: 4,
            publicationCount: 5,
            largestRowCharacterCount: 6
        ),
        for: .visiblePaint
    )

    #expect(controller.metrics?.publishToVisibleMedianNanoseconds == 11)
    #expect(controller.metrics?.selectionCount == nil)
    #expect(controller.metrics?.publicationCount == nil)
    #expect(controller.metrics?.largestRowCharacterCount == nil)
}

@Test("publish-to-visible statistics use the retained sample series")
func metricsStatisticsMatchKnownSeries() {
    let controller = DebugModuleController(debugMode: true, store: InMemoryDebugModuleStateStore())
    for value in stride(from: 100, through: 1_000, by: 100) {
        controller.record(
            DebugSelectionAggregate(
                publishToVisibleNanoseconds: UInt64(value),
                selectionCount: value / 100,
                publicationCount: value / 50,
                largestRowCharacterCount: value
            ),
            for: .visiblePaint
        )
    }

    let metrics = controller.metrics
    #expect(metrics?.publishToVisibleMedianNanoseconds == 550)
    #expect(metrics?.publishToVisibleP90Nanoseconds == 900)
    #expect(metrics?.publishToVisibleMaxNanoseconds == 1_000)
    #expect(metrics?.sampleSize == 10)
    #expect(metrics?.selectionCount == 10)
    #expect(metrics?.publicationCount == 20)
    #expect(metrics?.largestRowCharacterCount == 1_000)
}

@Test("module identities and display metadata are stable and complete")
func moduleIdentitySetIsStable() {
    #expect(DebugModule.allCases.map(\.id) == [
        "switch-phases",
        "sidebar-folder-selection",
        "main-actor-occupancy",
        "resource-contention",
        "text-layout-attribution",
        "visible-paint",
        "frame-delivery"
    ])
    #expect(DebugModule.allCases.allSatisfy { !$0.title.isEmpty && !$0.description.isEmpty })
    #expect(DebugModule.allMask == DebugModule.allCases.reduce(into: UInt64(0)) { $0 |= $1.bit })
}
