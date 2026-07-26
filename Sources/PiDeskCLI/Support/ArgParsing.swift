import Foundation

/// Declares one flag a command accepts. `long` is canonical and always used as the lookup key
/// in `ParsedArgs`, even when the user typed the short form.
struct FlagSpec {
    let long: String
    let short: String?
    let takesValue: Bool
    let placeholder: String
    let help: String

    init(_ long: String, short: String? = nil, takesValue: Bool, placeholder: String = "", help: String) {
        self.long = long
        self.short = short
        self.takesValue = takesValue
        self.placeholder = placeholder
        self.help = help
    }

    var synopsis: String {
        let names = [short, long].compactMap { $0 }.joined(separator: ", ")
        return takesValue ? "\(names) \(placeholder)" : names
    }
}

struct ParsedArgs {
    var values: [String: String] = [:]
    var switches: Set<String> = []
    var positionals: [String] = []

    func value(_ long: String) -> String? { values[long] }
    func flag(_ long: String) -> Bool { switches.contains(long) }
}

/// Hand-rolled flag/positional splitter shared by every command. Flags may appear before, after,
/// or interleaved with positionals (so `pidesk threads list --json` and `pidesk threads --json
/// list` style ordering both work at the leaf level). `--` stops flag parsing so an argument that
/// legitimately starts with "-" (e.g. message text) can be passed through untouched.
///
/// `specs` should already have command-specific flags merged ahead of shared/global ones (see
/// `GlobalOptions.merged(into:)`) so a name collision resolves in the command's favor.
func parseArgs(_ args: [String], specs: [FlagSpec]) throws -> ParsedArgs {
    var result = ParsedArgs()
    var stopFlags = false
    var index = 0

    func spec(long: String) -> FlagSpec? { specs.first { $0.long == long } }
    func spec(short: String) -> FlagSpec? { specs.first { $0.short == short } }

    while index < args.count {
        let token = args[index]
        defer { index += 1 }

        if !stopFlags, token == "--" {
            stopFlags = true
            continue
        }
        if !stopFlags, token.hasPrefix("--"), token.count > 2 {
            let (name, inline) = splitEquals(token)
            guard let matched = spec(long: name) else { throw UsageError.unknownFlag(name) }
            if matched.takesValue {
                if let inline {
                    result.values[matched.long] = inline
                } else {
                    index += 1
                    guard index < args.count else { throw UsageError.missingValue(matched.long) }
                    result.values[matched.long] = args[index]
                }
            } else {
                if let inline { throw UsageError.flagTakesNoValue(matched.long, inline) }
                result.switches.insert(matched.long)
            }
            continue
        }
        if !stopFlags, token.hasPrefix("-"), token != "-", token.count > 1, Int(token) == nil, Double(token) == nil {
            guard let matched = spec(short: token) else { throw UsageError.unknownFlag(token) }
            if matched.takesValue {
                index += 1
                guard index < args.count else { throw UsageError.missingValue(matched.long) }
                result.values[matched.long] = args[index]
            } else {
                result.switches.insert(matched.long)
            }
            continue
        }
        result.positionals.append(token)
    }
    return result
}

/// Splits `--flag=value` into `("--flag", "value")`; `--flag` alone yields `(name, nil)`.
private func splitEquals(_ token: String) -> (String, String?) {
    guard let eq = token.firstIndex(of: "=") else { return (token, nil) }
    let name = String(token[token.startIndex..<eq])
    let value = String(token[token.index(after: eq)...])
    return (name, value)
}

/// True if `--help`/`-h` is present anywhere in `args` before a `--` terminator. Checked up front
/// by every command so help always works even when required flags/positionals are missing.
func requestsHelp(_ args: [String]) -> Bool {
    for token in args {
        if token == "--" { return false }
        if token == "--help" || token == "-h" { return true }
    }
    return false
}

func truncated(_ text: String, max: Int) -> String {
    guard text.count > max else { return text }
    return String(text.prefix(max)) + "…"
}

/// Requires exactly `names.count` positionals, naming the first missing one in the error.
func requirePositionals(_ parsed: ParsedArgs, names: [String]) throws -> [String] {
    if parsed.positionals.count < names.count {
        throw UsageError.missingPositional(names[parsed.positionals.count])
    }
    if parsed.positionals.count > names.count {
        throw UsageError.tooManyPositionals(expected: names.count, got: parsed.positionals.count)
    }
    return parsed.positionals
}
