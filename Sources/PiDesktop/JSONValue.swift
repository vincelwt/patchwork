import Foundation

/// A lossless-enough JSON boundary for Pi's evolving RPC and session schemas.
/// Known fields are projected into app models while the original payload remains available.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map(JSONValue.init(any:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init(any:)))
        default:
            self = .string(String(describing: any))
        }
    }

    var anyValue: Any {
        switch self {
        case .null: NSNull()
        case let .bool(value): value
        case let .number(value): value
        case let .string(value): value
        case let .array(value): value.map(\.anyValue)
        case let .object(value): value.mapValues(\.anyValue)
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        switch self {
        case let .string(value): return value
        case let .number(value): return value.formatted()
        default: return nil
        }
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        switch self {
        case let .number(value): return value
        case let .string(value): return Double(value)
        default: return nil
        }
    }

    var intValue: Int? {
        doubleValue.map(Int.init)
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    func prettyPrinted(maxLength: Int = 12_000) -> String {
        guard JSONSerialization.isValidJSONObject(anyValue),
              let data = try? JSONSerialization.data(withJSONObject: anyValue, options: [.prettyPrinted, .sortedKeys]),
              let value = String(data: data, encoding: .utf8)
        else {
            let fallback = String(describing: anyValue)
            return fallback.count > maxLength ? String(fallback.prefix(maxLength)) + "…" : fallback
        }

        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength)) + "\n…"
    }

    /// Produces a bounded fallback without retaining the original JSON tree.
    func boundedFallback(maxLength: Int = 8_000) -> JSONValue {
        .string(prettyPrinted(maxLength: maxLength))
    }

    /// Keeps a shallow projected object while bounding large extension strings/arrays.
    func boundedProjection(depth: Int = 0, stringLimit: Int = 2_000, itemLimit: Int = 40) -> JSONValue {
        guard depth < 4 else { return boundedFallback(maxLength: stringLimit) }
        switch self {
        case let .string(value):
            return .string(value.count > stringLimit ? String(value.prefix(stringLimit)) + "…" : value)
        case let .array(values):
            return .array(values.prefix(itemLimit).map { $0.boundedProjection(depth: depth + 1, stringLimit: stringLimit, itemLimit: itemLimit) })
        case let .object(values):
            return .object(values.mapValues { $0.boundedProjection(depth: depth + 1, stringLimit: stringLimit, itemLimit: itemLimit) })
        default:
            return self
        }
    }

    static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    var jsonValue: JSONValue { .object(self) }
}
