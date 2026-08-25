import Foundation

/// Minimal dynamic JSON tree for gateway and REST payloads.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    /// A JSON integer that is exactly representable by `Int64`.
    case integer(Int64)
    /// A JSON number with a fractional component (or an integral value that
    /// was supplied as a floating-point value).
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard let value = int64Value else { return nil }
        return Int(exactly: value)
    }

    /// Returns an integral JSON number only when it is representable as
    /// `Int64`. Fractional, non-finite, and out-of-range values are rejected.
    public var int64Value: Int64? {
        switch self {
        case .integer(let value):
            return value
        case .number(let value):
            guard value.isFinite else { return nil }
            return Int64(exactly: value)
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}
