import Foundation

/// Top-level routing: `pidesk <group> <subcommand> [args]`, or `pidesk limits [args]` (the one
/// leaf command with no group). Kept deliberately dumb — each group owns its own subcommand
/// dispatch and help text.
enum CLIRunner {
    static let topLevelSummary = "pidesk — command-line client for Pi Desktop's control daemon."

    static let groups: [(name: String, summary: String)] = [
        ("threads", "Create, inspect, and drive threads (sessions)"),
        ("schedule", "Manage scheduled prompts"),
        ("daemon", "Install, start, stop, and inspect pi-deskd"),
        ("remote", "Manage the loopback web-remote listener"),
        ("limits", "Show parsed /limits usage report")
    ]

    static func run(_ rawArgs: [String], host: CLIHost) async -> Int32 {
        let jsonOutput = rawArgs.contains("--json")
        let quiet = rawArgs.contains("--quiet") || rawArgs.contains("-q")
        let out = OutputSink(
            writeOut: host.writeOut,
            writeErr: host.writeErr,
            quiet: quiet,
            jsonOutput: jsonOutput,
            colorEnabled: !jsonOutput && host.environment["NO_COLOR"] == nil && host.isTTY
        )
        let context = CommandContext(
            environment: host.environment,
            makeControlPlane: host.makeControlPlane,
            shellRunner: host.shellRunner,
            fileManager: host.fileManager,
            now: host.now,
            readStdin: host.readStdin,
            out: out,
            daemonSettingsPath: host.daemonSettingsPath,
            tokenFilePath: host.tokenFilePath,
            logFilePath: host.logFilePath,
            daemonOwnerFilePath: host.daemonOwnerFilePath
        )

        if rawArgs.isEmpty {
            out.errorLine(topLevelHelp())
            return ExitCode.badUsage.rawValue
        }
        if rawArgs[0] == "--version" {
            out.line("pidesk (Pi Desktop control API v\(1))")
            return ExitCode.ok.rawValue
        }
        if rawArgs[0] == "--help" || rawArgs[0] == "-h" {
            out.line(topLevelHelp())
            return ExitCode.ok.rawValue
        }

        let group = rawArgs[0]
        let rest = Array(rawArgs.dropFirst())
        switch group {
        case "threads": return await ThreadsCommand.run(rest, context: context)
        case "schedule": return await ScheduleCommand.run(rest, context: context)
        case "daemon": return await DaemonCommand.run(rest, context: context)
        case "remote": return await RemoteCommand.run(rest, context: context)
        case "limits": return await LimitsCommand.run(rest, context: context)
        default:
            out.errorLine("pidesk: unknown command \"\(group)\"\n\n\(topLevelHelp())")
            return ExitCode.badUsage.rawValue
        }
    }

    private static func topLevelHelp() -> String {
        var lines = [
            topLevelSummary,
            "",
            "Usage: pidesk <command> <subcommand> [args] [flags]",
            "",
            "Commands:"
        ]
        let width = groups.map(\.name.count).max() ?? 0
        for group in groups {
            lines.append("  \(group.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(group.summary)")
        }
        lines.append("")
        lines.append("Global options:")
        let flagWidth = GlobalFlag.all.map(\.synopsis.count).max() ?? 0
        for flag in GlobalFlag.all {
            lines.append("  \(flag.synopsis.padding(toLength: flagWidth, withPad: " ", startingAt: 0))  \(flag.help)")
        }
        lines.append("")
        lines.append("Run `pidesk <command> --help` or `pidesk <command> <subcommand> --help` for details.")
        lines.append("")
        lines.append("Examples:")
        lines.append("  pidesk threads new --cwd ~/code/myapp --message \"survey the repo\"")
        lines.append("  pidesk threads list --json | jq '.threads[].name'")
        lines.append("  pidesk schedule add --name \"Morning triage\" --cwd ~/code/myapp \\")
        lines.append("      --prompt \"Check overnight CI failures\" --cron \"0 9 * * 1-5\"")
        lines.append("")
        lines.append("Exit codes: 0 ok, 1 request failed, 2 bad usage, 3 daemon unreachable.")
        return lines.joined(separator: "\n")
    }
}
