import Foundation
import PatchworkKit

enum DaemonCommand {
    static let groupHelp = GroupHelp(
        name: "daemon",
        usage: "patchwork daemon <subcommand> [args]",
        summary: "Install, start, stop, and inspect patchworkd, the control-plane daemon.",
        subcommands: [
            ("status", "Show whether the daemon is reachable and its health"),
            ("start", "Start the daemon"),
            ("stop", "Stop the daemon"),
            ("restart", "Restart the daemon"),
            ("install", "Register patchworkd as a login item (LaunchAgent)"),
            ("uninstall", "Remove the LaunchAgent registration"),
            ("logs", "Show (or follow) the daemon log")
        ]
    )

    static func run(_ args: [String], context: CommandContext) async -> Int32 {
        await dispatchGroup(args, groupHelp: groupHelp, handlers: [
            "status": status, "start": start, "stop": stop, "restart": restart,
            "install": install, "uninstall": uninstall, "logs": logs
        ], context: context)
    }

    // MARK: - status

    private static let statusHelp = CommandHelp(
        usage: "patchwork daemon status [--json]",
        summary: "Report whether the daemon is reachable, and its health payload if so.",
        flags: [],
        examples: ["patchwork daemon status"]
    )

    private static func status(_ args: [String], context: CommandContext) async -> Int32 {
        if requestsHelp(args) {
            context.out.line(HelpPrinter.render(statusHelp))
            return ExitCode.ok.rawValue
        }
        do {
            let commandSpecs = GlobalFlag.merged(into: statusHelp.flags)
            let parsed = try parseArgs(args, specs: commandSpecs)
            let global = try GlobalOptions.resolve(parsed, environment: context.environment, commandOwnsTimeout: false)

            // Computed once, before the health probe, so both the reachable and unreachable
            // branches below report the same mode from the same snapshot in time.
            let launchAgentLoaded = DaemonControl.isLoaded(runner: context.shellRunner)
            let ownedByApp = DaemonOwnership.isLive(DaemonOwnership.read(from: context.daemonOwnerFilePath))

            do {
                let health = try await context.makeControlPlane(global).health()
                let mode = DaemonModeClassifier.classify(launchAgentLoaded: launchAgentLoaded, healthReachable: true, ownedByApp: ownedByApp)
                if global.jsonOutput {
                    context.out.json(DaemonStatusJSON(mode: mode.rawValue, modeDetail: modeDetail(for: mode), health: health))
                } else {
                    context.out.line("mode: \(modeSummary(for: mode))")
                    context.out.line("control service is running (v\(health.version ?? "?"), api \(health.api.map(String.init) ?? "?"))")
                    context.out.line("pi: \(health.piVersion ?? "-")   running runs: \(health.runningRuns ?? 0)   queued: \(health.queuedRuns ?? 0)")
                    context.out.line("schedules enabled: \(health.schedulesEnabled == true ? "yes" : "no")   started at: \(FlexibleDate.displayLocal(health.startedAt))")
                }
                return ExitCode.ok.rawValue
            } catch let error as ControlPlaneError {
                let mode = DaemonModeClassifier.classify(launchAgentLoaded: launchAgentLoaded, healthReachable: false, ownedByApp: ownedByApp)
                let failure = asFailure(error)
                if global.jsonOutput {
                    context.out.json(JSONErrorEnvelope(code: "unreachable", message: failure.message, mode: mode.rawValue))
                } else {
                    context.out.line("mode: \(modeSummary(for: mode))")
                    context.out.errorLine("control service is not reachable: \(failure.message)")
                    if let hint = failure.hint { context.out.errorLine(hint) }
                }
                return failure.exitCode.rawValue
            }
        } catch {
            let failure = asFailure(error)
            context.out.errorLine("patchwork: \(failure.message)")
            return failure.exitCode.rawValue
        }
    }

    /// Human-readable line for every mode `DaemonModeClassifier` can produce — kept exhaustive
    /// (no `default:`) so a new case is a compile error here, not a silently blank status line.
    private static func modeSummary(for mode: DaemonRunMode) -> String {
        switch mode {
        case .appManaged: "app-managed (hosted inside Patchwork.app)"
        case .launchAgent: "LaunchAgent (\(DaemonControl.label), starts at login)"
        case .external: "running, but not managed by Patchwork.app or the LaunchAgent"
        case .notRunning: "not running"
        }
    }

    private static func modeDetail(for mode: DaemonRunMode) -> String? {
        mode == .notRunning ? nil : modeSummary(for: mode)
    }

    // MARK: - start / stop / restart

    private static let startHelp = CommandHelp(usage: "patchwork daemon start", summary: "Start patchworkd (via launchctl if installed, otherwise a direct spawn).", flags: [], examples: ["patchwork daemon start"])
    private static let stopHelp = CommandHelp(usage: "patchwork daemon stop", summary: "Stop patchworkd via launchctl.", flags: [], examples: ["patchwork daemon stop"])
    private static let restartHelp = CommandHelp(usage: "patchwork daemon restart", summary: "Restart patchworkd via launchctl. Use after `patchwork remote enable/disable`.", flags: [], examples: ["patchwork daemon restart"])

    private static func start(_ args: [String], context: CommandContext) async -> Int32 {
        await lifecycleAction(args, context: context, help: startHelp, verb: "Started") { runner, fileManager in
            try DaemonControl.start(runner: runner, fileManager: fileManager, logFile: context.logFilePath)
        }
    }

    private static func stop(_ args: [String], context: CommandContext) async -> Int32 {
        await lifecycleAction(args, context: context, help: stopHelp, verb: "Stopped") { runner, fileManager in
            try DaemonControl.stop(runner: runner, fileManager: fileManager)
        }
    }

    private static func restart(_ args: [String], context: CommandContext) async -> Int32 {
        await lifecycleAction(args, context: context, help: restartHelp, verb: "Restarted") { runner, fileManager in
            try DaemonControl.restart(runner: runner, fileManager: fileManager)
        }
    }

    private static let installHelp = CommandHelp(usage: "patchwork daemon install", summary: "Register patchworkd as a LaunchAgent that starts at login and restarts on failure.", flags: [], examples: ["patchwork daemon install"])

    private static func install(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: installHelp) { _, global in
            let path = try DaemonControl.install(runner: context.shellRunner, fileManager: context.fileManager, logFile: context.logFilePath)
            if global.jsonOutput {
                context.out.json(DaemonActionResult(ok: true, action: "install", detail: path))
            } else {
                context.out.line("Installed \(DaemonControl.label) -> \(path)")
            }
        }
    }

    private static let uninstallHelp = CommandHelp(usage: "patchwork daemon uninstall", summary: "Remove the LaunchAgent registration.", flags: [], examples: ["patchwork daemon uninstall"])

    private static func uninstall(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: uninstallHelp) { _, global in
            try DaemonControl.uninstall(runner: context.shellRunner, fileManager: context.fileManager)
            if global.jsonOutput {
                context.out.json(DaemonActionResult(ok: true, action: "uninstall", detail: nil))
            } else {
                context.out.line("Uninstalled \(DaemonControl.label)")
            }
        }
    }

    private static func lifecycleAction(_ args: [String], context: CommandContext, help: CommandHelp, verb: String, action: (ShellRunning, FileManager) throws -> Void) async -> Int32 {
        await runLeaf(args, context: context, help: help) { _, global in
            try action(context.shellRunner, context.fileManager)
            if global.jsonOutput {
                context.out.json(DaemonActionResult(ok: true, action: verb.lowercased(), detail: nil))
            } else {
                context.out.line("\(verb) \(DaemonControl.label)")
            }
        }
    }

    // MARK: - logs

    private static let logsHelp = CommandHelp(
        usage: "patchwork daemon logs [-f] [--lines N] [--json]",
        summary: "Show the daemon's log file, most recent lines last.",
        flags: [
            FlagSpec("--follow", short: "-f", takesValue: false, help: "keep printing new lines as they're written"),
            FlagSpec("--lines", takesValue: true, placeholder: "N", help: "how many recent lines to show (default 100)")
        ],
        examples: ["patchwork daemon logs", "patchwork daemon logs -f", "patchwork daemon logs --lines 500 --json"]
    )

    private static func logs(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: logsHelp) { parsed, global in
            let count = try positiveInt(parsed.value("--lines"), default: 100)
            let path = context.logFilePath
            guard context.fileManager.fileExists(atPath: path.path) else {
                throw CLIFailure(exitCode: .requestFailed, message: "no log file at \(path.path) yet", hint: "the daemon hasn't run; try `patchwork daemon start` first")
            }
            let lines = try LogTail.lastLines(of: path, count: count)
            for line in lines { printLogLine(line, out: context.out, jsonOutput: global.jsonOutput) }

            guard parsed.flag("--follow") else { return }
            let handle = try FileHandle(forReadingFrom: path)
            _ = try handle.seekToEnd()
            context.out.info("Following \(path.path)… (Ctrl-C to stop)")
            while true {
                let appended = LogTail.readAppended(handle)
                if !appended.isEmpty {
                    var remainder = appended
                    if remainder.hasSuffix("\n") { remainder.removeLast() }
                    for line in remainder.components(separatedBy: "\n") { printLogLine(line, out: context.out, jsonOutput: global.jsonOutput) }
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private static func printLogLine(_ line: String, out: OutputSink, jsonOutput: Bool) {
        if jsonOutput { out.jsonLine(["line": line]) } else { out.line(line) }
    }

    private static func positiveInt(_ raw: String?, default value: Int) throws -> Int {
        guard let raw else { return value }
        guard let parsed = Int(raw), parsed > 0 else {
            throw UsageError.invalidValue(flag: "--lines", value: raw, reason: "expected a positive integer")
        }
        return parsed
    }
}

struct DaemonActionResult: Codable, Equatable {
    var ok: Bool
    var action: String
    var detail: String?
}

/// `daemon status --json`'s reachable shape: `mode`/`modeDetail` are this CLI's own knowledge
/// (docs/cli.md's "a few shapes are this CLI's own"), wrapped around — not merged into — the raw
/// `GET /v1/health` payload so the API's own contract stays untouched by CLI-local concerns.
struct DaemonStatusJSON: Codable, Equatable {
    var mode: String
    var modeDetail: String?
    var health: WireHealth
}
