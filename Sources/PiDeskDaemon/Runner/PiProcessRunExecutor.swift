import Foundation
import PiDeskKit

/// The real `RunExecuting`: spawns `pi --mode rpc`, attaches to the target session (or creates
/// one in a cwd), applies `mode` if requested, sends the prompt, streams events until
/// `agent_settled`, then stops the runtime. This is the only type in the daemon that actually
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
            return .failed(error.localizedDescription)
        } catch {
            logger.error("Run \(job.id) failed with an unexpected error: \(error)")
            return .failed("\(error)")
        }
    }

    private func runProtocol(_ job: RunJob) async throws -> RunOutcome {
        guard let piURL = piExecutableOverride ?? PiLocator.resolve() else { throw RunnerError.piNotFound }

        let cwd: URL
        let sessionPath: URL?
        switch job.target {
        case let .existingThread(_, path, cwdPath):
            cwd = URL(fileURLWithPath: cwdPath)
            sessionPath = URL(fileURLWithPath: path)
        case let .newThread(cwdPath, _):
            cwd = URL(fileURLWithPath: cwdPath)
            sessionPath = nil
        }
        let environment = PiLocator.augmentedEnvironment(piURL: piURL, cwd: cwd)
        let session = try PiRPCSession.start(cwd: cwd, sessionPath: sessionPath, piExecutable: piURL, environment: environment)
        defer { session.stop() }

        let stateID = try session.send(type: "get_state")
        let stateResponse = try await session.receiveMatching(id: stateID, timeout: 30)
        if let message = Self.responseError(stateResponse) { throw RunnerError.processExited(message) }
        let data = stateResponse["data"]
        let resolvedThreadId = data?["sessionId"]?.stringValue
        let resolvedThreadPath = data?["sessionFile"]?.stringValue

        if let mode = job.mode?.trimmingCharacters(in: .whitespaces), !mode.isEmpty {
            let modeID = try session.send(type: "prompt", payload: ["message": .string("/mode \(mode)")])
            let modeResponse = try await session.receiveMatching(id: modeID, timeout: 300)
            if let message = Self.responseError(modeResponse) {
                return RunOutcome(status: .failed, error: "Could not apply mode \"\(mode)\": \(message)", summary: nil, resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath)
            }
        }

        let promptID = try session.send(type: "prompt", payload: ["message": .string(job.prompt)])
        let promptResponse = try await session.receiveMatching(id: promptID, timeout: 300)
        if let message = Self.responseError(promptResponse) {
            return RunOutcome(status: .failed, error: message, summary: nil, resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath)
        }

        // Only published once Pi has accepted the prompt and only until admission is closed at a
        // settle boundary: outside that window there is no turn to steer into, and a caller must
        // fall back to a fresh queued run.
        let liveThreadID = job.target.existingThreadID ?? resolvedThreadId
        if let liveThreadID, let liveSessions {
            liveSessions.register(threadID: liveThreadID, runID: job.id, handle: PiSessionRuntimeHandle(session: session))
        }
        // Not a `defer`: unregistering has to happen only *after* `consumeUntilSettled` has closed
        // admission, and the ordering matters more than the brevity. `session.stop()`'s own defer
        // still runs after this, so the process is never left behind on a throw.
        do {
            let outcome = try await consumeUntilSettled(
                session, job: job, liveThreadID: liveThreadID,
                resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath
            )
            await finishLive(session, liveThreadID: liveThreadID, job: job)
            return outcome
        } catch {
            await finishLive(session, liveThreadID: liveThreadID, job: job)
            throw error
        }
    }

    private func finishLive(_ session: PiRPCSession, liveThreadID: String?, job: RunJob) async {
        if let liveThreadID, let liveSessions {
            // A settle boundary already closed admission with nothing in flight, so this returns
            // at once on the ordinary path. A timeout or an abort is the case it exists for:
            // those arrive whenever they like, including while a steer is being written, and
            // `session.stop()` (this function's caller's `defer`) would kill the process while
            // its HTTP caller is still waiting to hear what happened. Admission closes for good
            // first, then the writes already in flight get a bounded chance to land — pumping the
            // pipe as they do, because an acknowledgement nobody reads is indistinguishable from
            // one Pi never sent, and "outcome unknown" is never retried.
            await liveSessions.drainForShutdown(
                threadID: liveThreadID, runID: job.id,
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
            liveSessions.unregister(threadID: liveThreadID, runID: job.id)
        }
        interactions?.cancelAll(runID: job.id)
    }

    /// Polls in short slices (rather than one long wait) so both the run's own timeout and
    /// cooperative cancellation from `RunManager`'s timeout race are noticed within a few
    /// seconds instead of only after the next Pi event arrives.
    private func consumeUntilSettled(
        _ session: PiRPCSession, job: RunJob, liveThreadID: String?,
        resolvedThreadId: String?, resolvedThreadPath: String?
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
                summary: lastAssistantText, resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath
            )
        }

        while true {
            if Task.isCancelled { return timedOut() }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return timedOut() }

            if retryingClose, let liveThreadID, let liveSessions {
                switch liveSessions.closeAdmission(threadID: liveThreadID, runID: job.id) {
                case .closed:
                    return settledOutcome(lastAssistantText, lastAssistantIsError, resolvedThreadId, resolvedThreadPath)
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
                registerInteraction(event, session: session, job: job, threadID: liveThreadID, specs: questionSpecs)
            }

            if type == "message_end", let message = event["message"], message["role"]?.stringValue == "assistant" {
                lastAssistantText = Self.firstLine(from: message["content"]) ?? lastAssistantText
                lastAssistantIsError = message["isError"]?.boolValue ?? (message["stopReason"]?.stringValue == "error")
            }
            if type == "agent_settled" {
                // The settle boundary is the only place this run may stop accepting live messages,
                // and closing admission is what makes that safe: a steer accepted moments ago owns
                // the turn now starting, and stopping the session here would discard it.
                guard let liveThreadID, let liveSessions else {
                    return settledOutcome(lastAssistantText, lastAssistantIsError, resolvedThreadId, resolvedThreadPath)
                }
                switch liveSessions.closeAdmission(threadID: liveThreadID, runID: job.id) {
                case .closed:
                    return settledOutcome(lastAssistantText, lastAssistantIsError, resolvedThreadId, resolvedThreadPath)
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

    private func settledOutcome(_ text: String?, _ isError: Bool, _ threadId: String?, _ threadPath: String?) -> RunOutcome {
        RunOutcome(
            status: isError ? .failed : .ok,
            error: isError ? (text ?? "The run finished with an error.") : nil,
            summary: text,
            resolvedThreadId: threadId,
            resolvedThreadPath: threadPath
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

    private func registerInteraction(_ event: PiJSONValue, session: PiRPCSession, job: RunJob, threadID: String?, specs: [QuestionSpec]) {
        guard let id = event["id"]?.stringValue, !id.isEmpty,
              let method = event["method"]?.stringValue,
              !Self.nonBlockingDialogMethods.contains(method.lowercased()) else { return }

        let cancel: @Sendable () -> Void = {
            try? session.sendRaw([
                "type": .string("extension_ui_response"), "id": .string(id), "cancelled": .bool(true)
            ])
        }
        guard let interactions else { return cancel() }

        let title = event["title"]?.stringValue ?? "Pi"
        let spec = QuestionnaireSpecParser.match(specs, title: title, method: method)
        let rawOptions = Self.boundedOptions(event["options"]?.arrayValue)
        let requested = event["timeout"]?.intValue.map { TimeInterval($0) / 1_000 }
        let timeout = min(max(requested ?? InteractionRegistry.defaultTimeout, 1), InteractionRegistry.maxTimeout)

        let interaction = PendingInteraction(
            id: id,
            runId: job.id,
            threadId: threadID,
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
            try session.sendRaw(response)
        }
        if !registered {
            // Pi is blocked on this request; refusing it explicitly is the only safe way to stay
            // within the bound.
            logger.warn("Interaction \(id) refused: too many dialogs are already pending.")
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
