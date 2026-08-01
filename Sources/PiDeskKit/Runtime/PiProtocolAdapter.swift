import Foundation

/// Pi speaks the app's vocabulary natively, so this adapter is a pass-through.
///
/// It exists so Pi goes through exactly the same seam as every other agent: there is no
/// "default" path that skips translation, which is what keeps the transport honest and stops
/// Pi-only assumptions from creeping back into it.
public final class PiProtocolAdapter: AgentProtocolAdapter {
    public let agent: AgentKind = .pi
    private var initialSessionID: String?
    private var initialSessionName: String?

    public init() {}

    public func prepareNewSession(id: String?, name: String?) {
        initialSessionID = id
        initialSessionName = name
    }

    public func launchArguments(sessionPath: URL?, cwd: URL) -> [String] {
        var arguments = ["--mode", "rpc"]
        if let sessionPath {
            arguments += ["--session", sessionPath.path]
        } else {
            if let initialSessionID { arguments += ["--session-id", initialSessionID] }
            if let initialSessionName { arguments += ["--name", initialSessionName] }
        }
        return arguments
    }

    public func reset() {
        initialSessionID = nil
        initialSessionName = nil
    }

    public func encode(command: String, id: String, payload: [String: PiJSONValue]) -> AdapterOutbound {
        var object = payload
        object["type"] = .string(command)
        object["id"] = .string(id)
        return .write([AdapterEncoding.line(.object(object))])
    }

    public func encodeUncorrelated(_ value: PiJSONValue) -> [Data] {
        [AdapterEncoding.line(value)]
    }

    public func decode(line: Data) -> [AdapterInbound] {
        guard let value = try? PiJSONValue.decode(line) else { return [] }
        if value["type"]?.stringValue == "response", let id = value["id"]?.stringValue {
            return [.response(id: id, value: value)]
        }
        return [.event(value)]
    }
}
