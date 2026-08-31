import Foundation
/// App-owned memory categories. Values are resident decoded or prepared bytes,
/// not file-backed payloads that remain outside process memory.
public enum AppMemoryCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case activeTranscript
    case preparedContent
    case find
    case search
    case sidebar
    case prefetch
    case attachments
    case thumbnails
    case audioPCM
    case other

    public static let active = activeTranscript
    public static let prepared = preparedContent
    public static let sidebarDerivation = sidebar
    public static let sidebarMenu = sidebar
    public static let sidebarInput = sidebar
}

/// Device-class envelope and category admission limits for app-owned memory.
public struct AppMemoryProfile: Codable, Equatable, Sendable {
    public let name: String
    public let totalBytes: Int
    public let categoryLimits: [AppMemoryCategory: Int]

    public init(
        name: String,
        totalBytes: Int,
        categoryLimits: [AppMemoryCategory: Int] = [:]
    ) {
        precondition(totalBytes > 0, "App memory profile must have a positive envelope")
        self.name = name
        self.totalBytes = totalBytes
        self.categoryLimits = categoryLimits.mapValues { max(0, $0) }
    }

    public func limit(for category: AppMemoryCategory) -> Int {
        categoryLimits[category] ?? totalBytes
    }

    public var byteLimit: Int { totalBytes }
    public var envelopeBytes: Int { totalBytes }

    public static let iPhone100 = AppMemoryProfile(
        name: "iPhone100",
        totalBytes: 100 * 1_048_576,
        categoryLimits: [
            .activeTranscript: 4 * 1_048_576,
            .preparedContent: 8 * 1_048_576,
            .find: 4 * 1_048_576,
            .search: 8 * 1_048_576,
            .sidebar: 4 * 1_048_576,
            .prefetch: 32 * 1_048_576,
            .attachments: 2 * 1_048_576,
            .thumbnails: 4 * 1_048_576,
            .audioPCM: 1 * 1_048_576,
            .other: 33 * 1_048_576
        ]
    )

    public static let iPad216 = AppMemoryProfile(
        name: "iPad216",
        totalBytes: 216 * 1_048_576,
        categoryLimits: [
            .activeTranscript: 8 * 1_048_576,
            .preparedContent: 16 * 1_048_576,
            .find: 8 * 1_048_576,
            .search: 16 * 1_048_576,
            .sidebar: 8 * 1_048_576,
            .prefetch: 80 * 1_048_576,
            .attachments: 4 * 1_048_576,
            .thumbnails: 8 * 1_048_576,
            .audioPCM: 1 * 1_048_576,
            .other: 67 * 1_048_576
        ]
    )

    public static let mac440MiB = AppMemoryProfile(
        name: "mac440MiB",
        totalBytes: 440 * 1_048_576,
        categoryLimits: [
            .activeTranscript: 16 * 1_048_576,
            .preparedContent: 32 * 1_048_576,
            .find: 16 * 1_048_576,
            .search: 32 * 1_048_576,
            .sidebar: 16 * 1_048_576,
            .prefetch: 160 * 1_048_576,
            .attachments: 8 * 1_048_576,
            .thumbnails: 16 * 1_048_576,
            .audioPCM: 1 * 1_048_576,
            .other: 143 * 1_048_576
        ]
    )

    public static let `default` = mac440MiB
    public static let iPhone = iPhone100
    public static let iPad = iPad216
    public static let macOS = mac440MiB
    public static let iPhone100MiB = iPhone100
    public static let iPad216MiB = iPad216
    public static let mac440 = mac440MiB
}

public struct AppMemoryCategoryMetrics: Codable, Equatable, Sendable {
    public let limitBytes: Int
    public let residentBytes: Int
    public let peakBytes: Int
    public let admittedBytes: Int
    public let rejectedBytes: Int
    public let evictedBytes: Int
    public let admissionCount: Int
    public let rejectionCount: Int
    public let evictionCount: Int

    public init(
        limitBytes: Int,
        residentBytes: Int,
        peakBytes: Int,
        admittedBytes: Int,
        rejectedBytes: Int,
        evictedBytes: Int,
        admissionCount: Int,
        rejectionCount: Int,
        evictionCount: Int
    ) {
        self.limitBytes = limitBytes
        self.residentBytes = residentBytes
        self.peakBytes = peakBytes
        self.admittedBytes = admittedBytes
        self.rejectedBytes = rejectedBytes
        self.evictedBytes = evictedBytes
        self.admissionCount = admissionCount
        self.rejectionCount = rejectionCount
        self.evictionCount = evictionCount
    }
    public var limit: Int { limitBytes }
    public var resident: Int { residentBytes }
    public var usedBytes: Int { residentBytes }
    public var admissions: Int { admissionCount }
    public var rejections: Int { rejectionCount }
    public var evictions: Int { evictionCount }
}

public struct AppMemoryMetrics: Codable, Equatable, Sendable {
    public let profile: AppMemoryProfile
    public let residentBytes: Int
    public let peakBytes: Int
    public let admittedBytes: Int
    public let rejectedBytes: Int
    public let evictedBytes: Int
    public let categories: [AppMemoryCategory: AppMemoryCategoryMetrics]

    public init(
        profile: AppMemoryProfile,
        residentBytes: Int,
        peakBytes: Int,
        admittedBytes: Int,
        rejectedBytes: Int,
        evictedBytes: Int,
        categories: [AppMemoryCategory: AppMemoryCategoryMetrics]
    ) {
        self.profile = profile
        self.residentBytes = residentBytes
        self.peakBytes = peakBytes
        self.admittedBytes = admittedBytes
        self.rejectedBytes = rejectedBytes
        self.evictedBytes = evictedBytes
        self.categories = categories
    }

    public var totalBytes: Int { profile.totalBytes }
    public var limitBytes: Int { profile.totalBytes }
    public var usedBytes: Int { residentBytes }
}

public struct AppMemoryAdmission: Hashable, Sendable {
    public let id: UUID
    public let category: AppMemoryCategory
    public let requestedBytes: Int
    public let chargedBytes: Int
    public init(
        id: UUID = UUID(),
        category: AppMemoryCategory,
        requestedBytes: Int,
        chargedBytes: Int
    ) {
        precondition(requestedBytes >= 0 && chargedBytes >= 0)
        self.id = id
        self.category = category
        self.requestedBytes = requestedBytes
        self.chargedBytes = chargedBytes
    }
}

/// Synchronous, lock-protected admission for UI and Core cache adapters.
///
/// Admission is all-or-nothing. A rejected value stays with its caller and is
/// never retained by the registry. Callers release each successful admission
/// exactly once, or call evict to release it and increment the eviction count.
public final class AppMemoryRegistry: @unchecked Sendable {
    public let profile: AppMemoryProfile
    private struct State {
        var resident = 0
        var peak = 0
        var admitted = 0
        var rejected = 0
        var evicted = 0
        var admissionCount = 0
        var rejectionCount = 0
        var evictionCount = 0
    }

    private let lock = NSLock()
    private var stateByCategory = Dictionary(
        uniqueKeysWithValues: AppMemoryCategory.allCases.map { ($0, State()) }
    )

    public init(profile: AppMemoryProfile = .default) {
        self.profile = profile
    }

    public func admit(category: AppMemoryCategory, bytes: Int) -> AppMemoryAdmission? {
        guard bytes >= 0 else { return nil }
        return withLock {
            let resident = stateByCategory.values.reduce(0) {
                saturatingAdd($0, $1.resident)
            }
            let remaining = resident >= profile.totalBytes
                ? 0
                : profile.totalBytes - resident
            let categoryLimit = profile.limit(for: category)
            let categoryResident = stateByCategory[category, default: State()].resident
            guard categoryResident <= categoryLimit,
                  bytes <= categoryLimit - categoryResident,
                  bytes <= remaining else { var state = stateByCategory[category, default: State()]
                  state.rejected = saturatingAdd(state.rejected, bytes)
                  state.rejectionCount = saturatingAdd(state.rejectionCount, 1)
                  stateByCategory[category] = state
                  return nil
               }

            var state = stateByCategory[category, default: State()]
            state.resident = saturatingAdd(state.resident, bytes)
            state.peak = max(state.peak, state.resident)
            state.admitted = saturatingAdd(state.admitted, bytes)
            state.admissionCount = saturatingAdd(state.admissionCount, 1)
            stateByCategory[category] = state
            return AppMemoryAdmission(category: category, requestedBytes: bytes, chargedBytes: bytes)
        }
    }

    public func release(_ admission: AppMemoryAdmission) {
        withLock {
            var state = stateByCategory[admission.category, default: State()]
            state.resident = subtractClamped(state.resident, admission.chargedBytes)
            stateByCategory[admission.category] = state
        }
    }

    public func evict(_ admission: AppMemoryAdmission) {
        withLock {
            var state = stateByCategory[admission.category, default: State()]
            state.resident = subtractClamped(state.resident, admission.chargedBytes)
            state.evicted = saturatingAdd(state.evicted, admission.chargedBytes)
            state.evictionCount = saturatingAdd(state.evictionCount, 1)
            stateByCategory[admission.category] = state
        }
    }

    public func metrics() -> AppMemoryMetrics {
        withLock {
            let categories = Dictionary(uniqueKeysWithValues: AppMemoryCategory.allCases.map { category in
                let state = stateByCategory[category, default: State()]
                return (category, AppMemoryCategoryMetrics(
                    limitBytes: profile.limit(for: category),
                    residentBytes: state.resident,
                    peakBytes: state.peak,
                    admittedBytes: state.admitted,
                    rejectedBytes: state.rejected,
                    evictedBytes: state.evicted,
                    admissionCount: state.admissionCount,
                    rejectionCount: state.rejectionCount,
                    evictionCount: state.evictionCount
                ))
            })
            let total = categories.values.reduce(0) { saturatingAdd($0, $1.residentBytes) }
            let peak = categories.values.reduce(0) { saturatingAdd($0, $1.peakBytes) }
            let admitted = categories.values.reduce(0) { saturatingAdd($0, $1.admittedBytes) }
            let rejected = categories.values.reduce(0) { saturatingAdd($0, $1.rejectedBytes) }
            let evicted = categories.values.reduce(0) { saturatingAdd($0, $1.evictedBytes) }
            return AppMemoryMetrics(
                profile: profile,
                residentBytes: total,
                peakBytes: peak,
                admittedBytes: admitted,
                rejectedBytes: rejected,
                evictedBytes: evicted,
                categories: categories
            )
        }
    }
    public func metrics(for category: AppMemoryCategory) -> AppMemoryCategoryMetrics {
        metrics().categories[category] ?? AppMemoryCategoryMetrics(
            limitBytes: profile.limit(for: category),
            residentBytes: 0,
            peakBytes: 0,
            admittedBytes: 0,
            rejectedBytes: 0,
            evictedBytes: 0,
            admissionCount: 0,
            rejectionCount: 0,
            evictionCount: 0
        )
    }


    public func resetMetrics() {
        withLock {
            for category in AppMemoryCategory.allCases {
                var state = stateByCategory[category, default: State()]
                state.admitted = 0
                state.rejected = 0
                state.evicted = 0
                state.admissionCount = 0
                state.rejectionCount = 0
                state.evictionCount = 0
                state.peak = state.resident
                stateByCategory[category] = state
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }

    private func subtractClamped(_ lhs: Int, _ rhs: Int) -> Int {
        guard rhs >= 0 else { return lhs }
        return rhs >= lhs ? 0 : lhs - rhs
    }
}

public typealias MemoryCategory = AppMemoryCategory
public typealias MemoryProfile = AppMemoryProfile
public typealias MemoryRegistry = AppMemoryRegistry
