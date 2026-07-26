import Foundation

/// A lossless JSON boundary used wherever the control-plane API carries a payload this package
/// does not (yet) model explicitly: an SSE event whose name a client does not recognise, a
/// schedule trigger from a newer daemon, an extension's raw arguments. Mirrors the app's own
/// `JSONValue` shape so the two stay easy to reconcile if they are ever merged.
public enum PiJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PiJSONValue])
    case object([String: PiJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PiJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: PiJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Bridges a `JSONSerialization` result (`NSNull`/`Bool`/`NSNumber`/`String`/`[Any]`/
    /// `[String: Any]`) into this type. Any other dynamic type (should not occur for real JSON)
    /// falls back to its `String(describing:)` rather than throwing, since this initializer is
    /// not failable and the hot decode path must never crash on a surprising payload.
    public init(any: Any) {
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
            self = .array(value.map(PiJSONValue.init(any:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(PiJSONValue.init(any:)))
        default:
            self = .string(String(describing: any))
        }
    }

    public var objectValue: [String: PiJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var arrayValue: [PiJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .number(value): value.formatted()
        default: nil
        }
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        switch self {
        case let .number(value): value
        case let .string(value): Double(value)
        default: nil
        }
    }

    public var intValue: Int? { doubleValue.map(Int.init) }

    public subscript(key: String) -> PiJSONValue? { objectValue?[key] }

    /// Uses `JSONSerialization`, not the `Decodable` conformance above, on purpose: this is the
    /// hot path for scanning session JSONL (one call per line, files run tens of megabytes), and
    /// a native parse into `Any` is considerably faster here than `JSONDecoder`'s single-value-
    /// container trial-and-error over `Bool`/`Double`/`String`/`[Self]`/`[String: Self]` for
    /// every nested value. The `Decodable` conformance stays for the (much colder) case of a
    /// `PiJSONValue` nested inside another type's ordinary `Decodable` synthesis.
    public static func decode(_ data: Data) throws -> PiJSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return PiJSONValue(any: object)
    }

    /// Appends a trailing LF, the framing Pi's own RPC protocol and this API's SSE stream both use.
    public func encodedLine() throws -> Data {
        var data = try PiDeskJSON.encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
