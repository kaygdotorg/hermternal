import Foundation

/// A gateway-authoritative deep link to a chat or one persisted transcript
/// message.
///
/// The gateway host is part of the link's authority rather than application
/// state, so links from different backends cannot resolve to the wrong chat.
public struct MessageDeepLink: Hashable, Sendable {
    public enum Destination: Hashable, Sendable {
        case chat(sessionID: String)
        case message(MessageLocation)
    }

    public static let scheme = "hermternal"

    public let gatewayHost: String
    public let destination: Destination

    /// Creates a link for a durable message location.
    ///
    /// A location cannot carry a provisional identity, so callers that start
    /// from `MessageIdentity` should use the identity overload below; it
    /// returns nil for live, unsaved rows.
    /// Creates a link for a chat without selecting a message.
    public init?(gatewayHost: String, sessionID: String) {
        let host = gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidHost(host), Self.isValidSessionID(sessionID) else { return nil }
        self.gatewayHost = host
        self.destination = .chat(sessionID: sessionID)
    }

    /// Creates a link for a durable message location.
    public init?(gatewayHost: String, location: MessageLocation) {
        let host = gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidHost(host), Self.isValidSessionID(location.sessionID) else { return nil }
        self.gatewayHost = host
        self.destination = .message(location)
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

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty,
              !host.contains("/"),
              !host.contains(":"),
              !host.contains("?"),
              !host.contains("#"),
              !host.contains("@"),
              !host.unicodeScalars.contains(where: { $0.properties.isWhitespace })
        else { return false }
        var authority = URLComponents()
        authority.scheme = Self.scheme
        authority.host = host
        return authority.url != nil
    }

    private static func isValidSessionID(_ sessionID: String) -> Bool {
        !sessionID.isEmpty && !sessionID.contains("/") && !sessionID.contains("?")
            && !sessionID.contains("#")
    }

    private static func isParsedSessionID(_ sessionID: String) -> Bool {
        // Preserve the legacy parser's accepted percent-encoded characters.
        !sessionID.isEmpty && !sessionID.contains("/")
    }


    /// Parses `hermternal://<gateway-host>/chat/<session-id>/message/<message-id>`.
    /// Parses `hermternal://<gateway-host>/chat/<session-id>` or the
    /// message form with `/message/<message-id>` appended.
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
        Self.isValidHost(host),
        components.port == nil
        else { return nil }

        let encodedSegments = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard encodedSegments.count == 3 || encodedSegments.count == 5,
              encodedSegments[0].isEmpty,
              encodedSegments[1] == "chat",
              let encodedSessionID = encodedSegments[safe: 2],
              let sessionID = String(encodedSessionID).removingPercentEncoding,
              Self.isParsedSessionID(sessionID)
        else { return nil }

        if encodedSegments.count == 3 {
            self.gatewayHost = host
            self.destination = .chat(sessionID: sessionID)
            return
        }

        guard encodedSegments[3] == "message",
              let encodedMessageID = encodedSegments[safe: 4],
              let rawMessageID = String(encodedMessageID).removingPercentEncoding,
              !rawMessageID.isEmpty,
              rawMessageID.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value)
              }),
              let messageID = Int64(rawMessageID)
        else { return nil }

        self.gatewayHost = host
        self.destination = .message(
            MessageLocation(
                sessionID: sessionID,
                messageID: ServerMessageID(rawValue: messageID)
            )
        )
    }

    /// The canonical URL representation of this link.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = gatewayHost
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        switch destination {
        case .chat(let sessionID):
            let session = sessionID.addingPercentEncoding(withAllowedCharacters: allowed)
                ?? sessionID
            components.percentEncodedPath = "/chat/\(session)"
        case .message(let location):
            let session = location.sessionID.addingPercentEncoding(withAllowedCharacters: allowed)
                ?? location.sessionID
            components.percentEncodedPath = "/chat/\(session)/message/\(location.messageID.rawValue)"
        }
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
