import Foundation

/// Exit codes are part of the contract (docs/daemon-api.md, "CLI surface"): scripts and other
/// agents branch on these, so they must stay exactly as documented.
enum ExitCode: Int32 {
    case ok = 0
    case requestFailed = 1
    case badUsage = 2
    case unreachable = 3
}

/// The one error type every command path converges on. Carries its own exit code so the
/// top-level runner never has to guess how to map a failure.
struct CLIFailure: Error {
    var exitCode: ExitCode
    var message: String
    var hint: String?

    init(exitCode: ExitCode, message: String, hint: String? = nil) {
        self.exitCode = exitCode
        self.message = message
        self.hint = hint
    }

    static func badUsage(_ message: String, hint: String? = nil) -> CLIFailure {
        CLIFailure(exitCode: .badUsage, message: message, hint: hint)
    }
}

/// Bad-usage errors raised while tokenizing/validating argv. Kept separate from `CLIFailure` so
/// argument parsers stay free of exit-code plumbing; `asFailure()` does the one conversion.
enum UsageError: Error {
    case unknownFlag(String)
    case missingValue(String)
    case flagTakesNoValue(String, String)
    case unexpectedPositional(String)
    case missingPositional(String)
    case tooManyPositionals(expected: Int, got: Int)
    case conflictingFlags([String])
    case missingRequiredFlag(String)
    case invalidValue(flag: String, value: String, reason: String)
    case custom(String)

    var message: String {
        switch self {
        case let .unknownFlag(name):
            return "unknown flag \(name)"
        case let .missingValue(name):
            return "\(name) requires a value"
        case let .flagTakesNoValue(name, value):
            return "\(name) does not take a value (got \"\(value)\")"
        case let .unexpectedPositional(value):
            return "unexpected argument \"\(value)\""
        case let .missingPositional(name):
            return "missing required argument <\(name)>"
        case let .tooManyPositionals(expected, got):
            return "expected \(expected) argument(s), got \(got)"
        case let .conflictingFlags(names):
            return "\(names.joined(separator: " and ")) cannot be used together"
        case let .missingRequiredFlag(name):
            return "missing required flag \(name)"
        case let .invalidValue(flag, value, reason):
            return "invalid value \"\(value)\" for \(flag): \(reason)"
        case let .custom(message):
            return message
        }
    }

    func asFailure() -> CLIFailure {
        .badUsage(message)
    }
}
