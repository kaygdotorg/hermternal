import Foundation

/// Process-wide measurement gating for static Core instrumentation entry points.
///
/// This is deliberately a measurement mask rather than the capability/plugin
/// registry pattern: it selects no behaviour, carries no implementation, and
/// has no fake or omitted variant. A single startup installation avoids adding
/// a capability parameter to hot text parsing and cache APIs. The host resolves
/// capability state and environment overrides before calling `install`.
public enum MeasurementGate {
    /// Core measures nothing until the composition root installs its mask.
    nonisolated(unsafe) private static var installedMask: UInt64 = 0

    /// Installs the current process measurement mask during composition-root
    /// setup and after an explicit module toggle. The host must resolve all
    /// policy before calling this method.
    public static func install(mask: UInt64) {
        installedMask = mask
    }

    /// Performs the one integer gate test used by Core instrumentation hot paths.
    @inline(__always)
    public static func isEnabled(_ module: DebugModule) -> Bool {
        (installedMask & module.bit) != 0
    }
}
