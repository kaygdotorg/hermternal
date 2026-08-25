/// The semantic destination for transcript positioning.
///
/// A bottom target follows the most recent message, while a message target
/// identifies one message independently of its current array position.
/// Keeping this value independent of a rendered window lets a renderer
/// preserve an anchor when a bounded tail is promoted to a larger projection.
public enum TranscriptViewportTarget: Equatable, Sendable {
    case bottom
    case message(id: MessageIdentity)
}

/// Precedence rules for choosing a transcript viewport destination.
///
/// The policy is deliberately independent of AppKit/SwiftUI scroll APIs. A
/// route opening with no explicit target starts at the recent end. Once a
/// route is established, a projection change (including promotion of a warm
/// tail) retains the current anchor unless an explicit target or active stream
/// takes precedence.
public enum TranscriptViewportPolicy {
    /// Resolves the destination for one renderer update.
    ///
    /// Precedence is intentional and must remain in this order: explicit
    /// deep-link, Find target, streaming bottom-follow when the user is
    /// already near the bottom, route-opening bottom, then the existing
    /// anchor. A stream does not steal the viewport from a user reading older
    /// history. Promotion is represented by `routeChanged == false` and
    /// retains `currentTarget` without reasserting a new bottom target.
    public static func resolveTarget(
        explicitMessageID: MessageIdentity? = nil,
        findMessageID: MessageIdentity? = nil,
        isStreaming: Bool,
        isNearBottom: Bool,
        routeChanged: Bool,
        currentTarget: TranscriptViewportTarget? = nil
    ) -> TranscriptViewportTarget {
        if let explicitMessageID {
            return .message(id: explicitMessageID)
        }
        if let findMessageID {
            return .message(id: findMessageID)
        }
        if isStreaming && isNearBottom {
            return .bottom
        }
        if routeChanged {
            return .bottom
        }
        return currentTarget ?? .bottom
    }
}
