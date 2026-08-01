import Foundation

enum ThreadsCommand {
    static let groupHelp = GroupHelp(
        name: "threads",
        usage: "patchwork threads <subcommand> [args]",
        summary: "Create, inspect, and drive Patchwork threads (sessions).",
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
        usage: "patchwork threads list [--query TEXT] [--agent AGENT] [--running] [--automated] [--archived | --all] [--limit N] [--cursor C] [--json]",
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
            "patchwork threads list",
            "patchwork threads list --running --json",
            "patchwork threads list --agent codex --limit 10",
            "patchwork threads list --query \"nightly triage\" --limit 10"
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
                context.out.info("\nMore results available: patchwork threads list --cursor \(cursor)")
            }
        }
    }

    // MARK: - show

    private static let showHelp = CommandHelp(
        usage: "patchwork threads show <id> [--messages N] [--offset N] [--all] [--json]",
        summary: "Show recent user/assistant messages. Use --all for tool and system results.",
        flags: [
            FlagSpec("--messages", takesValue: true, placeholder: "N", help: "messages per page (default 8)"),
            FlagSpec("--offset", takesValue: true, placeholder: "N", help: "skip N newer matching messages"),
            FlagSpec("--all", takesValue: false, help: "include tool results and system messages")
        ],
        examples: [
            "patchwork threads show a1b2c3d4e5f6",
            "patchwork threads show a1b2c3d4e5f6 --offset 8",
            "patchwork threads show a1b2c3d4e5f6 --all --messages 20 --json"
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
                context.out.info("Older messages: patchwork threads show \(Rendering.threadID(thread)) --offset \(next)\(parsed.flag("--all") ? " --all" : "")")
            }
        }
    }

    // MARK: - new

    private static let newHelp = CommandHelp(
        usage: "patchwork threads new --cwd DIR [--agent AGENT] [--worktree] [--name NAME] [--message TEXT] [--mode MODE] [--client-id ID] [--json]",
        summary: "Create a thread. Pi and Codex may be idle; Claude Code requires --message.",
        flags: [
            FlagSpec("--cwd", takesValue: true, placeholder: "DIR", help: "working directory or source project (required)"),
            FlagSpec("--agent", takesValue: true, placeholder: "AGENT", help: "agent to run: pi, codex, or claude (default pi)"),
            FlagSpec("--worktree", takesValue: false, help: "run in a fresh managed git worktree"),
            FlagSpec("--name", takesValue: true, placeholder: "NAME", help: "thread name (default: chosen by the daemon)"),
            FlagSpec("--message", takesValue: true, placeholder: "TEXT", help: "first message to send; required for Claude Code; \"-\" reads it from stdin"),
            FlagSpec("--mode", takesValue: true, placeholder: "MODE", help: "Pi only: applies /mode before the first message, e.g. ultra"),
            FlagSpec("--client-id", takesValue: true, placeholder: "ID", help: "stable retry ID (ASCII letters, digits, _ or -; generated automatically)")
        ],
        examples: [
            "patchwork threads new --cwd ~/code/myapp --worktree --name \"Nightly triage\"",
            "patchwork threads new --cwd ~/code/myapp --message \"survey the repo\" --mode ultra --json",
            "patchwork threads new --cwd ~/code/myapp --agent claude --message \"survey the repo\"",
            "patchwork threads new --cwd ~/code/myapp --client-id nightly_triage_1"
        ]
    )

    private static func new(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: newHelp) { parsed, global in
            guard let cwd = parsed.value("--cwd") else { throw UsageError.missingRequiredFlag("--cwd") }
            let requestedMessage = try resolveMessageText(parsed.value("--message"), context: context)
            let message = requestedMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            if requestedMessage != nil, message?.isEmpty != false {
                throw UsageError.invalidValue(flag: "--message", value: requestedMessage ?? "", reason: "message text is empty")
            }
            let agent = try validatedAgent(parsed.value("--agent"))
            if agent == "claude", message == nil {
                throw UsageError.custom(
                    "--agent claude requires --message because Claude Code creates its conversation with the first message"
                )
            }
            if parsed.value("--mode") != nil, message == nil {
                throw UsageError.custom("--mode requires --message because idle threads have no turn to configure")
            }
            if parsed.value("--mode") != nil, let agent, agent != "pi" {
                throw UsageError.custom("--mode is only supported with --agent pi")
            }
            let clientID = try submissionClientID(parsed.value("--client-id"))
            let plane = context.makeControlPlane(global)
            if parsed.flag("--worktree"), try await plane.health().threadWorktrees != true {
                throw CLIFailure(
                    exitCode: .requestFailed,
                    message: "the running daemon does not support thread worktrees",
                    hint: "update Patchwork and restart the active host"
                )
            }
            let response: WireCreateThreadResponse
            do {
                response = try await plane.createThread(
                    WireCreateThreadRequest(
                        cwd: cwd, name: parsed.value("--name"), message: message,
                        mode: parsed.value("--mode"), worktree: parsed.flag("--worktree") ? true : nil,
                        agent: agent, clientId: clientID
                    )
                )
            } catch {
                throw mutationFailure(error, clientID: clientID, operation: "thread creation")
            }
            if global.jsonOutput {
                context.out.json(response)
                return
            }
            context.out.line("Created thread \(Rendering.threadID(response.thread))\(response.thread.name.map { " (\($0))" } ?? "")")
            if let runId = response.runId { context.out.info("Run started: \(runId)") }
            if let error = response.firstMessageError {
                let id = Rendering.threadID(response.thread)
                context.out.errorLine("Warning: the thread was created, but its first message was not sent: \(error)")
                context.out.errorLine("Retry it with `patchwork threads send \(id) -` and provide the message on stdin.")
            }
        }
    }

    // MARK: - send

    private static let sendHelp = CommandHelp(
        usage: "patchwork threads send <id> <text|-> [--steer | --follow-up] [--wait] [--client-id ID] [--json]",
        summary: "Send a message to an existing thread. \"-\" for <text> reads the message from stdin.",
        flags: [
            FlagSpec("--steer", takesValue: false, help: "interrupt the current turn instead of queueing"),
            FlagSpec("--follow-up", takesValue: false, help: "queue behind the current turn (default: daemon decides, \"auto\")"),
            FlagSpec("--wait", takesValue: false, help: "stream the run to completion; exits non-zero if it failed"),
            FlagSpec("--client-id", takesValue: true, placeholder: "ID", help: "stable retry ID (ASCII letters, digits, _ or -; generated by default)")
        ],
        examples: [
            "patchwork threads send 019f9dea-... \"what's the status?\" --wait",
            "echo \"continue\" | patchwork threads send 019f9dea-... - --follow-up",
            "patchwork threads send 019f9dea-... \"continue\" --client-id followup_1"
        ]
    )

    private static func send(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: sendHelp) { parsed, global in
            let positionals = try requirePositionals(parsed, names: ["id", "text"])
            let id = positionals[0]
            let text = (try resolveMessageText(positionals[1], context: context) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw UsageError.custom("message text is empty") }
            if parsed.flag("--steer"), parsed.flag("--follow-up") {
                throw UsageError.conflictingFlags(["--steer", "--follow-up"])
            }
            let clientID = try submissionClientID(parsed.value("--client-id"))
            let delivery = parsed.flag("--steer") ? "steer" : (parsed.flag("--follow-up") ? "followUp" : "auto")
            let plane = context.makeControlPlane(global)
            let waitingEvents = parsed.flag("--wait") ? PreparedControlPlaneEvents(
                source: plane.events(), readinessTimeoutSeconds: global.timeoutSeconds
            ) : nil
            defer { waitingEvents?.cancel() }
            try await waitingEvents?.waitUntilReady()
            let response: WireSendMessageResponse
            do {
                response = try await plane.sendMessage(
                    threadId: id,
                    request: WireSendMessageRequest(
                        text: text,
                        delivery: delivery,
                        attachments: [],
                        clientId: clientID
                    )
                )
            } catch {
                throw mutationFailure(error, clientID: clientID, operation: "message submission")
            }

            guard parsed.flag("--wait") else {
                if global.jsonOutput {
                    context.out.json(WireSendMessageWithRunResponse(
                        runId: response.runId, queued: response.queued,
                        delivery: response.delivery, run: nil
                    ))
                } else {
                    context.out.line("Run \(response.runId)\(response.queued ? " (queued)" : " started")")
                    if let actual = response.delivery, actual != delivery {
                        context.out.info("Delivered as \(actual), not \(delivery).")
                    }
                }
                return
            }

            context.out.info("Waiting for run \(response.runId) to finish…")
            guard let waitingEvents else {
                throw CLIFailure(exitCode: .requestFailed, message: "event stream was not prepared")
            }
            let run: WireRun
            do {
                run = try await waitForRun(
                    plane: plane,
                    events: waitingEvents.events,
                    runId: response.runId,
                    out: context.out,
                    unreachableTimeoutSeconds: global.timeoutSeconds
                )
            } catch {
                let failure = asFailure(error)
                throw CLIFailure(
                    exitCode: failure.exitCode,
                    message: failure.message,
                    hint: "The daemon accepted run \(response.runId). Review that run or thread before sending the message again."
                )
            }
            if global.jsonOutput {
                context.out.json(WireSendMessageWithRunResponse(
                    runId: response.runId, queued: response.queued,
                    delivery: response.delivery, run: run
                ))
            } else {
                context.out.line("Run \(run.id) finished: \(run.status ?? "unknown")")
                if let summary = run.summary { context.out.line(summary) }
            }
            guard RunStatus.isSuccess(run.status) else {
                let hint: String
                if run.retryable == true, run.promptStartedAt == nil {
                    hint = "The prompt did not start. Retry with a new --client-id value; reusing \(clientID) only replays this failed run."
                } else {
                    hint = "The prompt may have started. Review the thread before sending the message again."
                }
                throw CLIFailure(
                    exitCode: .requestFailed,
                    message: "run \(run.id) did not succeed (\(run.status ?? "unknown"))\(run.error.map { ": \($0)" } ?? "")",
                    hint: hint
                )
            }
        }
    }

    // MARK: - abort / archive / unarchive

    private static let abortHelp = CommandHelp(
        usage: "patchwork threads abort <id> [--json]",
        summary: "Abort a thread's currently running turn, if any.",
        flags: [],
        examples: ["patchwork threads abort 019f9dea-..."]
    )

    private static func abort(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: abortHelp) { parsed, global in
            let id = try requirePositionals(parsed, names: ["id"])[0]
            let response = try await context.makeControlPlane(global).abortThread(id: id)
            if global.jsonOutput { context.out.json(response) } else { context.out.line(response.aborted ? "Aborted \(id)" : "Nothing to abort on \(id)") }
        }
    }

    private static let archiveHelp = CommandHelp(
        usage: "patchwork threads archive <id> [--json]",
        summary: "Archive a thread.",
        flags: [],
        examples: ["patchwork threads archive 019f9dea-..."]
    )

    private static func archive(_ args: [String], context: CommandContext) async -> Int32 {
        await setArchived(args, context: context, archived: true, help: archiveHelp)
    }

    private static let unarchiveHelp = CommandHelp(
        usage: "patchwork threads unarchive <id> [--json]",
        summary: "Unarchive a thread.",
        flags: [],
        examples: ["patchwork threads unarchive 019f9dea-..."]
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
        usage: "patchwork threads rename <id> <name> [--json]",
        summary: "Rename a thread.",
        flags: [],
        examples: ["patchwork threads rename 019f9dea-... \"Nightly triage\""]
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
        usage: "patchwork threads watch [<id>] [--json]",
        summary: "Stream live thread/run/activity/schedule events. Without <id>, streams every thread.",
        flags: [],
        examples: ["patchwork threads watch", "patchwork threads watch 019f9dea-... --json"]
    )

    private static func watch(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: watchHelp) { parsed, global in
            guard parsed.positionals.count <= 1 else { throw UsageError.tooManyPositionals(expected: 1, got: parsed.positionals.count) }
            let filterId = parsed.positionals.first
            context.out.info("Watching for events\(filterId.map { " on thread \($0)" } ?? "")… (Ctrl-C to stop)")
            let events = context.makeControlPlane(global).events()
            for try await event in events {
                if event.name == "ready" { continue }
                if let filterId, !eventMatches(event, threadId: filterId) { continue }
                emit(event, out: context.out, jsonOutput: global.jsonOutput, now: context.now)
            }
            throw ControlPlaneError.transportFailure("event stream ended")
        }
    }

    private static func eventMatches(_ event: ControlPlaneEvent, threadId: String) -> Bool {
        if event.name == "activity" { return true } // global snapshot; not tied to one thread
        if let eventPath = event.data["path"]?.stringValue ?? event.data["threadPath"]?.stringValue,
           URL(fileURLWithPath: eventPath).standardizedFileURL.path
            == URL(fileURLWithPath: threadId).standardizedFileURL.path {
            return true
        }
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
    private static func waitForRun(
        plane: ControlPlane,
        events: AsyncThrowingStream<ControlPlaneEvent, Error>,
        runId: String,
        out: OutputSink,
        unreachableTimeoutSeconds: Double
    ) async throws -> WireRun {
        _ = out
        if let snapshot = try? await plane.showRun(id: runId), RunStatus.isTerminal(snapshot.run.status) {
            return snapshot.run
        }
        do {
            for try await event in events {
                guard event.name == "run", event.data["id"]?.stringValue == runId else { continue }
                guard let run = try? event.data.decoded(as: WireRun.self) else { continue }
                if RunStatus.isTerminal(run.status) { return run }
            }
        } catch {
            // A bounded event buffer may close under unrelated daemon traffic. The run itself is
            // still healthy, so its authoritative endpoint becomes the fallback rather than
            // turning a successful prompt into a failed CLI command.
        }
        var unreachableSince: Date?
        let unreachableLimit = max(0.01, unreachableTimeoutSeconds)
        while !Task.isCancelled {
            do {
                let snapshot = try await plane.showRun(id: runId)
                unreachableSince = nil
                if RunStatus.isTerminal(snapshot.run.status) { return snapshot.run }
            } catch {
                let firstFailure = unreachableSince ?? Date()
                unreachableSince = firstFailure
                if Date().timeIntervalSince(firstFailure) >= unreachableLimit {
                    throw CLIFailure(
                        exitCode: .requestFailed,
                        message: "The daemon remained unreachable while waiting for run \(runId)."
                    )
                }
            }
            let delay = min(0.5, unreachableLimit)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        throw CancellationError()
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

    static func submissionClientID(
        _ raw: String?, minimumLength: Int = 1, maximumLength: Int = 128
    ) throws -> String {
        let value = raw ?? UUID().uuidString.lowercased()
        let bytes = value.utf8
        let isAllowed = bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122) || byte == 95 || byte == 45
        }
        guard (minimumLength...maximumLength).contains(bytes.count), isAllowed else {
            throw UsageError.invalidValue(
                flag: "--client-id", value: value,
                reason: "expected \(minimumLength) to \(maximumLength) ASCII letters, digits, underscores, or hyphens"
            )
        }
        return value
    }

    static func mutationFailure(
        _ error: Error, clientID: String, operation: String
    ) -> CLIFailure {
        let failure = asFailure(error)
        if let plane = error as? ControlPlaneError, case .outcomeUnknown = plane {
            let review: String
            switch operation {
            case "thread creation":
                review = "Review the thread list before retrying. The active daemon did not confirm replay-safe creation."
            case "schedule creation":
                review = "Review the schedule list before retrying. The active daemon did not confirm replay-safe schedule creation."
            case "manual schedule run":
                review = "Review the schedule's run history before retrying. The active daemon did not confirm replay-safe manual runs."
            default:
                review = "Review the thread before retrying. The active daemon did not confirm replay safety."
            }
            return CLIFailure(exitCode: failure.exitCode, message: failure.message, hint: review)
        }
        if case let ControlPlaneError.apiError(_, code, _) = error {
            if code == "submission_outcome_unknown" || code == "creation_outcome_unknown"
                || code == "schedule_run_outcome_unknown" {
                let review: String
                switch operation {
                case "thread creation":
                    review = "Review the thread list before doing anything else. Do not retry this creation automatically."
                case "schedule creation":
                    review = "Review the schedule list before doing anything else. Do not create another schedule automatically."
                case "manual schedule run":
                    review = "Review the schedule's run history before doing anything else. Do not start another run automatically."
                default:
                    review = "Review the thread before doing anything else. Do not resend this message automatically."
                }
                return CLIFailure(
                    exitCode: failure.exitCode,
                    message: failure.message,
                    hint: failure.hint.map { "\($0). \(review)" } ?? review
                )
            }
            if code == "submission_id_conflict" || code == "creation_id_conflict"
                || code == "idempotency_conflict" || code == "run_id_conflict" {
                let review = operation == "schedule creation"
                    ? "This retry id belongs to different input. Review the schedule list, then use a new id only for a genuinely new schedule."
                    : "This retry id belongs to different input. Review existing work, then use a new id only for a genuinely new request."
                return CLIFailure(
                    exitCode: failure.exitCode,
                    message: failure.message,
                    hint: failure.hint.map { "\($0). \(review)" } ?? review
                )
            }
            if code == "submission_in_flight" || code == "creation_in_flight"
                || code == "schedule_run_in_flight" || code == "submissions_busy"
                || code == "creations_busy" || code == "create_retryable"
                || code == "creation_pending" || code == "submission_ledger_unavailable" {
                let retry = "Retry the exact \(operation) with --client-id \(clientID) within 30 minutes. This keeps the same protected request identity; after that window, review the authoritative list or history before doing anything else."
                return CLIFailure(
                    exitCode: failure.exitCode,
                    message: failure.message,
                    hint: failure.hint.map { "\($0). \(retry)" } ?? retry
                )
            }
            return failure
        }
        guard let plane = error as? ControlPlaneError else { return failure }
        switch plane {
        case .unreachable:
            return failure
        case .timedOut, .transportFailure, .malformedResponse:
            break
        case .apiError, .outcomeUnknown:
            return failure
        }
        let retry = "Retry the exact \(operation) with --client-id \(clientID) within 30 minutes. The daemon will replay an accepted request inside that window; after it expires, review the authoritative list or history before doing anything else."
        let hint = failure.hint.map { "\($0). \(retry)" } ?? retry
        return CLIFailure(exitCode: failure.exitCode, message: failure.message, hint: hint)
    }

    /// Caught here rather than at the daemon so a typo costs no round trip and the error names
    /// the valid agents. The list is the CLI's own, so a newer daemon's agent is still accepted
    /// on the wire \u2014 it just cannot be typed as a filter until this CLI learns it.
    static let agents = ["pi", "codex", "claude"]

    static func validatedAgent(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard !raw.isEmpty else {
            throw UsageError.invalidValue(flag: "--agent", value: raw, reason: "agent must not be empty")
        }
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

/// Opens the event stream before a mutating request and waits until the daemon confirms that the
/// subscription is installed. Later events stay in a bounded buffer while the request runs.
private final class PreparedControlPlaneEvents: @unchecked Sendable {
    let events: AsyncThrowingStream<ControlPlaneEvent, Error>
    private let ready: AsyncThrowingStream<Void, Error>
    private let readinessTimeoutSeconds: Double
    private let readinessTimeoutNanoseconds: UInt64
    private var task: Task<Void, Never>?

    init(source: AsyncThrowingStream<ControlPlaneEvent, Error>, readinessTimeoutSeconds: Double) {
        let boundedTimeout = min(max(readinessTimeoutSeconds, 0.001), 86_400)
        self.readinessTimeoutSeconds = boundedTimeout
        readinessTimeoutNanoseconds = UInt64(boundedTimeout * 1_000_000_000)
        var readyContinuation: AsyncThrowingStream<Void, Error>.Continuation!
        ready = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) {
            readyContinuation = $0
        }
        var eventContinuation: AsyncThrowingStream<ControlPlaneEvent, Error>.Continuation!
        events = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) {
            eventContinuation = $0
        }

        task = Task {
            var didSignalReady = false
            do {
                for try await event in source {
                    if !didSignalReady, event.name == "ready" {
                        didSignalReady = true
                        readyContinuation.yield(())
                        readyContinuation.finish()
                    }
                    if event.name == "ready" { continue }
                    switch eventContinuation.yield(event) {
                    case .enqueued:
                        break
                    case .dropped:
                        let error = ControlPlaneError.transportFailure("event consumer fell behind")
                        eventContinuation.finish(throwing: error)
                        return
                    case .terminated:
                        return
                    @unknown default:
                        return
                    }
                }
                if !didSignalReady {
                    readyContinuation.finish(throwing: ControlPlaneError.transportFailure(
                        "event stream ended before the ready barrier"
                    ))
                }
                eventContinuation.finish(throwing: ControlPlaneError.transportFailure(
                    "event stream ended"
                ))
            } catch {
                if !didSignalReady { readyContinuation.finish(throwing: error) }
                eventContinuation.finish(throwing: error)
            }
        }
    }

    func waitUntilReady() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask { [ready] in
                var iterator = ready.makeAsyncIterator()
                guard try await iterator.next() != nil else {
                    throw ControlPlaneError.transportFailure(
                        "event stream ended before the ready barrier"
                    )
                }
            }
            group.addTask { [readinessTimeoutNanoseconds, readinessTimeoutSeconds] in
                try await Task.sleep(nanoseconds: readinessTimeoutNanoseconds)
                throw ControlPlaneError.timedOut(
                    "event stream did not become ready within \(readinessTimeoutSeconds) seconds"
                )
            }
            _ = try await group.next()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

/// Stable `threads send --json` shape: `run` is always present (null unless --wait was given) so
/// scripts can rely on a fixed key set regardless of flags.
struct WireSendMessageWithRunResponse: Codable, Equatable {
    var runId: String
    var queued: Bool
    var delivery: String?
    var run: WireRun?

    private enum CodingKeys: String, CodingKey { case runId, queued, delivery, run }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runId, forKey: .runId)
        try container.encode(queued, forKey: .queued)
        try container.encode(delivery, forKey: .delivery)
        try container.encode(run, forKey: .run)
    }
}

/// Stable `threads watch --json` / one-line-per-event shape (this CLI's own envelope — the SSE
/// wire format itself has no single JSON object per message).
struct WatchEventLine: Codable, Equatable {
    var event: String
    var receivedAt: String
    var data: JSONValue
}
