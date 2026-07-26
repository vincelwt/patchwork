import Foundation

/// A lossless-enough JSON tree for reading server payloads we don't have strong models for yet
/// (e.g. the `/v1/limits` report) and for rendering unknown SSE event data. Mirrors the pattern
/// used elsewhere in this repo: unknown shapes degrade to something bounded and visible instead
/// of crashing the decoder.
enum JSONValue: Codable, Equatable {
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
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
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

    static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Round-trips through `Data` to land on a concrete Codable type. Used for SSE event data,
    /// which arrives as an untyped `JSONValue` since the event name (not its shape) says what it is.
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    subscript(key: String) -> JSONValue? {
        guard case let .object(value) = self else { return nil }
        return value[key]
    }

    var stringValue: String? {
        switch self {
        case let .string(value): return value
        case let .number(value): return String(value)
        case let .bool(value): return String(value)
        default: return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    /// Renders as indented "key: value" text, bounded in depth and line count so a huge or
    /// deeply-nested report can never blow up terminal output or memory.
    func renderedHuman(maxDepth: Int = 6, maxLines: Int = 400) -> String {
        var lines: [String] = []
        render(into: &lines, indent: 0, maxDepth: maxDepth, maxLines: maxLines)
        return lines.joined(separator: "\n")
    }

    private func render(into lines: inout [String], indent: Int, maxDepth: Int, maxLines: Int) {
        guard lines.count < maxLines else { return }
        let pad = String(repeating: "  ", count: indent)
        guard indent < maxDepth else {
            lines.append(pad + "…")
            return
        }
        switch self {
        case .null:
            lines.append(pad + "null")
        case let .bool(value):
            lines.append(pad + (value ? "true" : "false"))
        case let .number(value):
            lines.append(pad + Self.formatNumber(value))
        case let .string(value):
            lines.append(pad + value)
        case let .array(values):
            for value in values {
                if lines.count >= maxLines { lines.append(pad + "… (truncated)"); return }
                if case .object = value {
                    lines.append(pad + "-")
                    value.render(into: &lines, indent: indent + 1, maxDepth: maxDepth, maxLines: maxLines)
                } else {
                    lines.append(pad + "- " + (value.stringValue ?? value.renderedHuman(maxDepth: maxDepth - indent, maxLines: 1)))
                }
            }
        case let .object(values):
            for key in values.keys.sorted() {
                if lines.count >= maxLines { lines.append(pad + "… (truncated)"); return }
                guard let value = values[key] else { continue }
                switch value {
                case .object, .array:
                    lines.append(pad + key + ":")
                    value.render(into: &lines, indent: indent + 1, maxDepth: maxDepth, maxLines: maxLines)
                default:
                    lines.append(pad + key + ": " + (value.stringValue ?? "null"))
                }
            }
        }
    }

    private static func formatNumber(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}
