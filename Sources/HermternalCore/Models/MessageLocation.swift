import Foundation

/// A durable location within a persisted chat transcript.
public struct MessageLocation: Hashable, Sendable {
    public let sessionID: String
    public let messageID: ServerMessageID

    public init(sessionID: String, messageID: ServerMessageID) {
        self.sessionID = sessionID
        self.messageID = messageID
    }
}
