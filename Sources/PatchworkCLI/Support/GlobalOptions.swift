import Foundation
import PatchworkKit

/// Flags every command accepts, merged into each command's own `FlagSpec` list so they can
/// appear anywhere on the line (see `parseArgs`). `schedule add` is the one exception: it defines
/// its own `--timeout` (a run policy duration, not a request timeout) and shadows this one — see
/// `sharedSpecs(excluding:)`.
enum GlobalFlag {
    static let socket = FlagSpec("--socket", takesValue: true, placeholder: "PATH", help: "control socket path (default: ~/Library/Application Support/Patchwork/daemon.sock)")
    static let url = FlagSpec("--url", takesValue: true, placeholder: "URL", help: "talk to the loopback remote instead of the control socket, e.g. http://127.0.0.1:7717")
    static let token = FlagSpec("--token", takesValue: true, placeholder: "TOKEN", help: "bearer token for --url (default: $PATCHWORK_TOKEN)")
    static let timeout = FlagSpec("--timeout", takesValue: true, placeholder: "SECONDS", help: "per-request timeout in seconds (default: 10, or $PATCHWORK_TIMEOUT)")
    static let json = FlagSpec("--json", takesValue: false, help: "emit machine-readable JSON instead of human text")
    static let quiet = FlagSpec("--quiet", short: "-q", takesValue: false, help: "suppress incidental output; still prints requested data and errors")
    static let help = FlagSpec("--help", short: "-h", takesValue: false, help: "show this help")

    static let all: [FlagSpec] = [socket, url, token, timeout, json, quiet, help]

    /// `excludingTimeout: true` lets a command define its own `--timeout` with different
    /// semantics; the global request timeout then falls back to $PATCHWORK_TIMEOUT or the default.
    static func merged(into commandSpecs: [FlagSpec], excludingTimeout: Bool = false) -> [FlagSpec] {
        let shared = excludingTimeout ? all.filter { $0.long != "--timeout" } : all
        let commandLongNames = Set(commandSpecs.map(\.long))
        return commandSpecs + shared.filter { !commandLongNames.contains($0.long) }
    }
}

struct GlobalOptions {
    var socketPath: String
    var url: URL?
    var token: String?
    var timeoutSeconds: Double
    var jsonOutput: Bool
    var quiet: Bool

    var target: TransportTarget {
        if let url, let host = url.host {
            let port = UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))
            return .tcp(host: host, port: port)
        }
        return .unixSocket(path: socketPath)
    }

    /// `commandOwnsTimeout` is true only for `schedule add`, whose own `--timeout` means
    /// something else entirely (see GlobalFlag doc comment above).
    static func resolve(_ parsed: ParsedArgs, environment: [String: String], commandOwnsTimeout: Bool) throws -> GlobalOptions {
        let socketPath = parsed.value("--socket") ?? PatchworkPaths.controlSocket.path

        var url: URL?
        if let raw = parsed.value("--url") {
            guard let parsedURL = URL(string: raw), parsedURL.scheme != nil, parsedURL.host != nil else {
                throw UsageError.invalidValue(flag: "--url", value: raw, reason: "expected e.g. http://127.0.0.1:7717")
            }
            url = parsedURL
        }

        let token = parsed.value("--token") ?? environment["PATCHWORK_TOKEN"]

        var timeoutSeconds = 10.0
        if let raw = environment["PATCHWORK_TIMEOUT"], let value = Double(raw), value > 0 { timeoutSeconds = value }
        if !commandOwnsTimeout, let raw = parsed.value("--timeout") {
            guard let value = Double(raw), value > 0 else {
                throw UsageError.invalidValue(flag: "--timeout", value: raw, reason: "expected a positive number of seconds")
            }
            timeoutSeconds = value
        }

        return GlobalOptions(
            socketPath: socketPath,
            url: url,
            token: token,
            timeoutSeconds: timeoutSeconds,
            jsonOutput: parsed.flag("--json"),
            quiet: parsed.flag("--quiet")
        )
    }
}
