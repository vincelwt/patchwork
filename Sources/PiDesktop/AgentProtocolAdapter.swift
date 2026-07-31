import Foundation
import PiDeskKit

/// What an adapter wants done with one outbound app command.
enum AdapterOutbound {
    /// Write these JSONL lines to the agent's stdin. The completion resolves when the adapter
    /// later decodes a `.response` carrying the same correlation id.
    case write([Data])
    /// Register the pending completion but write nothing yet: the adapter is holding this command
    /// until a handshake finishes, and will put it on the wire itself. The caller still resolves
    /// through the same correlation id, and still times out on the normal schedule if the
    /// handshake never completes.
    case deferred
    /// Answer the caller immediately without touching the process. Used for facts the adapter
    /// already knows (the model list it cached at startup, the current session id).
    case immediate(JSONValue)
    /// This agent cannot do this at all. The caller gets a clear reason instead of a timeout.
    case unsupported(String)
}

/// One decoded inbound message, already expressed in the app's own vocabulary.
enum AdapterInbound {
    /// Resolves the pending command registered under this correlation id.
    case response(id: String, value: JSONValue)
    /// A streaming event, shaped exactly like a Pi RPC event.
    case event(JSONValue)
}

/// Translates between Pi Desktop's internal command/event vocabulary and one agent's native
/// protocol.
///
/// The app's vocabulary *is* Pi's RPC vocabulary. That is not a privilege granted to Pi, it is
/// simply the shape the app already speaks fluently: keeping one vocabulary means adding an
/// agent never touches the store's event handling, the transcript projection, or the tests
/// around them. Pi's adapter is the identity translation; the others do real work.
///
/// Every method is called serially on the transport's IO queue, so implementations may hold
/// mutable state without locking.
protocol AgentProtocolAdapter: AnyObject {
    var agent: AgentKind { get }

    /// Process arguments for this launch. `sessionPath` is the transcript to resume, if any.
    func launchArguments(sessionPath: URL?, cwd: URL) -> [String]

    /// Extra environment for this launch, merged over the shared agent environment.
    var environmentOverrides: [String: String] { get }

    /// Lines written immediately after spawn, before any user command.
    func startupLines(sessionPath: URL?, cwd: URL) -> [Data]

    /// Translates one app command. `id` is the correlation id the caller is waiting on.
    func encode(command: String, id: String, payload: [String: JSONValue]) -> AdapterOutbound

    /// Translates one uncorrelated app message (dialog answers, questionnaire replies).
    func encodeUncorrelated(_ value: JSONValue) -> [Data]

    /// Translates one inbound wire line into zero or more app-shaped messages.
    func decode(line: Data) -> [AdapterInbound]

    /// Called when the process is being torn down, so an adapter can drop per-session state.
    func reset()
}

extension AgentProtocolAdapter {
    var environmentOverrides: [String: String] { [:] }
    func startupLines(sessionPath: URL?, cwd: URL) -> [Data] { [] }
    func reset() {}
}

// MARK: - Adapter helpers

enum AdapterEncoding {
    /// One JSONL line, LF-terminated, for anything already shaped as a `JSONValue`.
    /// Encoding a `JSONValue` cannot actually fail (it is closed over JSON-representable cases),
    /// and an adapter has nowhere useful to report it, so an impossible failure becomes an empty
    /// write that the transport already rejects as an invalid command.
    static func line(_ value: JSONValue) -> Data { (try? value.encodedLine()) ?? Data() }

    /// One JSONL line from a loosely-typed dictionary, for protocols whose payloads are easier
    /// to express as literals than as `JSONValue` trees.
    static func line(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        else { return nil }
        data.append(0x0A)
        return data
    }

    /// A Pi-shaped `response` envelope, which is what every completion handler expects.
    static func response(id: String, data: JSONValue) -> JSONValue {
        .object(["type": .string("response"), "id": .string(id), "data": data])
    }

    static func failure(id: String, message: String) -> JSONValue {
        .object(["type": .string("response"), "id": .string(id), "error": .string(message)])
    }

    /// A Pi-shaped event.
    static func event(_ type: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
        var object = fields
        object["type"] = .string(type)
        return .object(object)
    }
}

/// Converts a `JSONSerialization` tree into the app's `JSONValue`. Adapters build their
/// translations with dictionaries and hand the result over once.
extension JSONValue {
    init(loose value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let bool as Bool:
            self = .bool(bool)
        case let number as NSNumber:
            // NSNumber erases Bool into a number; CFBoolean identity is the only reliable check.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSONValue(loose: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { JSONValue(loose: $0) })
        default:
            self = .null
        }
    }

    /// Back to a `JSONSerialization` tree, for building native protocol payloads out of app
    /// values (prompt text, image attachments) without hand-writing conversions.
    var looseValue: Any {
        switch self {
        case .null: NSNull()
        case let .bool(value): value
        case let .number(value): value
        case let .string(value): value
        case let .array(values): values.map(\.looseValue)
        case let .object(values): values.mapValues(\.looseValue)
        }
    }
}
