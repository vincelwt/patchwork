import Foundation

enum ScheduleCommand {
    static let groupHelp = GroupHelp(
        name: "schedule",
        usage: "pidesk schedule <subcommand> [args]",
        summary: "Manage scheduled prompts (once / interval / cron / heartbeat triggers).",
        subcommands: [
            ("list", "List schedules"),
            ("add", "Create a schedule"),
            ("show", "Show a schedule and its recent runs"),
            ("pause", "Pause a schedule"),
            ("resume", "Resume a paused schedule"),
            ("remove", "Delete a schedule"),
            ("run", "Run a schedule now, out of band")
        ]
    )

    static func run(_ args: [String], context: CommandContext) async -> Int32 {
        await dispatchGroup(args, groupHelp: groupHelp, handlers: [
            "list": list, "add": add, "show": show,
            "pause": pause, "resume": resume, "remove": remove, "run": runNow
        ], context: context)
    }

    // MARK: - list

    private static let listHelp = CommandHelp(
        usage: "pidesk schedule list [--json]",
        summary: "List every schedule.",
        flags: [],
        examples: ["pidesk schedule list", "pidesk schedule list --json | jq '.schedules[].id'"]
    )

    private static func list(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: listHelp) { _, global in
            let response = try await context.makeControlPlane(global).listSchedules()
            if global.jsonOutput {
                context.out.json(response)
                return
            }
            guard !response.schedules.isEmpty else {
                context.out.line("No schedules.")
                return
            }
            let rows = response.schedules.map { Rendering.scheduleRow($0, colorEnabled: context.out.colorEnabled) }
            for line in Table.render(headers: ["ID", "NAME", "STATUS", "TRIGGER", "NEXT RUN"], rows: rows) {
                context.out.line(line)
            }
        }
    }

    // MARK: - add

    private static let addHelp = CommandHelp(
        usage: "pidesk schedule add --name NAME (--thread ID | --cwd DIR) --prompt TEXT (--at ISO | --every DUR | --cron EXPR | --heartbeat DUR) [options]",
        summary: "Create a schedule. Exactly one of --thread/--cwd and exactly one trigger flag are required.",
        flags: [
            FlagSpec("--name", takesValue: true, placeholder: "NAME", help: "schedule name (required)"),
            FlagSpec("--thread", takesValue: true, placeholder: "ID", help: "run against an existing thread"),
            FlagSpec("--cwd", takesValue: true, placeholder: "DIR", help: "create a new thread each run, in this directory"),
            FlagSpec("--name-pattern", takesValue: true, placeholder: "PATTERN", help: "new-thread name pattern, e.g. \"Triage {date}\" (only with --cwd; defaults to --name)"),
            FlagSpec("--prompt", takesValue: true, placeholder: "TEXT", help: "prompt to send each run (required)"),
            FlagSpec("--at", takesValue: true, placeholder: "ISO|LOCAL", help: "fire once, e.g. 2026-07-27T09:00:00Z or 2026-07-27T09:00"),
            FlagSpec("--every", takesValue: true, placeholder: "DUR", help: "fire on an interval, e.g. 15m, 2h"),
            FlagSpec("--cron", takesValue: true, placeholder: "EXPR", help: "5-field cron expression, e.g. \"0 9 * * 1-5\""),
            FlagSpec("--heartbeat", takesValue: true, placeholder: "DUR", help: "fire while the thread is idle, never stacking runs"),
            FlagSpec("--timezone", takesValue: true, placeholder: "TZ", help: "IANA zone for --cron (default: local zone)"),
            FlagSpec("--start-at", takesValue: true, placeholder: "ISO|LOCAL", help: "first fire time for --every (default: now)"),
            FlagSpec("--mode", takesValue: true, placeholder: "MODE", help: "applies /mode before the prompt, e.g. ultra"),
            FlagSpec("--skip-if-running", takesValue: false, help: "never stack a run on a thread that's already busy"),
            // NOTE: shadows the global --timeout on this command only; see GlobalFlag doc comment.
            FlagSpec("--timeout", takesValue: true, placeholder: "DUR", help: "abort the run if it takes longer than this, e.g. 30m")
        ],
        examples: [
            "pidesk schedule add --name \"Morning triage\" --cwd ~/code/myapp \\\n      --prompt \"Check overnight CI failures and summarise\" --cron \"0 9 * * 1-5\"",
            "pidesk schedule add --name \"Keep-alive\" --thread 019f9dea-... --prompt \"ping\" --heartbeat 15m",
            "pidesk schedule add --name \"One-off\" --cwd ~/code/myapp --prompt \"ship it\" --at \"2026-07-27T09:00\""
        ]
    )

    private static func add(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: addHelp, ownsTimeout: true) { parsed, global in
            guard let name = parsed.value("--name") else { throw UsageError.missingRequiredFlag("--name") }
            guard let prompt = parsed.value("--prompt") else { throw UsageError.missingRequiredFlag("--prompt") }

            let target = try resolveTarget(parsed)
            let trigger = try resolveTrigger(TriggerFlags(
                at: parsed.value("--at"), every: parsed.value("--every"), cron: parsed.value("--cron"),
                heartbeat: parsed.value("--heartbeat"), timezone: parsed.value("--timezone"), startAt: parsed.value("--start-at")
            ))

            var policy: WireSchedulePolicy?
            if parsed.flag("--skip-if-running") || parsed.value("--timeout") != nil {
                let timeoutSeconds = try parsed.value("--timeout").map { Int(try parseDuration($0)) }
                policy = WireSchedulePolicy(skipIfRunning: parsed.flag("--skip-if-running") ? true : nil, catchUpMissed: nil, timeoutSeconds: timeoutSeconds, quietHours: nil)
            }

            let request = WireScheduleCreateRequest(
                name: name, enabled: true, target: target, prompt: prompt,
                mode: parsed.value("--mode"), trigger: trigger.wire, policy: policy
            )
            let response = try await context.makeControlPlane(global).createSchedule(request)
            if global.jsonOutput {
                context.out.json(response)
            } else {
                context.out.line("Created schedule \(response.schedule.id) (\(response.schedule.name ?? name))")
            }
        }
    }

    private static func resolveTarget(_ parsed: ParsedArgs) throws -> WireScheduleTarget {
        let thread = parsed.value("--thread")
        let cwd = parsed.value("--cwd")
        switch (thread, cwd) {
        case (nil, nil):
            throw UsageError.custom("one of --thread or --cwd is required")
        case let (.some(id), nil):
            return WireScheduleTarget(kind: "existingThread", threadId: id, cwd: nil, namePattern: nil)
        case let (nil, .some(dir)):
            return WireScheduleTarget(kind: "newThread", threadId: nil, cwd: dir, namePattern: parsed.value("--name-pattern") ?? parsed.value("--name"))
        case (.some, .some):
            throw UsageError.conflictingFlags(["--thread", "--cwd"])
        }
    }

    // MARK: - show

    private static let showHelp = CommandHelp(
        usage: "pidesk schedule show <id> [--json]",
        summary: "Show a schedule's configuration and recent run history.",
        flags: [],
        examples: ["pidesk schedule show sch_..."]
    )

    private static func show(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: showHelp) { parsed, global in
            let id = try requirePositionals(parsed, names: ["id"])[0]
            let response = try await context.makeControlPlane(global).showSchedule(id: id)
            if global.jsonOutput {
                context.out.json(response)
                return
            }
            let schedule = response.schedule
            context.out.line("\(schedule.name ?? "(unnamed)")  [\(schedule.id)]")
            context.out.line("status: \(Rendering.scheduleStatus(schedule, colorEnabled: context.out.colorEnabled))   trigger: \(Rendering.triggerSummary(schedule.trigger))")
            context.out.line("prompt: \(truncated(schedule.prompt ?? "", max: 200))")
            context.out.line("next run: \(FlexibleDate.displayLocal(schedule.nextRunAt))   last: \(schedule.lastStatus ?? "-") at \(FlexibleDate.displayLocal(schedule.lastRunAt))")
            guard !response.runs.isEmpty else { return }
            context.out.line("")
            for line in Table.render(headers: ["RUN ID", "STATUS", "TRIGGER", "STARTED", "SUMMARY"], rows: response.runs.map { Rendering.runRow($0, colorEnabled: context.out.colorEnabled) }) {
                context.out.line(line)
            }
        }
    }

    // MARK: - pause / resume

    private static let pauseHelp = CommandHelp(usage: "pidesk schedule pause <id> [--json]", summary: "Pause a schedule.", flags: [], examples: ["pidesk schedule pause sch_..."])
    private static let resumeHelp = CommandHelp(usage: "pidesk schedule resume <id> [--json]", summary: "Resume a paused schedule.", flags: [], examples: ["pidesk schedule resume sch_..."])

    private static func pause(_ args: [String], context: CommandContext) async -> Int32 {
        await setPaused(args, context: context, paused: true, help: pauseHelp)
    }

    private static func resume(_ args: [String], context: CommandContext) async -> Int32 {
        await setPaused(args, context: context, paused: false, help: resumeHelp)
    }

    private static func setPaused(_ args: [String], context: CommandContext, paused: Bool, help: CommandHelp) async -> Int32 {
        await runLeaf(args, context: context, help: help) { parsed, global in
            let id = try requirePositionals(parsed, names: ["id"])[0]
            let response = try await context.makeControlPlane(global).setSchedulePaused(id: id, paused: paused)
            if global.jsonOutput { context.out.json(response) } else { context.out.line("\(paused ? "Paused" : "Resumed") \(id)") }
        }
    }

    // MARK: - remove

    private static let removeHelp = CommandHelp(usage: "pidesk schedule remove <id> [--json]", summary: "Delete a schedule.", flags: [], examples: ["pidesk schedule remove sch_..."])

    private static func remove(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: removeHelp) { parsed, global in
            let id = try requirePositionals(parsed, names: ["id"])[0]
            let response = try await context.makeControlPlane(global).deleteSchedule(id: id)
            if global.jsonOutput { context.out.json(response) } else { context.out.line(response.deleted ? "Removed \(id)" : "Nothing removed for \(id)") }
        }
    }

    // MARK: - run

    private static let runHelp = CommandHelp(
        usage: "pidesk schedule run <id> [--json]",
        summary: "Run a schedule now, out of band from its trigger.",
        flags: [],
        examples: ["pidesk schedule run sch_..."]
    )

    private static func runNow(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: runHelp) { parsed, global in
            let id = try requirePositionals(parsed, names: ["id"])[0]
            let response = try await context.makeControlPlane(global).runSchedule(id: id)
            if global.jsonOutput { context.out.json(response) } else { context.out.line("Run started: \(response.runId)") }
        }
    }
}
