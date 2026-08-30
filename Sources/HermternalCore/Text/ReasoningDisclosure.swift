import Foundation

public enum ReasoningDisclosureState: String, Equatable, Sendable {
    case absent
    case collapsed
    case expanded
}

public struct ReasoningHeaderProjection: Equatable, Sendable {
    public let title: String
    public let isDisclosable: Bool
    public let isPulsing: Bool
    public let showsSpinner: Bool

    public init(title: String, isDisclosable: Bool, isPulsing: Bool, showsSpinner: Bool) {
        self.title = title
        self.isDisclosable = isDisclosable
        self.isPulsing = isPulsing
        self.showsSpinner = showsSpinner
    }

    /// Stable FNV-1a digest of header state. Deliberately excludes reasoning
    /// body length/content, so token arrivals do not invalidate this row.
    public var contentHash: UInt64 {
        var hash: UInt64 = 14695981039346656037
        func mix(_ byte: UInt8) { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        for byte in title.utf8 { mix(byte) }
        mix(0)
        mix(isDisclosable ? 1 : 0)
        mix(isPulsing ? 1 : 0)
        mix(showsSpinner ? 1 : 0)
        return hash
    }
}

public enum ReasoningDisclosurePolicy {
    public static func header(
        isStreaming: Bool,
        hasReasoning: Bool,
        reduceMotion: Bool
    ) -> ReasoningHeaderProjection? {
        guard hasReasoning else { return nil }
        let streaming = isStreaming
        return ReasoningHeaderProjection(
            title: streaming ? "Thinking" : "Reasoning",
            isDisclosable: true,
            isPulsing: streaming && !reduceMotion,
            showsSpinner: streaming && reduceMotion
        )
    }

    public static func rows(
        state: ReasoningDisclosureState,
        reasoningBlockCount: Int
    ) -> Int {
        guard state == .expanded else { return 0 }
        return max(0, reasoningBlockCount)
    }
}

public enum ReasoningPulse {
    public static let period: Duration = .milliseconds(1_600)
    public static let minimumOpacity = 0.45
    public static let maximumOpacity = 1.0

    public static func opacity(atPhase phase: Double) -> Double {
        guard phase.isFinite else { return maximumOpacity }
        let normalized = phase - floor(phase)
        let wave = (cos(normalized * 2 * Double.pi) + 1) / 2
        return minimumOpacity + (maximumOpacity - minimumOpacity) * wave
    }

    public static func isEnabled(reduceMotion: Bool, isStreaming: Bool) -> Bool {
        isStreaming && !reduceMotion
    }
}
