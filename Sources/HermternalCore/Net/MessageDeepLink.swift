import Foundation

/// A gateway-authoritative deep link to one persisted transcript message.
///
/// The gateway host is part of the link's authority rather than application
/// state, so links from different backends cannot resolve to the wrong chat.
public struct MessageDeepLink: Hashable, Sendable {
    public static let scheme = "hermternal"

    public let gatewayHost: String
    public let location: MessageLocation

    /// Creates a link for a durable message location.
    ///
    /// A location cannot carry a provisional identity, so callers that start
    /// from `MessageIdentity` should use the identity overload below; it
    /// returns nil for live, unsaved rows.
    public init?(gatewayHost: String, location: MessageLocation) {
        let host = gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              !host.contains("/"),
              !host.contains(":"),
              !host.contains("?"),
              !host.contains("#"),
              !host.contains("@"),
              !host.unicodeScalars.contains(where: { $0.properties.isWhitespace }),
              !location.sessionID.isEmpty,
              !location.sessionID.contains("/"),
              !location.sessionID.contains("?"),
              !location.sessionID.contains("#")
        else { return nil }
        var authority = URLComponents()
        authority.scheme = Self.scheme
        authority.host = host
        guard authority.url != nil else { return nil }
        self.gatewayHost = host
        self.location = location
    }

    /// Creates a link only for a persisted server identity.
    public init?(
        gatewayHost: String,
        sessionID: String,
        messageIdentity: MessageIdentity
    ) {
        guard case .server(let messageID) = messageIdentity else { return nil }
        self.init(
            gatewayHost: gatewayHost,
            location: MessageLocation(sessionID: sessionID, messageID: messageID)
        )
    }

    /// Parses `hermternal://<gateway-host>/chat/<session-id>/message/<message-id>`.
    public init?(url: URL) {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        components.scheme == Self.scheme,
        components.user == nil,
        components.password == nil,
        components.query == nil,
        components.fragment == nil,
        let host = components.host,
        !host.isEmpty,
        components.port == nil
        else { return nil }

        let encodedSegments = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard encodedSegments.count == 5,
              encodedSegments[0].isEmpty,
              encodedSegments[1] == "chat",
              encodedSegments[3] == "message",
              let encodedSessionID = encodedSegments[safe: 2],
              let encodedMessageID = encodedSegments[safe: 4],
              let sessionID = String(encodedSessionID).removingPercentEncoding,
              let rawMessageID = String(encodedMessageID).removingPercentEncoding,
              !sessionID.isEmpty,
              !rawMessageID.isEmpty,
              rawMessageID.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value)
              }),
              !sessionID.contains("/"),
              !rawMessageID.contains("/"),
              let messageID = Int64(rawMessageID)
        else { return nil }

        self.gatewayHost = host
        self.location = MessageLocation(
            sessionID: sessionID,
            messageID: ServerMessageID(rawValue: messageID)
        )
    }

    /// The canonical URL representation of this link.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = gatewayHost
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let session = location.sessionID.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? location.sessionID
        components.percentEncodedPath = "/chat/\(session)/message/\(location.messageID.rawValue)"
        // The initializer validates the host and path components, so this is
        // guaranteed for every value representable by MessageDeepLink.
        return components.url!
    }

    /// Convenience spelling for consumers that need to distinguish this
    /// value from other URL properties.
    public var serializedURL: URL { url }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
