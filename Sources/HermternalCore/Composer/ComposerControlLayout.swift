import Foundation

public enum ComposerControlDensity: String, Equatable, Sendable {
    case full
    case condensed
    case minimal
}

public enum ComposerControlLayout {
    public static let fullMinimumWidth: Double = 480
    public static let condensedMinimumWidth: Double = 360
    public static let hysteresis: Double = 24

    public static func density(
        availableWidth: Double,
        previous: ComposerControlDensity?
    ) -> ComposerControlDensity {
        let width = max(0, availableWidth)
        guard let previous else {
            if width >= fullMinimumWidth { return .full }
            if width >= condensedMinimumWidth { return .condensed }
            return .minimal
        }

        switch previous {
        case .full:
            // Once full, leave it only below the lower edge of its band.
            return width >= fullMinimumWidth - hysteresis ? .full :
                (width >= condensedMinimumWidth - hysteresis ? .condensed : .minimal)
        case .condensed:
            // Condensed has a dead band on both sides, preventing oscillation
            // while a window is dragged over a breakpoint.
            if width >= fullMinimumWidth + hysteresis { return .full }
            if width < condensedMinimumWidth - hysteresis { return .minimal }
            return .condensed
        case .minimal:
            return width >= condensedMinimumWidth + hysteresis ? .condensed : .minimal
        }
    }
}
