import Foundation

enum ThreadsCommand {
    static let groupHelp = GroupHelp(
        name: "threads",
        usage: "pidesk threads <subcommand> [args]",
        summary: "Create, inspect, and drive Pi Desktop threads (sessions).",
        subcommands: [
            ("list", "List threads"),
            ("show", "Show one thread and its recent messages"),
            ("new", "Create a thread, optionally sending the first message"),
            ("send", "Send a follow-up/steer message to a thread"),
            ("abort", "Abort a thread's running turn"),
            ("archive", "Archive a thread"),
            ("unarchive", "Unarchive a thread"),
            ("rename", "Rename a thread"),
            ("watch", "Stream live events for one thread, or all threads")
        ]
    )

    static func run(_ args: [String], context: CommandContext) async -> Int32 {
        await dispatchGroup(args, groupHelp: groupHelp, handlers: [
            "list": list, "show": show, "new": new, "send": send,
            "abort": abort, "archive": archive, "unarchive": unarchive,
            "rename": rename, "watch": watch
        ], context: context)
    }

    // MARK: - list

    private static let listHelp = CommandHelp(
        usage: "pidesk threads list [--query TEXT] [--agent AGENT] [--running] [--automated] [--archived | --all] [--limit N] [--cursor C] [--json]",
        summary: "List active threads newest first. UUIDs use their compact final segment.",
        flags: [
            FlagSpec("--query", takesValue: true, placeholder: "TEXT", help: "filter by name/preview text"),
            FlagSpec("--agent", takesValue: true, placeholder: "AGENT", help: "only one agent's threads: pi, codex, or claude"),
            FlagSpec("--running", takesValue: false, help: "only threads with a run in progress"),
            FlagSpec("--automated", takesValue: false, help: "only threads targeted by an automation"),
            FlagSpec("--archived", takesValue: false, help: "only archived threads"),
            FlagSpec("--all", takesValue: false, help: "include active and archived threads"),
            FlagSpec("--limit", takesValue: true, placeholder: "N", help: "max threads to fetch (default 20)"),
            FlagSpec("--cursor", takesValue: true, placeholder: "C", help: "resume from a previous --json nextCursor")
        ],
        examples: [
            "pidesk threads list",
            "pidesk threads list --running --json",
            "pidesk threads list --agent codex --limit 10",
            "pidesk threads list --query \"nightly triage\" --limit 10"
        ]
    )

    private static func list(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: listHelp) { parsed, global in
            let limit = try positiveInt(parsed.value("--limit"), flag: "--limit", default: 20)
            if parsed.flag("--archived"), parsed.flag("--all") {
                throw UsageError.conflictingFlags(["--archived", "--all"])
            }
            let plane = context.makeControlPlane(global)
            let response = try await plane.listThreads(
                query: parsed.value("--query"),
                limit: limit,
                cursor: parsed.value("--cursor"),
                archived: parsed.flag("--all") ? nil : parsed.flag("--archived"),
                running: parsed.flag("--running") ? true : nil,
                automated: parsed.flag("--automated") ? true : nil,
                agent: try validatedAgent(parsed.value("--agent"))
            )
            if global.jsonOutput {
                context.out.json(response)
                return
            }
            guard !response.threads.isEmpty else {
                context.out.line("No threads.")
                return
            }
            let rows = response.threads.map { Rendering.threadRow($0, colorEnabled: context.out.colorEnabled) }
            for line in Table.render(headers: ["ID", "AGENT", "NAME", "LOCATION", "STATUS", "UPDATED", "PREVIEW"], rows: rows) {
                context.out.line(line)
            }
            if let cursor = response.nextCursor {
                context.out.info("\nMore results available: pidesk threads list --cursor \(cursor)")
            }
        }
    }

    // MARK: - show

    private static let showHelp = CommandHelp(
        usage: "pidesk threads show <id> [--messages N] [--offset N] [--all] [--json]",
        summary: "Show recent user/assistant messages. Use --all for tool and system results.",
        flags: [
            FlagSpec("--messages", takesValue: true, placeholder: "N", help: "messages per page (default 8)"),
            FlagSpec("--offset", takesValue: true, placeholder: "N", help: "skip N newer matching messages"),
            FlagSpec("--all", takesValue: false, help: "include tool results and system messages")
        ],
        examples: [
            "pidesk threads show a1b2c3d4e5f6",
            "pidesk threads show a1b2c3d4e5f6 --offset 8",
            "pidesk threads show a1b2c3d4e5f6 --all --messages 20 --json"
        ]
    )

    private static func show(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: showHelp) { parsed, global in
            let id = try requirePositionals(parsed, names: ["id"])[0]
            let messages = try positiveInt(parsed.value("--messages"), flag: "--messages", default: 8)
            let offset = try nonNegativeInt(parsed.value("--offset"), flag: "--offset", default: 0)
            let response = try await context.makeControlPlane(global).showThread(
                id: id, messages: messages, offset: offset, includeTools: parsed.flag("--all")
            )
            if global.jsonOutput {
                context.out.json(response)
                return
            }
            let thread = response.thread
            context.out.line("\(thread.name ?? "(unnamed)")  [\(Rendering.threadID(thread))]")
            if let worktree = thread.worktree {
                context.out.line("project: \(thread.project ?? "-")")
                context.out.line("worktree: \(worktree)")
            } else {
                context.out.line("cwd: \(thread.cwd ?? "-")")
            }
            context.out.line("agent: \(Rendering.threadAgent(thread))")
            context.out.line("status: \(Rendering.threadStatus(thread, colorEnabled: context.out.colorEnabled))   updated: \(FlexibleDate.displayLocal(thread.updatedAt))")
            if let cost = thread.cost { context.out.line("cost: $\(String(format: "%.2f", cost))") }
            context.out.line("")
            for message in response.messages {
                let role = (message.role ?? "?").uppercased()
                let at = FlexibleDate.displayLocal(message.at)
                context.out.line("[\(at)] \(role)\(message.isError == true ? " (error)" : "")")
                context.out.line(truncated(message.text ?? "", max: 2000))
                context.out.line("")
            }
            if let next = response.nextOffset {
                context.out.info("Older messages: pidesk threads show \(Rendering.threadID(thread)) --offset \(next)\(parsed.flag("--all") ? " --all" : "")")
            }
        }
    }

    // MARK: - new

    private static let newHelp = CommandHelp(
        usage: "pidesk threads new --cwd DIR [--agent AGENT] [--worktree] [--name NAME] [--message TEXT] [--mode MODE] [--json]",
        summary: "Create a thread. Without --message the session is created idle (no run starts).",
        flags: [
            FlagSpec("--cwd", takesValue: true, placeholder: "DIR", help: "working directory or source project (required)"),
            FlagSpec("--agent", takesValue: true, placeholder: "AGENT", help: "agent to run: pi, codex, or claude (default pi)"),
            FlagSpec("--worktree", takesValue: false, help: "run in a fresh managed git worktree"),
            FlagSpec("--name", takesValue: true, placeholder: "NAME", help: "thread name (default: chosen by the daemon)"),
            FlagSpec("--message", takesValue: true, placeholder: "TEXT", help: "first message to send; \"-\" reads it from stdin"),
            FlagSpec("--mode", takesValue: true, placeholder: "MODE", help: "applies /mode before the message, e.g. ultra")
        ],
        examples: [
            "pidesk threads new --cwd ~/code/myapp --worktree --name \"Nightly triage\"",
            "pidesk threads new --cwd ~/code/myapp --message \"survey the repo\" --mode ultra --json"
        ]
    )

    private static func new(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: newHelp) { parsed, global in
            guard let cwd = parsed.value("--cwd") else { throw UsageError.missingRequiredFlag("--cwd") }
            let message = try resolveMessageText(parsed.value("--message"), context: context)
            let plane = context.makeControlPlane(global)
            if parsed.flag("--worktree"), try await plane.health().threadWorktrees != true {
                throw CLIFailure(
                    exitCode: .requestFailed,
                    message: "the running daemon does not support thread worktrees",
                    hint: "update Pi Desktop and restart the active host"
                )
            }
            let response = try await plane.createThread(
                WireCreateThreadRequest(
                    cwd: cwd, name: parsed.value("--name"), message: message,
                    mode: parsed.value("--mode"), worktree: parsed.flag("--worktree") ? true : nil,
                    agent: try validatedAgent(parsed.value("--agent"))
                )
            )
            if global.jsonOutput {
                context.out.json(response)
                return
            }
            context.out.line("Created thread \(Rendering.threadID(response.thread))\(response.thread.name.map { " (\($0))" } ?? "")")
            if let runId = response.runId { context.out.info("Run started: \(runId)") }
        }
    }

    // MARK: - send

    private static let sendHelp = CommandHelp(
        usage: "pidesk threads send <id> <text|-> [--steer | --follow-up] [--wait] [--json]",
        summary: "Send a message to an existing thread. \"-\" for <text> reads the message from stdin.",
        flags: [
            FlagSpec("--steer", takesValue: false, help: "interrupt the current turn instead of queueing"),
            FlagSpec("--follow-up", takesValue: false, help: "queue behind the current turn (default: daemon decides, \"auto\")"),
            FlagSpec("--wait", takesValue: false, help: "stream the run to completion; exits non-zero if it failed")
        ],
        examples: [
            "pidesk threads send 019f9dea-... \"what's the status?\" --wait",
            "echo \"continue\" | pidesk threads send 019f9dea-... - --follow-up"
        ]
    )

    private static func send(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: sendHelp) { parsed, global in
            let positionals = try requirePositionals(parsed, names: ["id", "text"])
            let id = positionals[0]
            let text = try resolveMessageText(positionals[1], context: context) ?? ""
            guard !text.isEmpty else { throw UsageError.custom("message text is empty") }
            if parsed.flag("--steer"), parsed.flag("--follow-up") {
                throw UsageError.conflictingFlags(["--steer", "--follow-up"])
            }
            let delivery = parsed.flag("--steer") ? "steer" : (parsed.flag("--follow-up") ? "followUp" : "auto")
            let plane = context.makeControlPlane(global)
            let response = try await plane.sendMessage(threadId: id, request: WireSendMessageRequest(text: text, delivery: delivery, attachments: []))

            guard parsed.flag("--wait") else {
                if global.jsonOutput {
                    context.out.json(WireSendMessageWithRunResponse(runId: response.runId, queued: response.queued, run: nil))
                } else {
                    context.out.line("Run \(response.runId)\(response.queued == true ? " (queued)" : " started")")
                }
                return
            }

            context.out.info("Waiting for run \(response.runId) to finish…")
            let run = try await waitForRun(plane: plane, runId: response.runId, out: context.out)
            if global.jsonOutput {
                context.out.json(WireSendMessageWithRunResponse(runId: response.runId, queued: response.queued, run: run))
            } else {
                context.out.line("Run \(run.id) finished: \(run.status ?? "unknown")")
                if let summary = run.summary { context.out.line(summary) }
            }
            guard RunStatus.isSuccess(run.status) else {
                throw CLIFailure(exitCode: .requestFailed, message: "run \(run.id) did not succeed (\(run.status ?? "unknown"))\(run.error.map { ": \($0)" } ?? "")")
            }
        }
    }

    // MARK: - abort / archive / unarchive

    private static let abortHelp = CommandHelp(
        usage: "pidesk threads abort <id> [--json]",
        summary: "Abort a thread's currently running turn, if any.",
        flags: [],
        examples: ["pidesk threads abort 019f9dea-..."]
    )

    private static func abort(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: abortHelp) { parsed, global in
            let id = try requirePositionals(parsed, names: ["id"])[0]
            let response = try await context.makeControlPlane(global).abortThread(id: id)
            if global.jsonOutput { context.out.json(response) } else { context.out.line(response.aborted ? "Aborted \(id)" : "Nothing to abort on \(id)") }
        }
    }

    private static let archiveHelp = CommandHelp(
        usage: "pidesk threads archive <id> [--json]",
        summary: "Archive a thread.",
        flags: [],
        examples: ["pidesk threads archive 019f9dea-..."]
    )

    private static func archive(_ args: [String], context: CommandContext) async -> Int32 {
        await setArchived(args, context: context, archived: true, help: archiveHelp)
    }

    private static let unarchiveHelp = CommandHelp(
        usage: "pidesk threads unarchive <id> [--json]",
        summary: "Unarchive a thread.",
        flags: [],
        examples: ["pidesk threads unarchive 019f9dea-..."]
    )

    private static func unarchive(_ args: [String], context: CommandContext) async -> Int32 {
        await setArchived(args, context: context, archived: false, help: unarchiveHelp)
    }

    private static func setArchived(_ args: [String], context: CommandContext, archived: Bool, help: CommandHelp) async -> Int32 {
        await runLeaf(args, context: context, help: help) { parsed, global in
            let id = try requirePositionals(parsed, names: ["id"])[0]
            let response = try await context.makeControlPlane(global).setArchived(id: id, archived: archived)
            if global.jsonOutput { context.out.json(response) } else { context.out.line("\(archived ? "Archived" : "Unarchived") \(id)") }
        }
    }

    // MARK: - rename

    private static let renameHelp = CommandHelp(
        usage: "pidesk threads rename <id> <name> [--json]",
        summary: "Rename a thread.",
        flags: [],
        examples: ["pidesk threads rename 019f9dea-... \"Nightly triage\""]
    )

    private static func rename(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: renameHelp) { parsed, global in
            let positionals = try requirePositionals(parsed, names: ["id", "name"])
            let response = try await context.makeControlPlane(global).renameThread(id: positionals[0], name: positionals[1])
            if global.jsonOutput { context.out.json(response) } else { context.out.line("Renamed \(positionals[0]) to \"\(positionals[1])\"") }
        }
    }

    // MARK: - watch

    private static let watchHelp = CommandHelp(
        usage: "pidesk threads watch [<id>] [--json]",
        summary: "Stream live thread/run/activity/schedule events. Without <id>, streams every thread.",
        flags: [],
        examples: ["pidesk threads watch", "pidesk threads watch 019f9dea-... --json"]
    )

    private static func watch(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: watchHelp) { parsed, global in
            guard parsed.positionals.count <= 1 else { throw UsageError.tooManyPositionals(expected: 1, got: parsed.positionals.count) }
            let filterId = parsed.positionals.first
            context.out.info("Watching for events\(filterId.map { " on thread \($0)" } ?? "")… (Ctrl-C to stop)")
            let events = context.makeControlPlane(global).events()
            for try await event in events {
                if let filterId, !eventMatches(event, threadId: filterId) { continue }
                emit(event, out: context.out, jsonOutput: global.jsonOutput, now: context.now)
            }
        }
    }

    private static func eventMatches(_ event: ControlPlaneEvent, threadId: String) -> Bool {
        if event.name == "activity" { return true } // global snapshot; not tied to one thread
        return [event.data["id"]?.stringValue, event.data["threadId"]?.stringValue]
            .compactMap { $0 }
            .contains { $0 == threadId || $0.hasPrefix(threadId) || $0.hasSuffix(threadId) }
    }

    private static func emit(_ event: ControlPlaneEvent, out: OutputSink, jsonOutput: Bool, now: () -> Date) {
        if jsonOutput {
            out.jsonLine(WatchEventLine(event: event.name, receivedAt: FlexibleDate.iso8601(now()), data: event.data))
            return
        }
        let timestamp = FlexibleDate.displayLocal(FlexibleDate.iso8601(now()))
        let summary = event.data["name"]?.stringValue ?? event.data["status"]?.stringValue ?? event.data["id"]?.stringValue ?? ""
        out.line("[\(timestamp)] \(event.name)\(summary.isEmpty ? "" : "  " + summary)")
    }

    // MARK: - shared helpers

    /// Waits for one specific run to reach a terminal status by filtering `/v1/events`. Streamed
    /// intermediate events for *other* runs/threads are ignored, not printed, to keep --wait output
    /// focused on the run the caller asked about.
    private static func waitForRun(plane: ControlPlane, runId: String, out: OutputSink) async throws -> WireRun {
        for try await event in plane.events() {
            guard event.name == "run", event.data["id"]?.stringValue == runId else { continue }
            guard let run = try? event.data.decoded(as: WireRun.self) else { continue }
            if RunStatus.isTerminal(run.status) { return run }
        }
        throw CLIFailure(exitCode: .requestFailed, message: "event stream ended before run \(runId) finished")
    }

    private static func resolveMessageText(_ raw: String?, context: CommandContext) throws -> String? {
        guard let raw else { return nil }
        guard raw == "-" else { return raw }
        let data = context.readStdin(1_000_000)
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageError.custom("stdin was not valid UTF-8 text")
        }
        return text.trimmingCharacters(in: .newlines)
    }

    /// Caught here rather than at the daemon so a typo costs no round trip and the error names
    /// the valid agents. The list is the CLI's own, so a newer daemon's agent is still accepted
    /// on the wire \u2014 it just cannot be typed as a filter until this CLI learns it.
    static let agents = ["pi", "codex", "claude"]

    static func validatedAgent(_ raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let value = raw.lowercased()
        guard agents.contains(value) else {
            throw UsageError.invalidValue(flag: "--agent", value: raw, reason: "expected one of: \(agents.joined(separator: ", "))")
        }
        return value
    }

    private static func positiveInt(_ raw: String?, flag: String, default value: Int) throws -> Int {
        guard let raw else { return value }
        guard let parsed = Int(raw), parsed > 0 else {
            throw UsageError.invalidValue(flag: flag, value: raw, reason: "expected a positive integer")
        }
        return parsed
    }

    private static func nonNegativeInt(_ raw: String?, flag: String, default value: Int) throws -> Int {
        guard let raw else { return value }
        guard let parsed = Int(raw), parsed >= 0 else {
            throw UsageError.invalidValue(flag: flag, value: raw, reason: "expected zero or a positive integer")
        }
        return parsed
    }
}

/// Stable `threads send --json` shape: `run` is always present (null unless --wait was given) so
/// scripts can rely on a fixed key set regardless of flags.
struct WireSendMessageWithRunResponse: Codable, Equatable {
    var runId: String
    var queued: Bool?
    var run: WireRun?
}

/// Stable `threads watch --json` / one-line-per-event shape (this CLI's own envelope — the SSE
/// wire format itself has no single JSON object per message).
struct WatchEventLine: Codable, Equatable {
    var event: String
    var receivedAt: String
    var data: JSONValue
}
