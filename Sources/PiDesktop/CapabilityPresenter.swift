import Foundation

enum ToolCapabilityKind: String, Hashable, Sendable {
    case browser = "Browser"
    case computer = "Computer"

    var symbol: String { self == .browser ? "safari" : "display" }
}

struct ToolCapability: Equatable, Hashable, Sendable {
    let kind: ToolCapabilityKind
    let sourceID: String
    let title: String
    let target: String?
}

/// Extracts a useful capability target from both today's tool schemas and future nested argument
/// shapes. Unknown fields are ignored and retained elsewhere by the normal tool fallback.
enum CapabilityPresenter {
    static func capability(toolName: String, callID: String, arguments: JSONValue) -> ToolCapability? {
        let normalized = toolName.lowercased()
        let kind: ToolCapabilityKind
        if normalized == "chrome_js" || normalized.hasPrefix("chrome_") {
            kind = .browser
        } else if ["computer_js", "observe_ui", "act_ui", "find_roots"].contains(normalized) {
            kind = .computer
        } else {
            return nil
        }

        let title = firstString(in: arguments, keys: ["title", "task", "action", "prompt"])
        let target: String?
        switch kind {
        case .browser:
            target = firstString(in: arguments, keys: ["url", "selector", "target", "tab", "query"])
                ?? firstURL(in: arguments)
                ?? "Current browser session"
        case .computer:
            target = firstString(in: arguments, keys: ["app", "application", "target", "selector", "element"])
                ?? firstAppReference(in: arguments)
                ?? "macOS"
        }
        return ToolCapability(
            kind: kind,
            sourceID: callID,
            title: clean(title) ?? defaultTitle(toolName: normalized, kind: kind),
            target: clean(target)
        )
    }

    private static func defaultTitle(toolName: String, kind: ToolCapabilityKind) -> String {
        let readable = toolName.replacingOccurrences(of: "_", with: " ").capitalizedFirstWord
        return readable.isEmpty ? "Using \(kind.rawValue.lowercased())" : readable
    }

    private static func firstString(in value: JSONValue, keys: [String], depth: Int = 0) -> String? {
        guard depth < 4 else { return nil }
        switch value {
        case let .object(object):
            for key in keys {
                if let match = object.first(where: { $0.key.lowercased() == key.lowercased() })?.value.stringValue,
                   !match.isEmpty {
                    return match
                }
            }
            for key in object.keys.sorted() {
                if let nested = firstString(in: object[key] ?? .null, keys: keys, depth: depth + 1) { return nested }
            }
        case let .array(values):
            for nestedValue in values.prefix(20) {
                if let nested = firstString(in: nestedValue, keys: keys, depth: depth + 1) { return nested }
            }
        default:
            break
        }
        return nil
    }

    private static func firstURL(in value: JSONValue) -> String? {
        guard let text = firstStringValue(in: value),
              let range = text.range(of: #"https?://[^\s\"']+"#, options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "),.;"))
    }

    private static func firstAppReference(in value: JSONValue) -> String? {
        guard let text = firstStringValue(in: value) else { return nil }
        for pattern in [#"app\s*:\s*\"([^\"]+)\""#, #"app\s*:\s*'([^']+)'"#] {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range])
        }
        return nil
    }

    private static func firstStringValue(in value: JSONValue, depth: Int = 0) -> String? {
        guard depth < 4 else { return nil }
        switch value {
        case let .string(text): return text
        case let .object(object):
            for key in object.keys.sorted() {
                if let found = firstStringValue(in: object[key] ?? .null, depth: depth + 1) { return found }
            }
        case let .array(values):
            for nested in values.prefix(20) {
                if let found = firstStringValue(in: nested, depth: depth + 1) { return found }
            }
        default: break
        }
        return nil
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let compact = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        return compact.count <= 180 ? compact : String(compact.prefix(179)) + "…"
    }
}
