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

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .switchPhases: "Session switch phases"
        case .sidebarAndFolderSelection: "Sidebar and folder selection"
        case .mainActorOccupancy: "Main-actor occupancy"
        case .resourceContention: "Resource contention"
        case .textLayoutAttribution: "Text-layout attribution"
        case .visiblePaint: "Visible paint"
        }
    }

    /// One line suitable for a Settings row. The final clause states the
    /// principal cost so an operator can make an informed toggle choice.
    public var description: String {
        switch self {
        case .switchPhases:
            "Records session-switch phase timestamps; adds one timestamp at each phase."
        case .sidebarAndFolderSelection:
            "Records sidebar and folder selection transitions; adds a small event and timestamp per selection."
        case .mainActorOccupancy:
            "Records main-actor occupancy and body evaluation summaries; adds counters and elapsed-time sampling per selection."
        case .resourceContention:
            "Records cache and warm-store wait aggregates; adds wait counters and elapsed-time sampling while work is contended."
        case .textLayoutAttribution:
            "Attributes text layout work to messages and segments; adds lightweight counters around layout evaluation."
        case .visiblePaint:
            "Records the publish-to-visible interval; adds one bounded timing sample per visible selection."
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
/// ``capacity * MemoryLayout<DebugSelectionAggregate>.stride`` bytes, with
/// 64 samples by default. The exact ceiling is exposed by
/// ``retainedBytesCeiling`` so hosts do not need to duplicate layout math.
public final class DebugMetricsRingBuffer: @unchecked Sendable {
    public static let defaultCapacity = 64

    public let capacity: Int
    public var retainedBytesCeiling: Int {
        capacity * MemoryLayout<DebugSelectionAggregate>.stride
    }

    private var slots: [DebugSelectionAggregate?]
    private var nextIndex = 0
    private var sampleCount = 0

    public init(capacity: Int = DebugMetricsRingBuffer.defaultCapacity) {
        precondition(capacity > 0, "Debug metrics capacity must be positive")
        self.capacity = capacity
        self.slots = Array(repeating: nil, count: capacity)
    }

    public var count: Int { sampleCount }

    public func append(_ sample: DebugSelectionAggregate) {
        slots[nextIndex] = sample
        nextIndex = (nextIndex + 1) % capacity
        sampleCount = min(sampleCount + 1, capacity)
    }

    public func removeAll() {
        slots = Array(repeating: nil, count: capacity)
        nextIndex = 0
        sampleCount = 0
    }

    public var samples: [DebugSelectionAggregate] {
        guard sampleCount > 0 else { return [] }
        let firstIndex = sampleCount == capacity ? nextIndex : 0
        return (0..<sampleCount).map { offset in
            slots[(firstIndex + offset) % capacity]!
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

    func isEnabled(_ module: DebugModule) -> Bool
    func setEnabled(_ enabled: Bool, for module: DebugModule)
    func record(_ aggregate: DebugSelectionAggregate, for module: DebugModule)
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

    public init(
        debugMode: Bool,
        forceAllModulesOn: Bool = false,
        store: any DebugModuleStateStore = UserDefaultsDebugModuleStateStore(),
        capacity: Int = DebugMetricsRingBuffer.defaultCapacity
    ) {
        self.store = store
        self.buffer = DebugMetricsRingBuffer(capacity: capacity)

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

    @inline(__always)
    public func isEnabled(_ module: DebugModule) -> Bool {
        gate.isEnabled(module)
    }

    public func setEnabled(_ enabled: Bool, for module: DebugModule) {
        guard state.isAvailable else { return }
        let oldMask = gate.rawValue
        let newMask = enabled ? oldMask | module.bit : oldMask & ~module.bit
        guard newMask != oldMask else { return }
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

    public func clearMetrics() {
        guard buffer.count > 0 else { return }
        buffer.removeAll()
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

    public init(
        enabledMask: DebugModuleMask = .all,
        capacity: Int = DebugMetricsRingBuffer.defaultCapacity
    ) {
        self.gate = DebugModuleGate(mask: enabledMask)
        self.buffer = DebugMetricsRingBuffer(capacity: capacity)
    }

    public var metrics: DebugMetricsSnapshot? {
        guard isEnabled(.visiblePaint), buffer.count > 0 else { return nil }
        return DebugMetricsSnapshot(samples: buffer.samples, enabledMask: gate.rawValue)
    }

    @inline(__always)
    public func isEnabled(_ module: DebugModule) -> Bool {
        gate.isEnabled(module)
    }

    public func setEnabled(_ enabled: Bool, for module: DebugModule) {
        let oldMask = gate.rawValue
        let newMask = enabled ? oldMask | module.bit : oldMask & ~module.bit
        guard oldMask != newMask else { return }
        gate.replace(with: DebugModuleMask(rawValue: newMask))
    }

    public func record(_ aggregate: DebugSelectionAggregate, for module: DebugModule) {
        guard module == .visiblePaint, isEnabled(module) else { return }
        buffer.append(aggregate)
    }

    public func clearMetrics() {
        guard buffer.count > 0 else { return }
        buffer.removeAll()
    }
}

/// Omission is a valid injected state, not an exceptional path. It has no
/// displayable modules, a zero gate, and no-op mutation/measurement methods.
public final class OmittedDebugModuleCapability: DebugModuleCapability, @unchecked Sendable {
    public let state: DebugModuleCapabilityState = .unavailable(reason: "Debug modules capability was omitted")
    public let modules: [DebugModule] = []
    public let gate = DebugModuleGate(mask: .none)
    public let metrics: DebugMetricsSnapshot? = nil

    public init() {}

    @inline(__always)
    public func isEnabled(_ module: DebugModule) -> Bool { false }

    public func setEnabled(_ enabled: Bool, for module: DebugModule) {}
    public func record(_ aggregate: DebugSelectionAggregate, for module: DebugModule) {}
    public func clearMetrics() {}
}
