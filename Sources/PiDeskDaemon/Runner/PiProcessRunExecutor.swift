import Foundation
import PiDeskKit

/// The real `RunExecuting`: spawns `pi --mode rpc`, attaches to the target session (or creates
/// one in a cwd), applies `mode` if requested, sends the prompt, streams events until
/// `agent_settled` (or Pi Desktop's command-only completion marker), then stops the runtime.
/// This is the only type in the daemon that actually
/// launches Pi; every test uses a fake `RunExecuting` instead.
struct PiProcessRunExecutor: RunExecuting {
    let logger: DaemonLogger
    /// Test/override seam for the executable path itself; production leaves this nil and defers
    /// to `PiLocator`, exactly like the app does.
    var piExecutableOverride: URL?
    /// Where dialogs this run blocks on are published, and where their answers come back from.
    var interactions: InteractionRegistry?
    /// Publishes this run's session while its turn is in flight, so `POST .../messages` with
    /// `delivery: steer` has something to interrupt.
    var liveSessions: LiveSessionRegistry?

    func execute(_ job: RunJob) async -> RunOutcome {
        do {
            return try await runProtocol(job)
        } catch let error as RunnerError {
            logger.error("Run \(job.id) failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription, retryable: error.retryableBeforePrompt)
        } catch {
            logger.error("Run \(job.id) failed with an unexpected error: \(error)")
            return .failed("\(error)")
        }
    }

    private func runProtocol(_ job: RunJob) async throws -> RunOutcome {
        let agent = job.target.agent
        // The executable is resolved for the thread's own agent, and the adapter translates this
        // run's commands into that agent's protocol. Nothing below this line is agent-specific.
        guard let executable = piExecutableOverride ?? AgentCatalog.executable(for: agent) else {
            throw RunnerError.agentNotFound(agent)
        }

        let cwd: URL
        let sessionPath: URL?
        switch job.target {
        case let .existingThread(_, path, cwdPath, _):
            cwd = URL(fileURLWithPath: cwdPath)
            sessionPath = URL(fileURLWithPath: path)
        case let .newThread(cwdPath, _, _):
            cwd = URL(fileURLWithPath: cwdPath)
            sessionPath = nil
        }
        let initialSessionName = Self.initialSessionName(for: job)
        let adapter = AgentAdapterFactory.make(agent)
        let environment = AgentCatalog.augmentedEnvironment(executable: executable, cwd: cwd)
        let session = try PiRPCSession.start(
            cwd: cwd, sessionPath: sessionPath, piExecutable: executable, environment: environment,
            initialSessionID: sessionPath == nil ? job.initialSessionID : nil,
            initialSessionName: sessionPath == nil ? initialSessionName : nil,
            adapter: adapter
        )
        defer { session.stop() }

        let stateID = try session.send(type: "get_state")
        let stateResponse = try await session.receiveMatching(id: stateID, timeout: 30)
        if let message = Self.responseError(stateResponse) { throw RunnerError.processExited(message) }
        let data = stateResponse["data"]
        let resolvedThreadId = data?["sessionId"]?.stringValue
        let resolvedThreadPath = data?["sessionFile"]?.stringValue
        if sessionPath == nil, let expected = job.initialSessionID,
           resolvedThreadId != expected {
            throw RunnerError.processExited(
                "\(agent.displayName) resolved session \(resolvedThreadId ?? "<missing>") instead of the preallocated identity \(expected)."
            )
        }
        if let expected = job.target.existingThreadID, resolvedThreadId != expected {
            throw RunnerError.processExited(
                "\(agent.displayName) resumed session \(resolvedThreadId ?? "<missing>") instead of the requested identity \(expected)."
            )
        }
        if sessionPath == nil,
           let resolvedThreadId, !resolvedThreadId.isEmpty,
           let resolvedThreadPath, !resolvedThreadPath.isEmpty {
            if await job.onThreadIdentityResolved?(resolvedThreadId, resolvedThreadPath) == false {
                return RunOutcome(
                    status: .failed,
                    error: "Another runtime already owns the conversation this agent resolved.",
                    summary: nil,
                    resolvedThreadId: resolvedThreadId,
                    resolvedThreadPath: resolvedThreadPath,
                    retryable: true
                )
            }
        }

        if sessionPath == nil, agent.capabilities.canRenameSession,
           let initialSessionName {
            do {
                let nameID = try session.send(
                    type: "set_session_name", payload: ["name": .string(initialSessionName)]
                )
                let response = try await session.receiveMatching(id: nameID, timeout: 30)
                if let message = Self.responseError(response) {
                    logger.warn("Run \(job.id) created its thread, but the initial name was rejected: \(message)")
                }
            } catch {
                logger.warn("Run \(job.id) created its thread, but the initial name could not be confirmed: \(error)")
            }
        }

        if let command = Self.piModeCommand(job.mode, agent: agent) {
            let modeID = try session.send(type: "prompt", payload: ["message": .string(command)])
            let modeResponse = try await session.receiveMatching(id: modeID, timeout: 300)
            if let message = Self.responseError(modeResponse) {
                return RunOutcome(status: .failed, error: "Could not apply \(command): \(message)", summary: nil, resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath)
            }
        }

        // Persist the ambiguous-delivery boundary before writing a byte of the real prompt. If
        // that durable transition fails, stop: executing without it could duplicate side effects
        // after a crash and restart.
        if Task.isCancelled {
            return RunOutcome(
                status: .interrupted, error: "The run stopped before prompt delivery.", summary: nil,
                resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath,
                retryable: true
            )
        }
        let promptStartedAt = Date()
        if let onPromptDispatch = job.onPromptDispatch {
            switch await onPromptDispatch(promptStartedAt) {
            case .ready:
                break
            case .retry:
                return RunOutcome(
                    status: .failed, error: "Could not persist this automation before prompt delivery.", summary: nil,
                    resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath,
                    retryable: true
                )
            case .cancelled:
                return RunOutcome(
                    status: .interrupted, error: "This automation was removed before prompt delivery.", summary: nil,
                    resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath
                )
            }
        }

        if Task.isCancelled {
            return RunOutcome(
                status: .interrupted, error: "The run stopped at the prompt delivery boundary.", summary: nil,
                resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath,
                promptStartedAt: promptStartedAt
            )
        }

        let promptResponse: PiJSONValue
        do {
            let promptID = try session.send(type: "prompt", payload: ["message": .string(job.prompt)])
            promptResponse = try await session.receiveMatching(id: promptID, timeout: 300)
        } catch {
            // Bytes may have reached Pi even without an acknowledgement. Never blindly resend an
            // arbitrary prompt whose delivery outcome is unknown.
            return RunOutcome(
                status: .interrupted, error: "Prompt delivery was interrupted; its outcome is unknown.", summary: nil,
                resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath,
                promptStartedAt: promptStartedAt
            )
        }
        if let message = Self.responseError(promptResponse) {
            return RunOutcome(
                status: .failed, error: message, summary: nil,
                resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath,
                promptStartedAt: promptStartedAt
            )
        }
        let promptAcceptedAt = Date()
        await job.onPromptAccepted?(promptAcceptedAt)

        // Only published once Pi has accepted the prompt and only until admission is closed at a
        // settle boundary: outside that window there is no turn to steer into, and a caller must
        // fall back to a fresh queued run.
        let liveThreadID = job.target.existingThreadID ?? resolvedThreadId
        let liveThreadKey = (job.target.existingThreadPath ?? resolvedThreadPath).map {
            ThreadInstanceKey(path: $0)
        }
        if let liveThreadKey, let liveSessions {
            liveSessions.register(thread: liveThreadKey, runID: job.id, handle: PiSessionRuntimeHandle(session: session))
        }
        if let resolvedThreadId, !resolvedThreadId.isEmpty,
           let resolvedThreadPath, !resolvedThreadPath.isEmpty {
            await job.onThreadReady?(resolvedThreadId, resolvedThreadPath)
        }
        // Not a `defer`: unregistering has to happen only *after* `consumeUntilSettled` has closed
        // admission, and the ordering matters more than the brevity. `session.stop()`'s own defer
        // still runs after this, so the process is never left behind on a throw.
        do {
            let outcome = try await consumeUntilSettled(
                session, job: job, liveThreadKey: liveThreadKey, interactionThreadID: liveThreadID,
                interactionThreadPath: job.target.existingThreadPath ?? resolvedThreadPath,
                resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath,
                promptStartedAt: promptStartedAt, promptAcceptedAt: promptAcceptedAt
            )
            await finishLive(session, liveThreadKey: liveThreadKey, job: job)
            return outcome
        } catch {
            await finishLive(session, liveThreadKey: liveThreadKey, job: job)
            logger.error("Run \(job.id) was interrupted after Pi accepted its prompt: \(error)")
            return RunOutcome(
                status: .interrupted, error: "The accepted run was interrupted before it settled.", summary: nil,
                resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath,
                promptStartedAt: promptStartedAt, promptAcceptedAt: promptAcceptedAt
            )
        }
    }

    static func piModeCommand(_ raw: String?, agent: AgentKind) -> String? {
        guard agent == .pi,
              let mode = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mode.isEmpty else { return nil }
        return "/mode \(mode)"
    }

    static func initialSessionName(for job: RunJob) -> String? {
        guard case let .newThread(_, pattern, _) = job.target,
              let pattern = pattern?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pattern.isEmpty else { return nil }
        guard job.scheduleId != nil, pattern.contains("{date}") else {
            return ThreadCreationService.boundedInitialName(pattern)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let expanded = pattern.replacingOccurrences(
            of: "{date}", with: formatter.string(from: job.scheduledAt ?? job.queuedAt)
        )
        return ThreadCreationService.boundedInitialName(expanded)
    }

    private func finishLive(_ session: PiRPCSession, liveThreadKey: ThreadInstanceKey?, job: RunJob) async {
        if let liveThreadKey, let liveSessions {
            // A settle boundary already closed admission with nothing in flight, so this returns
            // at once on the ordinary path. A timeout or an abort is the case it exists for:
            // those arrive whenever they like, including while a steer is being written, and
            // `session.stop()` (this function's caller's `defer`) would kill the process while
            // its HTTP caller is still waiting to hear what happened. Admission closes for good
            // first, then the writes already in flight get a bounded chance to land — pumping the
            // pipe as they do, because an acknowledgement nobody reads is indistinguishable from
            // one Pi never sent, and "outcome unknown" is never retried.
            await liveSessions.drainForShutdown(
                thread: liveThreadKey, runID: job.id,
                deadline: Date().addingTimeInterval(LiveSessionRegistry.drainSeconds)
            ) {
                // A process that has already exited can neither acknowledge anything nor be
                // stopped twice, so there is nothing left to wait for.
                guard session.isRunning else { return false }
                // `receiveNext` caches every response it decodes, which is exactly what an
                // in-flight `deliver` is waiting on.
                _ = try? await session.receiveNext(timeout: 0.1)
                return true
            }
            liveSessions.unregister(thread: liveThreadKey, runID: job.id)
        }
        interactions?.cancelAll(runID: job.id)
    }

    /// Polls in short slices (rather than one long wait) so both the run's own timeout and
    /// cooperative cancellation from `RunManager`'s timeout race are noticed within a few
    /// seconds instead of only after the next Pi event arrives.
    private static let commandOnlyReviewPrompt = "/pi-desktop-pr-review "
    private static let commandOnlyReviewStatus = "pi-desktop-pr-review-complete"

    private static func isCommandOnlyCompletion(_ event: PiJSONValue, prompt: String) -> Bool {
        prompt.hasPrefix(commandOnlyReviewPrompt)
            && event["type"]?.stringValue == "extension_ui_request"
            && event["method"]?.stringValue == "setStatus"
            && event["statusKey"]?.stringValue == commandOnlyReviewStatus
            && event["statusText"] == nil
    }

    private func consumeUntilSettled(
        _ session: PiRPCSession, job: RunJob, liveThreadKey: ThreadInstanceKey?,
        interactionThreadID: String?,
        interactionThreadPath: String?,
        resolvedThreadId: String?, resolvedThreadPath: String?,
        promptStartedAt: Date, promptAcceptedAt: Date
    ) async throws -> RunOutcome {
        var lastAssistantText: String?
        var lastAssistantIsError = false
        // Bounded: the app's own questionnaire parser accepts at most four questions per call, and
        // only the newest call's questions can still be unanswered.
        var questionSpecs: [QuestionSpec] = []
        var deadline = Date().addingTimeInterval(TimeInterval(job.timeoutSeconds))
        // Set while a settle boundary is waiting on an in-flight live write; the loop then polls
        // in short slices instead of sitting in a five-second receive.
        var retryingClose = false

        func timedOut() -> RunOutcome {
            RunOutcome(
                status: .timeout, error: "Run exceeded its \(job.timeoutSeconds)s timeout.",
                summary: lastAssistantText, resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath,
                promptStartedAt: promptStartedAt, promptAcceptedAt: promptAcceptedAt
            )
        }

        while true {
            if Task.isCancelled { return timedOut() }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return timedOut() }

            if retryingClose, let liveThreadKey, let liveSessions {
                switch liveSessions.closeAdmission(thread: liveThreadKey, runID: job.id) {
                case .closed:
                    return settledOutcome(
                        lastAssistantText, lastAssistantIsError, resolvedThreadId, resolvedThreadPath,
                        promptStartedAt, promptAcceptedAt
                    )
                case .continueConsuming:
                    retryingClose = false
                    deadline = Self.extendedDeadline(deadline)
                case .busy:
                    break
                }
            }

            let slice = retryingClose ? 0.25 : 5
            guard let event = try await session.receiveNext(timeout: min(remaining, slice)) else { continue }
            let type = event["type"]?.stringValue

            // Pi announces `ask_user_question` on `tool_execution_start` with `toolName`/`args`,
            // exactly as the app reads it. The content-block form is also accepted because a
            // streaming update or `message_end` can carry the same call, and neither is guaranteed
            // to arrive before the dialog does.
            let specs = QuestionnaireSpecParser.specs(inEvent: event)
            if !specs.isEmpty { questionSpecs = specs }

            if type == "extension_ui_request" {
                registerInteraction(
                    event, session: session, job: job,
                    threadID: interactionThreadID, threadPath: interactionThreadPath,
                    specs: questionSpecs
                )
            }

            if type == "message_end", let message = event["message"], message["role"]?.stringValue == "assistant" {
                lastAssistantText = Self.firstLine(from: message["content"]) ?? lastAssistantText
                lastAssistantIsError = message["isError"]?.boolValue ?? (message["stopReason"]?.stringValue == "error")
            }
            if type == "agent_settled" || Self.isCommandOnlyCompletion(event, prompt: job.prompt) {
                // A settle boundary is the only place this run may stop accepting live messages,
                // and closing admission is what makes that safe: a steer accepted moments ago owns
                // the turn now starting, and stopping the session here would discard it.
                guard let liveThreadKey, let liveSessions else {
                    return settledOutcome(
                        lastAssistantText, lastAssistantIsError, resolvedThreadId, resolvedThreadPath,
                        promptStartedAt, promptAcceptedAt
                    )
                }
                switch liveSessions.closeAdmission(thread: liveThreadKey, runID: job.id) {
                case .closed:
                    return settledOutcome(
                        lastAssistantText, lastAssistantIsError, resolvedThreadId, resolvedThreadPath,
                        promptStartedAt, promptAcceptedAt
                    )
                case .continueConsuming:
                    deadline = Self.extendedDeadline(deadline)
                case .busy:
                    retryingClose = true
                }
            }
        }
    }

    /// A message steered in at the very end of a long run deserves a real turn rather than the
    /// few seconds its host run happened to have left. Bounded twice over: the extension is fixed,
    /// and `LiveSessionRegistry.maxTurnCredits` caps how many times it can be granted.
    static let turnGraceSeconds: TimeInterval = 300

    private static func extendedDeadline(_ current: Date) -> Date {
        max(current, Date().addingTimeInterval(turnGraceSeconds))
    }

    private func settledOutcome(
        _ text: String?, _ isError: Bool, _ threadId: String?, _ threadPath: String?,
        _ promptStartedAt: Date, _ promptAcceptedAt: Date
    ) -> RunOutcome {
        RunOutcome(
            status: isError ? .failed : .ok,
            error: isError ? (text ?? "The run finished with an error.") : nil,
            summary: text, resolvedThreadId: threadId, resolvedThreadPath: threadPath,
            promptStartedAt: promptStartedAt, promptAcceptedAt: promptAcceptedAt
        )
    }

    /// The methods the app itself handles *without* replying: they expect no response, so turning
    /// one into a dialog would invent a prompt nobody can dismiss. Everything else is treated as
    /// potentially blocking and surfaced, because a method this build has never seen may well be
    /// holding the run hostage — a visible card with a Cancel button is the only safe default,
    /// and silently ignoring it is not.
    private static let nonBlockingDialogMethods: Set<String> = [
        "notify", "setstatus", "setwidget", "settitle", "set_editor_text", "seteditortext"
    ]

    /// Bounds on what one dialog may carry into the registry and out over the API.
    private static let maxOptionCount = 100
    private static let maxOptionLength = 500
    private static let maxOptionsTotalLength = 20_000

    private func registerInteraction(
        _ event: PiJSONValue, session: PiRPCSession, job: RunJob,
        threadID: String?, threadPath: String?, specs: [QuestionSpec]
    ) {
        guard let id = event["id"]?.stringValue, !id.isEmpty,
              let method = event["method"]?.stringValue,
              !Self.nonBlockingDialogMethods.contains(method.lowercased()) else { return }

        let wireID = id
        let publicID = "\(job.id):\(wireID)"
        let cancel: @Sendable () -> Void = {
            try? session.sendRaw([
                "type": .string("extension_ui_response"), "id": .string(wireID), "cancelled": .bool(true)
            ])
        }
        guard let interactions else { return cancel() }

        let title = event["title"]?.stringValue ?? "Pi"
        let spec = QuestionnaireSpecParser.match(specs, title: title, method: method)
        let rawOptions = Self.boundedOptions(event["options"]?.arrayValue)
        let requested = event["timeout"]?.intValue.map { TimeInterval($0) / 1_000 }
        let timeout = min(max(requested ?? InteractionRegistry.defaultTimeout, 1), InteractionRegistry.maxTimeout)

        let interaction = PendingInteraction(
            id: publicID,
            runId: job.id,
            threadId: threadID,
            threadPath: threadPath,
            method: InteractionMethod(rawValue: method),
            title: String(title.prefix(2_000)),
            message: event["message"]?.stringValue.map { String($0.prefix(4_000)) },
            options: rawOptions,
            placeholder: event["placeholder"]?.stringValue.map { String($0.prefix(500)) },
            prefill: event["prefill"]?.stringValue.map { String($0.prefix(20_000)) },
            expiresAt: Date().addingTimeInterval(timeout),
            header: spec?.header,
            multiSelect: spec?.multiSelect ?? false,
            choices: QuestionnaireSpecParser.choices(for: spec, rawOptions: rawOptions, multiSelect: spec?.multiSelect ?? false),
            questionIndex: spec?.index,
            questionCount: spec?.count
        )

        let registered = interactions.register(interaction) { response in
            // Throwing rather than swallowing: a write that never reached Pi must fail the
            // caller's request, not be reported as an answered dialog.
            var wireResponse = response
            wireResponse["id"] = .string(wireID)
            try session.sendRaw(wireResponse)
        }
        if !registered {
            // Pi is blocked on this request; refusing it explicitly is the only safe way to stay
            // within the bound.
            logger.warn("Interaction \(publicID) refused: too many dialogs are already pending.")
            cancel()
        }
    }

    /// Each option is length-capped and the set is capped both in count and in total size, so one
    /// pathological dialog cannot inflate every `GET /v1/interactions` response after it.
    private static func boundedOptions(_ raw: [PiJSONValue]?) -> [String] {
        var total = 0
        var options: [String] = []
        for value in (raw ?? []).prefix(maxOptionCount) {
            guard let string = value.stringValue else { continue }
            let bounded = string.count <= maxOptionLength ? string : String(string.prefix(maxOptionLength - 1)) + "\u{2026}"
            guard total + bounded.count <= maxOptionsTotalLength else { break }
            total += bounded.count
            options.append(bounded)
        }
        return options
    }

    /// Matches the app's own `AppStore.responseError(_:)`: `success == false` carries the
    /// message in `error`, never in `data`.
    private static func responseError(_ response: PiJSONValue) -> String? {
        guard response["success"]?.boolValue == false else { return nil }
        return response["error"]?.stringValue ?? "Pi rejected the command."
    }

    private static func firstLine(from content: PiJSONValue?) -> String? {
        let text: String?
        if let string = content?.stringValue {
            text = string
        } else {
            let joined = (content?.arrayValue ?? []).compactMap { block -> String? in
                guard block["type"]?.stringValue == "text" else { return nil }
                return block["text"]?.stringValue
            }.joined(separator: "\n")
            text = joined.isEmpty ? nil : joined
        }
        guard let text, !text.isEmpty else { return nil }
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        return firstLine.count > 240 ? String(firstLine.prefix(239)) + "\u{2026}" : firstLine
    }
}
