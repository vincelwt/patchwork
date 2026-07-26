import Foundation

/// Shared routing for `pidesk <group> <subcommand> [args]`. Every group command file builds a
/// `GroupHelp` and a name->handler table and hands both to this.
func dispatchGroup(
    _ args: [String],
    groupHelp: GroupHelp,
    handlers: [String: ([String], CommandContext) async -> Int32],
    context: CommandContext
) async -> Int32 {
    guard let sub = args.first else {
        context.out.errorLine(HelpPrinter.render(groupHelp))
        return ExitCode.badUsage.rawValue
    }
    if sub == "--help" || sub == "-h" {
        context.out.line(HelpPrinter.render(groupHelp))
        return ExitCode.ok.rawValue
    }
    guard let handler = handlers[sub] else {
        context.out.errorLine("pidesk: unknown \(groupHelp.name) subcommand \"\(sub)\"")
        context.out.errorLine("")
        context.out.errorLine(HelpPrinter.render(groupHelp))
        return ExitCode.badUsage.rawValue
    }
    return await handler(Array(args.dropFirst()), context)
}

/// Every leaf command follows the same shape: parse, act, print, map errors to an exit code.
/// This wraps that so each command body only writes the "act + print" part.
func runLeaf(
    _ args: [String],
    context: CommandContext,
    help: CommandHelp,
    ownsTimeout: Bool = false,
    body: (ParsedArgs, GlobalOptions) async throws -> Void
) async -> Int32 {
    if requestsHelp(args) {
        context.out.line(HelpPrinter.render(help))
        return ExitCode.ok.rawValue
    }
    do {
        let commandSpecs = GlobalFlag.merged(into: help.flags, excludingTimeout: ownsTimeout)
        let parsed = try parseArgs(args, specs: commandSpecs)
        let global = try GlobalOptions.resolve(parsed, environment: context.environment, commandOwnsTimeout: ownsTimeout)
        try await body(parsed, global)
        return ExitCode.ok.rawValue
    } catch {
        let failure = asFailure(error)
        context.out.errorLine("pidesk: \(failure.message)")
        if let hint = failure.hint { context.out.errorLine(hint) }
        return failure.exitCode.rawValue
    }
}
