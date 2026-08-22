import Foundation
import HermternalCore
import Testing

@Test("a complete WebSocket JSON object decodes without a newline")
func completeWebSocketMessageFlushesImmediately() throws {
    let text = #"{"jsonrpc":"2.0","id":1,"result":{"sessions":[{"id":"session-1","title":"A chat","preview":"hello","started_at":1750000000.25,"message_count":3}]}}"#

    let frames = try GatewayClient.validateWebSocketFrames(from: text)
    #expect(frames.count == 1)

    let frame = try JSONDecoder().decode(JSONValue.self, from: try #require(frames.first))
    let sessionValue = try #require(frame["result"]?["sessions"]?.arrayValue?.first)
    let session = ChatSession(from: sessionValue)
    #expect(session.id == "session-1")
    #expect(session.messageCount == 3)
    #expect(session.startedAt == Date(timeIntervalSince1970: 1_750_000_000.25))
}

@Test("newline-separated WebSocket objects remain independently framed")
func newlineSeparatedWebSocketMessagesRemainSeparate() throws {
    let text = #"{"jsonrpc":"2.0","id":1,"result":{"sessions":[]}}"#
        + "\n"
        + #"{"jsonrpc":"2.0","id":2,"method":"event","params":{"type":"message.delta","payload":{"text":"hi"}}}"#

    let frames = try GatewayClient.validateWebSocketFrames(from: text)
    #expect(frames.count == 2)
}

@Test("malformed WebSocket input surfaces a decoding error")
func malformedWebSocketMessageIsNotSilent() throws {
    do {
        _ = try GatewayClient.validateWebSocketFrames(
            from: #"{"jsonrpc":"2.0","id":1,"result":{"sessions":[}}"#
        )
        Issue.record("malformed frame was accepted")
    } catch let error as GatewayError {
        #expect(error.localizedDescription.contains("Malformed gateway frame"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test("unroutable WebSocket replies surface an error")
func unroutableWebSocketReplyIsNotSilent() throws {
    do {
        _ = try GatewayClient.validateWebSocketFrames(
            from: #"{"jsonrpc":"2.0","id":"request-1","result":{"sessions":[]}}"#
        )
        Issue.record("unroutable frame was accepted")
    } catch let error as GatewayError {
        #expect(error.localizedDescription.contains("Unroutable gateway frame"))
        #expect(error.localizedDescription.contains("response id"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
