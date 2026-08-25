import Foundation


/// The optional instrumentation modules understood by HermternalCore.
///
/// The raw identifiers are persistence keys and are therefore stable across
/// releases. Keep adding cases at the end when possible so the bit positions
/// remain stable as well.
public enum DebugModule: String, CaseIterable, Codable, Sendable, Identifiable {
    case switchPhases = "switch-phases"
    case sidebarAndFolderSelection = "sidebar-folder-selection"
    case mainActorOccupancy = "main-actor-occupancy"
    case resourceContention = "resource-contention"
    case textLayoutAttribution = "text-layout-attribution"
    case visiblePaint = "visible-paint"
    case frameDelivery = "frame-delivery"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .switchPhases: "Session switch phases"
        case .sidebarAndFolderSelection: "Sidebar and folder selection"
        case .mainActorOccupancy: "Main-actor occupancy"
        case .resourceContention: "Resource contention"
        case .textLayoutAttribution: "Text-layout attribution"
        case .visiblePaint: "Visible paint"
        case .frameDelivery: "Frame delivery and gesture latency"
        }
    }

    /// One line suitable for a Settings row. The final clause states the
    /// principal cost of the module as its probes actually execute.
    public var description: String {
        switch self {
        case .switchPhases:
            "Times every session-switch phase; writes about a dozen synchronous stderr lines per selection, all on the main actor."
        case .sidebarAndFolderSelection:
            "Records sidebar and folder selection transitions; writes three or more synchronous stderr lines per selection, including a before/after pair around each selection write."
        case .mainActorOccupancy:
            "Counts the sidebar work one selection causes; increments a counter inside every row body, reads the clock twice per sidebar body and per ordering resolve, and posts one flush task per selection."
        case .resourceContention:
            "Measures cache and warm-store waits; takes a lock and two clock reads per guarded acquisition, and writes one stderr line per contended resource each selection."
        case .textLayoutAttribution:
            "Times and counts text work; measures each row's UTF-16 length inside the row body, times every parse and string conversion, and writes six stderr lines per selection."
        case .visiblePaint:
            "Times publish to visible pixels, and carries every statistic below; adds a one-point AppKit overlay that reports from each transcript paint pass, and appends one bounded ring sample per selection."
        case .frameDelivery:
            "Records display-refresh callbacks during scroll gestures and after sidebar clicks; one monotonic clock and one fixed-buffer write per callback, with no work while off."
        }
    }

    /// The bit occupied by this module in ``DebugModuleGate``.
    public var bit: UInt64 {
        switch self {
        case .switchPhases: UInt64(1) << 0
        case .sidebarAndFolderSelection: UInt64(1) << 1
        case .mainActorOccupancy: UInt64(1) << 2
        case .resourceContention: UInt64(1) << 3
        case .textLayoutAttribution: UInt64(1) << 4
        case .visiblePaint: UInt64(1) << 5
        case .frameDelivery: UInt64(1) << 6
        }
    }

    public static var allMask: UInt64 {
        allCases.reduce(into: UInt64(0)) { $0 |= $1.bit }
    }
}

/// The persisted and hot-path representation of enabled modules.
public struct DebugModuleMask: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let none = Self(rawValue: 0)
    public static let all = Self(rawValue: DebugModule.allMask)

    public init(_ modules: some Sequence<DebugModule>) {
        self.init(rawValue: modules.reduce(into: UInt64(0)) { $0 |= $1.bit })
    }

    public func contains(_ module: DebugModule) -> Bool {
        (rawValue & module.bit) != 0
    }
}

/// A deliberately tiny read-only gate for instrumentation hot paths.
///
/// ``isEnabled(_:)`` performs one ordinary ``UInt64`` field read and one
/// bitwise AND/compare. It does not acquire a lock, inspect a dictionary, or
/// read the environment. The composition root owns the capability and updates
/// the mask only in response to an explicit Settings toggle.
public final class DebugModuleGate: @unchecked Sendable {
    public private(set) var rawValue: UInt64

    public init(mask: DebugModuleMask = .none) {
        self.rawValue = mask.rawValue
    }

    @inline(__always)
    public func isEnabled(_ module: DebugModule) -> Bool {
        (rawValue & module.bit) != 0
    }

    fileprivate func replace(with mask: DebugModuleMask) {
        rawValue = mask.rawValue
    }
}

public enum DebugModuleCapabilityState: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var reason: String? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }
}

/// A platform-neutral persistence seam. Reads must be side-effect free; the
/// implementation writes only when the controller observes a changed mask.
public protocol DebugModuleStateStore: AnyObject {
    func loadMask() -> UInt64?
    func saveMask(_ mask: UInt64)
}

public final class UserDefaultsDebugModuleStateStore: DebugModuleStateStore, @unchecked Sendable {
    public static let defaultKey = "hermternal.debug-modules.enabled-mask"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = UserDefaultsDebugModuleStateStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func loadMask() -> UInt64? {
        guard let value = defaults.object(forKey: key) as? NSNumber else { return nil }
        return value.uint64Value
    }

    public func saveMask(_ mask: UInt64) {
        defaults.set(NSNumber(value: mask), forKey: key)
    }
}

/// A deterministic adapter useful to hosts without a persistence backend and
/// to tests that need to observe exactly how often persistence is written.
public final class InMemoryDebugModuleStateStore: DebugModuleStateStore, @unchecked Sendable {
    public private(set) var storedMask: UInt64?
    public private(set) var writeCount = 0

    public init(storedMask: UInt64? = nil) {
        self.storedMask = storedMask
    }

    public func loadMask() -> UInt64? {
        storedMask
    }

    public func saveMask(_ mask: UInt64) {
        storedMask = mask
        writeCount += 1
    }
}

public enum FrameDeliverySurface: String, Codable, CaseIterable, Sendable {
    case sidebar
    case transcript
    case unknown
}

/// One display-refresh observation captured by the AppKit probe. The probe
/// writes these value types into a preallocated ring; statistics are derived
/// only when the debug pane asks for a snapshot.
public struct FrameDeliverySample: Equatable, Sendable {
    public let presentedAtNanoseconds: UInt64
    public let intervalNanoseconds: UInt64?
    public let refreshIntervalNanoseconds: UInt64
    public let surface: FrameDeliverySurface
    public let gestureLatencyNanoseconds: UInt64?
    public let clickLatencyNanoseconds: UInt64?

    public init(
        presentedAtNanoseconds: UInt64,
        intervalNanoseconds: UInt64?,
        refreshIntervalNanoseconds: UInt64,
        surface: FrameDeliverySurface,
        gestureLatencyNanoseconds: UInt64? = nil,
        clickLatencyNanoseconds: UInt64? = nil
    ) {
        self.presentedAtNanoseconds = presentedAtNanoseconds
        self.intervalNanoseconds = intervalNanoseconds
        self.refreshIntervalNanoseconds = refreshIntervalNanoseconds
        self.surface = surface
        self.gestureLatencyNanoseconds = gestureLatencyNanoseconds
        self.clickLatencyNanoseconds = clickLatencyNanoseconds
    }
}

public struct DebugFrameDeliveryMetrics: Equatable, Sendable {
    public let observedRefreshIntervalNanoseconds: UInt64?
    public let frameIntervalMedianNanoseconds: UInt64?
    public let frameIntervalP90Nanoseconds: UInt64?
    public let frameIntervalP99Nanoseconds: UInt64?
    public let frameIntervalMaximumNanoseconds: UInt64?
    public let intervalsExceedingOneRefreshPeriod: Int
    public let intervalsExceedingTwoRefreshPeriods: Int
    public let longestConsecutiveLongFrameRun: Int
    public let gestureLatencyMedianNanoseconds: UInt64?
    public let clickLatencyMedianNanoseconds: UInt64?
    public let clickLatencyP90Nanoseconds: UInt64?
    public let clickLatencyP99Nanoseconds: UInt64?
    public let clickLatencyMaximumNanoseconds: UInt64?
    public let clickSampleCount: Int
    public let gestureLatencyP90Nanoseconds: UInt64?
    public let gestureLatencyP99Nanoseconds: UInt64?
    public let gestureLatencyMaximumNanoseconds: UInt64?
    public let gestureSampleCount: Int
    public let sidebarFrameCount: Int
    public let transcriptFrameCount: Int
    public let unattributedFrameCount: Int
    public let sampleSize: Int

    public init(samples: [FrameDeliverySample]) {
        sampleSize = samples.count
        guard !samples.isEmpty else {
            observedRefreshIntervalNanoseconds = nil
            frameIntervalMedianNanoseconds = nil
            frameIntervalP90Nanoseconds = nil
            frameIntervalP99Nanoseconds = nil
            frameIntervalMaximumNanoseconds = nil
            intervalsExceedingOneRefreshPeriod = 0
            intervalsExceedingTwoRefreshPeriods = 0
            longestConsecutiveLongFrameRun = 0
            gestureLatencyMedianNanoseconds = nil
            gestureLatencyP90Nanoseconds = nil
            clickLatencyMedianNanoseconds = nil
            clickLatencyP90Nanoseconds = nil
            clickLatencyP99Nanoseconds = nil
            clickLatencyMaximumNanoseconds = nil
            clickSampleCount = 0
            gestureLatencyP99Nanoseconds = nil
            gestureLatencyMaximumNanoseconds = nil
            gestureSampleCount = 0
            sidebarFrameCount = 0
            transcriptFrameCount = 0
            unattributedFrameCount = 0
            return
        }

        let refresh = samples.map(\.refreshIntervalNanoseconds).sorted()
        observedRefreshIntervalNanoseconds = Self.median(refresh)

        let intervals = samples.compactMap(\.intervalNanoseconds).sorted()
        frameIntervalMedianNanoseconds = intervals.isEmpty ? nil : Self.median(intervals)
        frameIntervalP90Nanoseconds = intervals.isEmpty ? nil : Self.nearestRank(intervals, numerator: 9, denominator: 10)
        frameIntervalP99Nanoseconds = intervals.isEmpty ? nil : Self.nearestRank(intervals, numerator: 99, denominator: 100)
        frameIntervalMaximumNanoseconds = intervals.last

        let period = observedRefreshIntervalNanoseconds ?? 0
        intervalsExceedingOneRefreshPeriod = period == 0 ? 0 : samples.reduce(into: 0) { count, sample in
            if let interval = sample.intervalNanoseconds, interval > period { count += 1 }
        }
        intervalsExceedingTwoRefreshPeriods = period == 0 ? 0 : samples.reduce(into: 0) { count, sample in
            if let interval = sample.intervalNanoseconds, interval > period * 2 { count += 1 }
        }

        var currentRun = 0
        var longestRun = 0
        if period > 0 {
            for sample in samples {
                if let interval = sample.intervalNanoseconds, interval > period {
                    currentRun += 1
                    longestRun = max(longestRun, currentRun)
                } else {
                    currentRun = 0
                }
            }
        }
        longestConsecutiveLongFrameRun = longestRun

        let latencies = samples.compactMap(\.gestureLatencyNanoseconds).sorted()
        gestureSampleCount = latencies.count
        gestureLatencyMedianNanoseconds = latencies.isEmpty ? nil : Self.median(latencies)
        gestureLatencyP90Nanoseconds = latencies.isEmpty ? nil : Self.nearestRank(latencies, numerator: 9, denominator: 10)
        gestureLatencyP99Nanoseconds = latencies.isEmpty ? nil : Self.nearestRank(latencies, numerator: 99, denominator: 100)
        gestureLatencyMaximumNanoseconds = latencies.last
        let clickLatencies = samples.compactMap(\.clickLatencyNanoseconds).sorted()
        clickSampleCount = clickLatencies.count
        clickLatencyMedianNanoseconds = clickLatencies.isEmpty ? nil : Self.median(clickLatencies)
        clickLatencyP90Nanoseconds = clickLatencies.isEmpty ? nil : Self.nearestRank(clickLatencies, numerator: 9, denominator: 10)
        clickLatencyP99Nanoseconds = clickLatencies.isEmpty ? nil : Self.nearestRank(clickLatencies, numerator: 99, denominator: 100)
        clickLatencyMaximumNanoseconds = clickLatencies.last

        sidebarFrameCount = samples.reduce(into: 0) { count, sample in
            if sample.surface == .sidebar { count += 1 }
        }
        transcriptFrameCount = samples.reduce(into: 0) { count, sample in
            if sample.surface == .transcript { count += 1 }
        }
        unattributedFrameCount = samples.reduce(into: 0) { count, sample in
            if sample.surface == .unknown { count += 1 }
        }
    }

    private static func nearestRank(_ sorted: [UInt64], numerator: Int, denominator: Int) -> UInt64 {
        sorted[max(1, (sorted.count * numerator + denominator - 1) / denominator) - 1]
    }

    private static func median(_ sorted: [UInt64]) -> UInt64 {
        let middle = sorted.count / 2
        guard sorted.count.isMultiple(of: 2) else { return sorted[middle] }
        return (sorted[middle - 1] / 2) + (sorted[middle] / 2)
            + ((sorted[middle - 1] % 2 + sorted[middle] % 2) / 2)
    }
}

public struct DebugSelectionAggregate: Codable, Equatable, Sendable {
    public let publishToVisibleNanoseconds: UInt64
    public let selectionCount: Int
    public let publicationCount: Int
    public let largestRowCharacterCount: Int?

    public init(
        publishToVisibleNanoseconds: UInt64,
        selectionCount: Int = 0,
        publicationCount: Int = 0,
        largestRowCharacterCount: Int? = nil
    ) {
        self.publishToVisibleNanoseconds = publishToVisibleNanoseconds
        self.selectionCount = selectionCount
        self.publicationCount = publicationCount
        self.largestRowCharacterCount = largestRowCharacterCount
    }
}

/// A bounded chronological sample store. Its payload retains at most
/// ``capacity`` samples for each producer. Frame storage is lazy: a disabled
/// frame module never allocates its second slot array.
public final class DebugMetricsRingBuffer: @unchecked Sendable {
    public static let defaultCapacity = 64

    public let capacity: Int
    public var retainedBytesCeiling: Int {
        capacity * MemoryLayout<DebugSelectionAggregate>.stride
    }

    private var slots: [DebugSelectionAggregate?]
    private var frameSlots: [FrameDeliverySample?]?
    private var nextIndex = 0
    private var sampleCount = 0
    private var frameNextIndex = 0
    private var frameSampleCount = 0

    public init(capacity: Int = DebugMetricsRingBuffer.defaultCapacity) {
        precondition(capacity > 0, "Debug metrics capacity must be positive")
        self.capacity = capacity
        self.slots = Array(repeating: nil, count: capacity)
    }

    public var count: Int { sampleCount }
    public var frameCount: Int { frameSampleCount }
    public var isFrameStorageAllocated: Bool { frameSlots != nil }

    public func append(_ sample: DebugSelectionAggregate) {
        slots[nextIndex] = sample
        nextIndex = (nextIndex + 1) % capacity
        sampleCount = min(sampleCount + 1, capacity)
    }

    public func appendFrame(_ sample: FrameDeliverySample) {
        if frameSlots == nil {
            frameSlots = Array(repeating: nil, count: capacity)
        }
        frameSlots![frameNextIndex] = sample
        frameNextIndex = (frameNextIndex + 1) % capacity
        frameSampleCount = min(frameSampleCount + 1, capacity)
    }

    public func removeAll() {
        slots = Array(repeating: nil, count: capacity)
        nextIndex = 0
        sampleCount = 0
        if frameSlots != nil {
            frameSlots = Array(repeating: nil, count: capacity)
        }
        frameNextIndex = 0
        frameSampleCount = 0
    }

    public var samples: [DebugSelectionAggregate] {
        guard sampleCount > 0 else { return [] }
        let firstIndex = sampleCount == capacity ? nextIndex : 0
        return (0..<sampleCount).map { offset in
            slots[(firstIndex + offset) % capacity]!
        }
    }

    public var frameSamples: [FrameDeliverySample] {
        guard let frameSlots, frameSampleCount > 0 else { return [] }
        let firstIndex = frameSampleCount == capacity ? frameNextIndex : 0
        return (0..<frameSampleCount).map { offset in
            frameSlots[(firstIndex + offset) % capacity]!
        }
    }
}
public struct DebugMetricsSnapshot: Equatable, Sendable {
    public let latest: DebugSelectionAggregate
    public let publishToVisibleMedianNanoseconds: UInt64
    public let publishToVisibleP90Nanoseconds: UInt64
    public let publishToVisibleMaxNanoseconds: UInt64
    /// Nil means the producer module was disabled for the retained samples.
    public let selectionCount: Int?
    public let publicationCount: Int?
    public let largestRowCharacterCount: Int?
    public let sampleSize: Int

    fileprivate init(samples: [DebugSelectionAggregate], enabledMask: UInt64 = DebugModule.allMask) {
        precondition(!samples.isEmpty)
        let sortedDurations = samples.map(\.publishToVisibleNanoseconds).sorted()
        self.latest = samples[samples.count - 1]
        self.publishToVisibleMedianNanoseconds = Self.median(sortedDurations)
        self.publishToVisibleP90Nanoseconds = sortedDurations[Self.nearestRankIndex(count: sortedDurations.count, numerator: 9, denominator: 10)]
        self.publishToVisibleMaxNanoseconds = sortedDurations[sortedDurations.count - 1]
        self.selectionCount = enabledMask & DebugModule.sidebarAndFolderSelection.bit != 0
            ? latest.selectionCount
            : nil
        self.publicationCount = enabledMask & DebugModule.switchPhases.bit != 0
            ? latest.publicationCount
            : nil
        self.largestRowCharacterCount = enabledMask & DebugModule.textLayoutAttribution.bit != 0
            ? latest.largestRowCharacterCount
            : nil
        self.sampleSize = samples.count
    }

    private static func nearestRankIndex(count: Int, numerator: Int, denominator: Int) -> Int {
        let rank = max(1, (count * numerator + denominator - 1) / denominator)
        return rank - 1
    }

    private static func median(_ sorted: [UInt64]) -> UInt64 {
        let middle = sorted.count / 2
        guard sorted.count.isMultiple(of: 2) else { return sorted[middle] }
        return average(sorted[middle - 1], sorted[middle])
    }

    private static func average(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        (lhs / 2) + (rhs / 2) + ((lhs % 2 + rhs % 2) / 2)
    }
}

public protocol DebugModuleCapability: AnyObject, Sendable {
    var state: DebugModuleCapabilityState { get }
    var modules: [DebugModule] { get }
    var gate: DebugModuleGate { get }
    var metrics: DebugMetricsSnapshot? { get }
    var frameDeliveryMetrics: DebugFrameDeliveryMetrics? { get }

    func isEnabled(_ module: DebugModule) -> Bool
    func setEnabled(_ enabled: Bool, for module: DebugModule)
    func record(_ aggregate: DebugSelectionAggregate, for module: DebugModule)
    func record(_ sample: FrameDeliverySample)
    func clearMetrics()
}

/// The injected implementation used by a composition root. The host supplies
/// the debug-mode Bool (normally the HERMTERNAL_DEBUG=1 decision); this core
/// module never reads the environment itself.
public final class DebugModuleController: DebugModuleCapability, @unchecked Sendable {
    public let state: DebugModuleCapabilityState
    public let modules: [DebugModule]
    public let gate: DebugModuleGate
    private let store: any DebugModuleStateStore
    private let buffer: DebugMetricsRingBuffer
    private var frameBuffer: DebugMetricsRingBuffer?

    public init(
        debugMode: Bool,
        forceAllModulesOn: Bool = false,
        store: any DebugModuleStateStore = UserDefaultsDebugModuleStateStore(),
        capacity: Int = DebugMetricsRingBuffer.defaultCapacity
    ) {
        self.store = store
        self.buffer = DebugMetricsRingBuffer(capacity: capacity)
        self.frameBuffer = nil

        // The outer gate is checked before touching persistence. A normal
        // launch therefore neither reads nor writes a prior debug mask.
        let initialMask: UInt64
        if forceAllModulesOn {
            initialMask = DebugModule.allMask
        } else if debugMode {
            // In debug mode, no stored choice means every module starts on.
            // This is an in-memory default only; it is not persisted until a
            // toggle.
            initialMask = store.loadMask() ?? DebugModule.allMask
        } else {
            initialMask = 0
        }
        self.gate = DebugModuleGate(mask: DebugModuleMask(rawValue: initialMask))
        MeasurementGate.install(mask: initialMask)
        if initialMask & DebugModule.frameDelivery.bit != 0 {
            self.frameBuffer = DebugMetricsRingBuffer(capacity: capacity)
        }

        guard debugMode else {
            self.state = .unavailable(reason: "Debug modules require HERMTERNAL_DEBUG=1")
            self.modules = []
            return
        }

        self.state = .available
        self.modules = DebugModule.allCases
    }

    public var metrics: DebugMetricsSnapshot? {
        guard state.isAvailable, isEnabled(.visiblePaint), buffer.count > 0 else { return nil }
        return DebugMetricsSnapshot(samples: buffer.samples, enabledMask: gate.rawValue)
    }
    public var frameDeliveryMetrics: DebugFrameDeliveryMetrics? {
        guard state.isAvailable, isEnabled(.frameDelivery),
              let frameBuffer, frameBuffer.frameCount > 0
        else { return nil }
        return DebugFrameDeliveryMetrics(samples: frameBuffer.frameSamples)
    }
    /// Testable proof that disabled recording keeps the frame ring unallocated.
    public var frameDeliveryStorageAllocated: Bool {
        frameBuffer != nil
    }

    @inline(__always)
    public func isEnabled(_ module: DebugModule) -> Bool {
        gate.isEnabled(module)
    }

    public func setEnabled(_ enabled: Bool, for module: DebugModule) {
        guard state.isAvailable else { return }
        let oldMask = gate.rawValue
        let newMask = enabled ? oldMask | module.bit : oldMask & ~module.bit
        guard newMask != oldMask else { return }
        if enabled, module == .frameDelivery, frameBuffer == nil {
            frameBuffer = DebugMetricsRingBuffer(capacity: buffer.capacity)
        }
        gate.replace(with: DebugModuleMask(rawValue: newMask))
        MeasurementGate.install(mask: newMask)
        store.saveMask(newMask)
    }

    public func record(_ aggregate: DebugSelectionAggregate, for module: DebugModule) {
        // Visible-paint is the owner of the publish-to-visible sample stream.
        // Other modules may contribute fields to that aggregate upstream, but
        // only an enabled owner can retain one.
        guard module == .visiblePaint, isEnabled(module) else { return }
        buffer.append(aggregate)
    }
    public func record(_ sample: FrameDeliverySample) {
        guard isEnabled(.frameDelivery) else { return }
        if frameBuffer == nil {
            frameBuffer = DebugMetricsRingBuffer(capacity: buffer.capacity)
        }
        frameBuffer?.appendFrame(sample)
    }

    public func clearMetrics() {
        guard buffer.count > 0 || frameBuffer?.frameCount ?? 0 > 0 else { return }
        buffer.removeAll()
        frameBuffer?.removeAll()
    }

}
/// An in-memory capability adapter for previews, deterministic tests, and hosts
/// that intentionally do not persist debug choices. It implements the same
/// seam as the production controller without consulting UserDefaults.
public final class InMemoryDebugModuleCapability: DebugModuleCapability, @unchecked Sendable {
    public let state: DebugModuleCapabilityState = .available
    public let modules: [DebugModule] = DebugModule.allCases
    public let gate: DebugModuleGate

    private let buffer: DebugMetricsRingBuffer
    private var frameBuffer: DebugMetricsRingBuffer?

    public init(
        enabledMask: DebugModuleMask = .all,
        capacity: Int = DebugMetricsRingBuffer.defaultCapacity
    ) {
        self.gate = DebugModuleGate(mask: enabledMask)
        self.buffer = DebugMetricsRingBuffer(capacity: capacity)
        self.frameBuffer = nil
        if enabledMask.rawValue & DebugModule.frameDelivery.bit != 0 {
            self.frameBuffer = DebugMetricsRingBuffer(capacity: capacity)
        }
    }

    public var metrics: DebugMetricsSnapshot? {
        guard isEnabled(.visiblePaint), buffer.count > 0 else { return nil }
        return DebugMetricsSnapshot(samples: buffer.samples, enabledMask: gate.rawValue)
    }
    public var frameDeliveryMetrics: DebugFrameDeliveryMetrics? {
        guard isEnabled(.frameDelivery),
              let frameBuffer, frameBuffer.frameCount > 0
        else { return nil }
        return DebugFrameDeliveryMetrics(samples: frameBuffer.frameSamples)
    }

    @inline(__always)
    public func isEnabled(_ module: DebugModule) -> Bool {
        gate.isEnabled(module)
    }

    public func setEnabled(_ enabled: Bool, for module: DebugModule) {
        let oldMask = gate.rawValue
        let newMask = enabled ? oldMask | module.bit : oldMask & ~module.bit
        guard oldMask != newMask else { return }
        if enabled, module == .frameDelivery, frameBuffer == nil {
            frameBuffer = DebugMetricsRingBuffer(capacity: buffer.capacity)
        }
        gate.replace(with: DebugModuleMask(rawValue: newMask))
    }

    public func record(_ aggregate: DebugSelectionAggregate, for module: DebugModule) {
        guard module == .visiblePaint, isEnabled(module) else { return }
        buffer.append(aggregate)
    }

    public func record(_ sample: FrameDeliverySample) {
        guard isEnabled(.frameDelivery) else { return }
        if frameBuffer == nil {
            frameBuffer = DebugMetricsRingBuffer(capacity: buffer.capacity)
        }
        frameBuffer?.appendFrame(sample)
    }

    public func clearMetrics() {
        guard buffer.count > 0 || frameBuffer?.frameCount ?? 0 > 0 else { return }
        buffer.removeAll()
        frameBuffer?.removeAll()
    }
}

/// Omission is a valid injected state, not an exceptional path. It has no
/// displayable modules, a zero gate, and no-op mutation/measurement methods.
public final class OmittedDebugModuleCapability: DebugModuleCapability, @unchecked Sendable {
    public let state: DebugModuleCapabilityState = .unavailable(reason: "Debug modules capability was omitted")
    public let modules: [DebugModule] = []
    public let gate = DebugModuleGate(mask: .none)
    public let metrics: DebugMetricsSnapshot? = nil
    public let frameDeliveryMetrics: DebugFrameDeliveryMetrics? = nil

    public init() {}

    @inline(__always)
    public func isEnabled(_ module: DebugModule) -> Bool { false }

    public func setEnabled(_ enabled: Bool, for module: DebugModule) {}
    public func record(_ aggregate: DebugSelectionAggregate, for module: DebugModule) {}
    public func record(_ sample: FrameDeliverySample) {}
    public func clearMetrics() {}
}
