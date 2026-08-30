import Foundation

public enum TranscriptMemoryCategory: String, Codable, CaseIterable, Sendable {
    case pagePayload
    case rowDescriptors
    case findCursor
    case index
    case wireRecord
    case other

    public var weight: Int {
        switch self {
        case .pagePayload: return 1
        case .rowDescriptors: return 2
        case .findCursor: return 2
        case .index: return 3
        case .wireRecord: return 1
        case .other: return 1
        }
    }
}

public struct TranscriptMemoryProfile: Codable, Hashable, Sendable {
    public let name: String
    public let byteLimit: Int
    public let categoryWeights: [TranscriptMemoryCategory: Int]

    public init(name: String, byteLimit: Int, categoryWeights: [TranscriptMemoryCategory: Int] = [:]) {
        precondition(byteLimit > 0)
        self.name = name
        self.byteLimit = byteLimit
        self.categoryWeights = categoryWeights
    }

    public static let active4MiB = TranscriptMemoryProfile(name: "active-4MiB", byteLimit: 4 * 1024 * 1024)
    public static let active8MiB = TranscriptMemoryProfile(name: "active-8MiB", byteLimit: 8 * 1024 * 1024)
    public static let active16MiB = TranscriptMemoryProfile(name: "active-16MiB", byteLimit: 16 * 1024 * 1024)
    public static let `default` = active8MiB

    public func weight(for category: TranscriptMemoryCategory) -> Int {
        max(1, categoryWeights[category] ?? category.weight)
    }
    public static let active4 = active4MiB
    public static let active8 = active8MiB
    public static let active16 = active16MiB
}

public struct TranscriptMemoryMetrics: Codable, Equatable, Sendable {
    public let limitBytes: Int
    public let usedBytes: Int
    public let peakBytes: Int
    public let admittedBytes: Int
    public let rejectedBytes: Int
    public let evictedBytes: Int
    public let admissions: [TranscriptMemoryCategory: Int]
    public let rejections: [TranscriptMemoryCategory: Int]

    public init(
        limitBytes: Int,
        usedBytes: Int,
        peakBytes: Int,
        admittedBytes: Int,
        rejectedBytes: Int,
        evictedBytes: Int,
        admissions: [TranscriptMemoryCategory: Int] = [:],
        rejections: [TranscriptMemoryCategory: Int] = [:]
    ) {
        self.limitBytes = limitBytes
        self.usedBytes = usedBytes
        self.peakBytes = peakBytes
        self.admittedBytes = admittedBytes
        self.rejectedBytes = rejectedBytes
        self.evictedBytes = evictedBytes
        self.admissions = admissions
        self.rejections = rejections
    }
}

public struct TranscriptMemoryAdmission: Hashable, Sendable {
    public let id: UUID
    public let category: TranscriptMemoryCategory
    public let requestedBytes: Int
    public let chargedBytes: Int

    public init(id: UUID = UUID(), category: TranscriptMemoryCategory, requestedBytes: Int, chargedBytes: Int) {
        self.id = id
        self.category = category
        self.requestedBytes = requestedBytes
        self.chargedBytes = chargedBytes
    }
}

/// Weighted byte admission for transient and cached transcript values.
public actor TranscriptMemoryBudget {
    public typealias Metrics = TranscriptMemoryMetrics
    public let profile: TranscriptMemoryProfile
    private var used = 0
    private var peak = 0
    private var admitted = 0
    private var rejected = 0
    private var evicted = 0
    private var admissions: [TranscriptMemoryCategory: Int] = [:]
    private var rejections: [TranscriptMemoryCategory: Int] = [:]

    public init(profile: TranscriptMemoryProfile = .default) {
        self.profile = profile
    }

    public func admit(category: TranscriptMemoryCategory, bytes: Int) -> TranscriptMemoryAdmission? {
        guard bytes >= 0 else { return nil }
        let charged = bytes.multipliedReportingOverflow(by: profile.weight(for: category))
        guard !charged.overflow, charged.partialValue <= profile.byteLimit,
              used <= profile.byteLimit - charged.partialValue else {
            let rejectedBytes = charged.overflow ? Int.max : charged.partialValue
            rejected = rejected.addingReportingOverflow(rejectedBytes).partialValue
            rejections[category, default: 0] = rejections[category, default: 0].addingReportingOverflow(rejectedBytes).partialValue
            return nil
        }
        used += charged.partialValue
        peak = max(peak, used)
        admitted = admitted.addingReportingOverflow(charged.partialValue).partialValue
        admissions[category, default: 0] = admissions[category, default: 0].addingReportingOverflow(charged.partialValue).partialValue
        return TranscriptMemoryAdmission(category: category, requestedBytes: bytes, chargedBytes: charged.partialValue)
    }

    public func release(_ admission: TranscriptMemoryAdmission) {
        used = max(0, used - admission.chargedBytes)
    }

    public func recordEviction(_ bytes: Int) { evicted = evicted.addingReportingOverflow(max(0, bytes)).partialValue }

    public func metrics() -> TranscriptMemoryMetrics {
        TranscriptMemoryMetrics(limitBytes: profile.byteLimit, usedBytes: used, peakBytes: peak, admittedBytes: admitted, rejectedBytes: rejected, evictedBytes: evicted, admissions: admissions, rejections: rejections)
    }

    public func resetMetrics() {
        admitted = 0; rejected = 0; evicted = 0; peak = used
        admissions.removeAll(keepingCapacity: true); rejections.removeAll(keepingCapacity: true)
    }
}
