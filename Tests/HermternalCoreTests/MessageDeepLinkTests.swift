import Foundation
import HermternalCore
import Testing

@Test("message deep links round trip their location and gateway")
func messageDeepLinkRoundTrip() throws {
    let location = MessageLocation(
        sessionID: "session with spaces",
        messageID: ServerMessageID(rawValue: 42)
    )
    let link = try #require(MessageDeepLink(gatewayHost: "alpha.example", location: location))
    let parsed = try #require(MessageDeepLink(url: link.url))

    #expect(parsed == link)
    #expect(parsed.destination == .message(location))
    #expect(parsed.url.absoluteString == "hermternal://alpha.example/chat/session%20with%20spaces/message/42")
}

@Test("chat deep links round trip without a message target")
func chatDeepLinkRoundTrip() throws {
    let link = try #require(
        MessageDeepLink(gatewayHost: "alpha.example", sessionID: "session with spaces")
    )
    let parsed = try #require(MessageDeepLink(url: link.url))

    #expect(parsed == link)
    #expect(parsed.destination == .chat(sessionID: "session with spaces"))
    #expect(parsed.url.absoluteString == "hermternal://alpha.example/chat/session%20with%20spaces")
}

@Test("deep-link parser accepts only chat and message shapes")
func deepLinkParserRejectsOtherPathShapes() {
    let malformed = [
        "hermternal://alpha.example/chat/session/",
        "hermternal://alpha.example/chat/session/message",
        "hermternal://alpha.example/chat/session/message/1/extra",
        "hermternal://alpha.example/chat/session/message/",
        "hermternal://alpha.example/chat/session/message/-1"
    ]

    for raw in malformed {
        #expect(URL(string: raw).flatMap(MessageDeepLink.init(url:)) == nil, "accepted \(raw)")
    }
}

@Test("message deep links preserve the backend authority")
func messageDeepLinkPreservesHost() throws {
    let location = MessageLocation(sessionID: "chat-1", messageID: ServerMessageID(rawValue: 7))
    let first = try #require(MessageDeepLink(gatewayHost: "one.example", location: location))
    let second = try #require(MessageDeepLink(gatewayHost: "two.example", location: location))

    #expect(first.url.host == "one.example")
    #expect(second.url.host == "two.example")
    #expect(first.url != second.url)
    #expect(MessageDeepLink(url: first.url)?.gatewayHost == "one.example")
    #expect(MessageDeepLink(url: second.url)?.gatewayHost == "two.example")
}

@Test("malformed message deep links are rejected")
func malformedMessageDeepLinksAreRejected() {
    let malformed = [
        "https://alpha.example/chat/session/message/1",
        "hermternal:///chat/session/message/1",
        "hermternal://alpha.example/chat/session/1",
        "hermternal://alpha.example/chat//message/1",
        "hermternal://alpha.example/chat/session/message/not-an-id",
        "hermternal://alpha.example/chat/session/message/1?other=backend",
        "hermternal://alpha.example/chat/session/message/1#fragment",
        "hermternal://user@alpha.example/chat/session/message/1",
        "hermternal://alpha.example:443/chat/session/message/1"
    ]

    for raw in malformed {
        let url = URL(string: raw)
        #expect(url.flatMap(MessageDeepLink.init(url:)) == nil, "accepted \(raw)")
    }
}

@Test("provisional identities cannot become message deep links")
func provisionalMessageIdentityIsRejected() {
    let identity = MessageIdentity.provisional(UUID())
    #expect(
        MessageDeepLink(
            gatewayHost: "alpha.example",
            sessionID: "session",
            messageIdentity: identity
        ) == nil
    )
}
