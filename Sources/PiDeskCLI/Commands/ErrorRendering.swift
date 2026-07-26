import Foundation

/// Converts anything a command can throw into one `CLIFailure`, so there is exactly one place
/// that decides exit codes from errors. Unreachable-daemon messages are short and actionable
/// per the contract ("never a stack trace").
func asFailure(_ error: Error) -> CLIFailure {
    switch error {
    case let failure as CLIFailure:
        return failure
    case let usage as UsageError:
        return usage.asFailure()
    case let plane as ControlPlaneError:
        return failure(for: plane)
    default:
        return CLIFailure(exitCode: .requestFailed, message: truncated("\(error)", max: 500))
    }
}

private func failure(for error: ControlPlaneError) -> CLIFailure {
    switch error {
    case let .unreachable(reason):
        return CLIFailure(
            exitCode: .unreachable,
            message: "cannot reach the Pi Desktop daemon (\(reason))",
            hint: "start it with `pidesk daemon start` (or `pidesk daemon install` to run at login); check `pidesk daemon status`"
        )
    case let .timedOut(reason):
        return CLIFailure(exitCode: .requestFailed, message: reason)
    case let .apiError(status, code, message):
        return CLIFailure(exitCode: .requestFailed, message: "\(code): \(message) (HTTP \(status))")
    case let .malformedResponse(reason):
        return CLIFailure(exitCode: .requestFailed, message: "unexpected response from daemon: \(reason)")
    case let .transportFailure(reason):
        return CLIFailure(exitCode: .requestFailed, message: reason)
    }
}

/// The JSON shape for a failed `daemon status --json`, distinct from a thrown `CLIFailure`
/// because that command's whole job is to report reachability, not just error out silently.
/// `mode` is additive alongside the original `ok`/`error` fields — unreachable does not mean
/// "unknown": a LaunchAgent between restarts is still reported as such.
struct JSONErrorEnvelope: Codable, Equatable {
    var ok = false
    var mode: String
    var error: Detail
    struct Detail: Codable, Equatable { var code: String; var message: String }

    init(code: String, message: String, mode: String) {
        self.mode = mode
        error = Detail(code: code, message: message)
    }
}
