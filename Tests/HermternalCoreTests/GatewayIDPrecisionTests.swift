import Foundation
import HermternalCore
import Testing

private func gatewayEvent(payload: String) throws -> GatewayEvent {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
    return GatewayEvent(type: "message", sessionID: nil, payload: value)
}

@Test("Gateway event IDs preserve integers beyond IEEE-754 precision")
func gatewayEventIDPreservesExactValue() throws {
    let event = try gatewayEvent(payload: "{\"id\":9007199254740993}")

    #expect(event.serverMessageID == ServerMessageID(rawValue: 9_007_199_254_740_993))
}

@Test("Adjacent large gateway event IDs remain distinct")
func gatewayEventAdjacentIDsRemainDistinct() throws {
    let first = try gatewayEvent(payload: "{\"id\":9007199254740993}")
    let second = try gatewayEvent(payload: "{\"id\":9007199254740994}")

    #expect(first.serverMessageID != second.serverMessageID)
}

@Test("Invalid gateway event IDs become provisional without trapping")
func gatewayEventInvalidIDsAreProvisional() throws {
    let fractional = try gatewayEvent(payload: "{\"id\":1.5}")
    let outOfRange = try gatewayEvent(payload: "{\"id\":9223372036854775808}")

    #expect(fractional.serverMessageID == nil)
    #expect(outOfRange.serverMessageID == nil)
}

@Test("Gateway event integer IDs decode normally")
func gatewayEventIntegerIDDecodes() throws {
    let event = try gatewayEvent(payload: "{\"id\":42}")

    #expect(event.serverMessageID == ServerMessageID(rawValue: 42))
}

@Test("Gateway row_id alias preserves exact integer")
func gatewayEventRowIDAliasPreservesExactValue() throws {
    let event = try gatewayEvent(payload: "{\"row_id\":9007199254740993}")

    #expect(event.serverMessageID == ServerMessageID(rawValue: 9_007_199_254_740_993))
}
