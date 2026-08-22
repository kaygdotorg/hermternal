import Foundation
import HermternalCore
import Testing

@Test("JSON integers preserve values beyond the IEEE-754 exact range")
func jsonIntegersPreserveExactValues() throws {
    let first = try JSONDecoder().decode(
        JSONValue.self,
        from: Data("9007199254740993".utf8)
    )
    let second = try JSONDecoder().decode(
        JSONValue.self,
        from: Data("9007199254740994".utf8)
    )

    #expect(first.int64Value == 9_007_199_254_740_993)
    #expect(second.int64Value == 9_007_199_254_740_994)
    #expect(first.int64Value != second.int64Value)
}

@Test("JSON integer accessor accepts the Int64 boundaries")
func jsonIntegerBoundariesAreChecked() throws {
    let minimum = try JSONDecoder().decode(
        JSONValue.self,
        from: Data("-9223372036854775808".utf8)
    )
    let maximum = try JSONDecoder().decode(
        JSONValue.self,
        from: Data("9223372036854775807".utf8)
    )
    let outOfRange = try JSONDecoder().decode(
        JSONValue.self,
        from: Data("9223372036854775808".utf8)
    )

    #expect(minimum.int64Value == Int64.min)
    #expect(maximum.int64Value == Int64.max)
    #expect(outOfRange.int64Value == nil)
    #expect(JSONValue.number(Double(Int64.max)).int64Value == nil)
    #expect(JSONValue.number(-Double(Int64.max) * 2).int64Value == nil)
    #expect(JSONValue.number(1.25).int64Value == nil)
}

@Test("JSON integer and double cases survive Codable and JSONSerialization")
func jsonNumberCasesRoundTrip() throws {
    let original: [JSONValue] = [
        .integer(9_007_199_254_740_993),
        .number(1.25)
    ]
    let encoded = try JSONEncoder().encode(original)
    let object = try JSONSerialization.jsonObject(with: encoded)
    let reserialized = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode([JSONValue].self, from: reserialized)

    #expect(decoded.count == 2)
    #expect(decoded[0].int64Value == 9_007_199_254_740_993)
    #expect(decoded[1].doubleValue == 1.25)
    if case .integer = decoded[0] {
        // Expected: JSONSerialization and Codable retain the integer token.
    } else {
        Issue.record("The integer JSON token decoded as a floating-point number")
    }
    if case .number = decoded[1] {
        // Expected: the fractional token remains a double.
    } else {
        Issue.record("The fractional JSON token decoded as an integer")
    }
}

@Test("REST projection uses checked Int64 server IDs")
func restProjectionRejectsUnsafeIDs() {
    let rows = [
        historyRow(id: .integer(9_007_199_254_740_993), text: "first"),
        historyRow(id: .integer(9_007_199_254_740_994), text: "second"),
        historyRow(id: .number(1.5), text: "fractional"),
        historyRow(id: .number(Double(Int64.max)), text: "out of range")
    ]

    let messages = ChatMessage.projectREST(historyRows: rows)
    #expect(messages.count == 2)
    #expect(messages[0].id == .server(ServerMessageID(rawValue: 9_007_199_254_740_993)))
    #expect(messages[1].id == .server(ServerMessageID(rawValue: 9_007_199_254_740_994)))
}

@Test("date parser accepts Unix seconds and milliseconds")
func dateParserAcceptsEpochUnits() {
    let seconds = DateParser.date(from: .integer(1_750_000_000))
    let milliseconds = DateParser.date(from: .integer(1_750_000_000_000))
    let floatingMilliseconds = DateParser.date(from: .number(1_750_000_000_000))

    #expect(seconds == Date(timeIntervalSince1970: 1_750_000_000))
    #expect(milliseconds == Date(timeIntervalSince1970: 1_750_000_000))
    #expect(floatingMilliseconds == Date(timeIntervalSince1970: 1_750_000_000))
}

@Test("date parser accepts fractional and nonfractional ISO8601")
func dateParserAcceptsISO8601Variants() {
    let plain = DateParser.date(from: .string("2026-08-22T10:20:30Z"))
    let fractional = DateParser.date(from: .string("2026-08-22T10:20:30.125Z"))

    #expect(plain != nil)
    #expect(fractional != nil)
    if let plain, let fractional {
        #expect(abs(fractional.timeIntervalSince(plain) - 0.125) < 0.001)
    }
}

@Test("date parser rejects invalid values")
func dateParserRejectsInvalidValues() {
    #expect(DateParser.date(from: .string("not-a-date")) == nil)
    #expect(DateParser.date(from: .bool(true)) == nil)
    #expect(DateParser.date(from: .number(.infinity)) == nil)
    #expect(DateParser.date(from: .null) == nil)
}

private func historyRow(id: JSONValue, text: String) -> JSONValue {
    .object([
        "id": id,
        "role": .string("assistant"),
        "text": .string(text)
    ])
}
