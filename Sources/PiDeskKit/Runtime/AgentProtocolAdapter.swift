import Foundation

/// What an adapter wants done with one outbound app command.
public enum AdapterOutbound {
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
    case immediate(PiJSONValue)
    /// Answer immediately and publish adapter-owned state changes in the same ordered delivery.
    /// Used when accepting a local queue operation changes UI state without a wire response.
    case immediateWithEvents(PiJSONValue, [PiJSONValue])
    /// This agent cannot do this at all. The caller gets a clear reason instead of a timeout.
    case unsupported(String)
}

/// One decoded inbound message, already expressed in the app's own vocabulary.
public enum AdapterInbound {
    /// Resolves the pending command registered under this correlation id.
    case response(id: String, value: PiJSONValue)
    /// A streaming event, shaped exactly like a Pi RPC event.
    case event(PiJSONValue)
}

/// Whether an uncorrelated UI answer was written, deliberately retained until more answers arrive,
/// or did not match adapter state at all. The last two cases both contain no bytes, but callers
/// such as the daemon must not report an accepted grouped answer as a delivery failure.
public enum AdapterUncorrelatedOutbound {
    case write([Data])
    case acceptedWithoutWrite
    case unmatched

    public var lines: [Data] {
        if case let .write(lines) = self { return lines }
        return []
    }

    public var wasAccepted: Bool {
        switch self {
        case .write, .acceptedWithoutWrite: true
        case .unmatched: false
        }
    }
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
public protocol AgentProtocolAdapter: AnyObject {
    var agent: AgentKind { get }

    /// Process arguments for this launch. `sessionPath` is the transcript to resume, if any.
    func launchArguments(sessionPath: URL?, cwd: URL) -> [String]

    /// Supplies the optional name for a fresh session before launch. Most agents name a session
    /// through their live protocol and inherit the no-op implementation. An agent whose first
    /// prompt creates the transcript can instead carry the name on its launch command.
    func prepareNewSession(name: String?)
    /// Supplies a preallocated identity when the agent can create or resume that exact session.
    /// The default preserves adapters whose server owns identity allocation.
    func prepareNewSession(id: String?, name: String?)

    /// Extra environment for this launch, merged over the shared agent environment.
    var environmentOverrides: [String: String] { get }

    /// Lines written immediately after spawn, before any user command.
    func startupLines(sessionPath: URL?, cwd: URL) -> [Data]

    /// Translates one app command. `id` is the correlation id the caller is waiting on.
    func encode(command: String, id: String, payload: [String: PiJSONValue]) -> AdapterOutbound

    /// Reverts bookkeeping performed by `encode` when the transport refuses the bytes before any
    /// write begins. Correlation FIFOs must not retain a command the process never received.
    func rollbackRejectedEncoding(command: String, id: String, payload: [String: PiJSONValue])

    /// Translates one uncorrelated app message (dialog answers, questionnaire replies).
    func encodeUncorrelated(_ value: PiJSONValue) -> [Data]

    /// Semantic variant used when the transport must distinguish a partial grouped answer from a
    /// stale or unknown dialog id. Adapters without grouped answers inherit the ordinary mapping.
    func encodeUncorrelatedWithDisposition(_ value: PiJSONValue) -> AdapterUncorrelatedOutbound

    /// Translates one inbound wire line into zero or more app-shaped messages.
    func decode(line: Data) -> [AdapterInbound]

    /// Called when the process is being torn down, so an adapter can drop per-session state.
    func reset()
}

public extension AgentProtocolAdapter {
    func prepareNewSession(name: String?) {}
    func prepareNewSession(id: String?, name: String?) {
        prepareNewSession(name: name)
    }
    func launchArguments(
        sessionPath: URL?, cwd: URL, initialSessionName: String?
    ) -> [String] {
        launchArguments(
            sessionPath: sessionPath, cwd: cwd,
            initialSessionID: nil, initialSessionName: initialSessionName
        )
    }
    func launchArguments(
        sessionPath: URL?, cwd: URL,
        initialSessionID: String?, initialSessionName: String?
    ) -> [String] {
        prepareNewSession(id: initialSessionID, name: initialSessionName)
        return launchArguments(sessionPath: sessionPath, cwd: cwd)
    }
    var environmentOverrides: [String: String] { [:] }
    func startupLines(sessionPath: URL?, cwd: URL) -> [Data] { [] }
    func rollbackRejectedEncoding(command: String, id: String, payload: [String: PiJSONValue]) {}
    func encodeUncorrelatedWithDisposition(_ value: PiJSONValue) -> AdapterUncorrelatedOutbound {
        let lines = encodeUncorrelated(value)
        return lines.isEmpty ? .unmatched : .write(lines)
    }
    func reset() {}
}

// MARK: - Adapter helpers

public enum AdapterEncoding {
    /// One JSONL line, LF-terminated, for anything already shaped as a `PiJSONValue`.
    /// Encoding a `PiJSONValue` cannot actually fail (it is closed over JSON-representable cases),
    /// and an adapter has nowhere useful to report it, so an impossible failure becomes an empty
    /// write that the transport already rejects as an invalid command.
    public static func line(_ value: PiJSONValue) -> Data { (try? value.encodedLine()) ?? Data() }

    /// One JSONL line from a loosely-typed dictionary, for protocols whose payloads are easier
    /// to express as literals than as `PiJSONValue` trees.
    public static func line(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        else { return nil }
        data.append(0x0A)
        return data
    }

    /// A Pi-shaped `response` envelope, which is what every completion handler expects.
    public static func response(id: String, data: PiJSONValue) -> PiJSONValue {
        .object(["type": .string("response"), "id": .string(id), "data": data])
    }

    public static func failure(id: String, message: String) -> PiJSONValue {
        .object(["type": .string("response"), "id": .string(id), "error": .string(message)])
    }

    /// A Pi-shaped event.
    public static func event(_ type: String, _ fields: [String: PiJSONValue] = [:]) -> PiJSONValue {
        var object = fields
        object["type"] = .string(type)
        return .object(object)
    }
}
