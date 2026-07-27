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

        // Only published once Pi has accepted the prompt and only until the turn settles: outside
        // that window there is no turn to steer into, and a caller must fall back to the queue.
        let liveThreadID = job.target.existingThreadID ?? resolvedThreadId
        if let liveThreadID, let liveSessions {
            liveSessions.register(threadID: liveThreadID, runID: job.id, handle: PiSessionRuntimeHandle(session: session))
        }
        defer {
            if let liveThreadID { liveSessions?.unregister(threadID: liveThreadID, runID: job.id) }
            interactions?.cancelAll(runID: job.id)
        }

        return try await consumeUntilSettled(session, job: job, resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath)
    }

    /// Polls in short slices (rather than one long wait) so both the run's own timeout and
    /// cooperative cancellation from `RunManager`'s timeout race are noticed within a few
    /// seconds instead of only after the next Pi event arrives.
    private func consumeUntilSettled(_ session: PiRPCSession, job: RunJob, resolvedThreadId: String?, resolvedThreadPath: String?) async throws -> RunOutcome {
        var lastAssistantText: String?
        var lastAssistantIsError = false
        // Bounded: the app's own questionnaire parser accepts at most four questions per call, and
        // only the newest call's questions can still be unanswered.
        var questionSpecs: [QuestionSpec] = []
        let deadline = Date().addingTimeInterval(TimeInterval(job.timeoutSeconds))

        while true {
            if Task.isCancelled {
                return RunOutcome(status: .timeout, error: "Run exceeded its \(job.timeoutSeconds)s timeout.", summary: lastAssistantText, resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                return RunOutcome(status: .timeout, error: "Run exceeded its \(job.timeoutSeconds)s timeout.", summary: lastAssistantText, resolvedThreadId: resolvedThreadId, resolvedThreadPath: resolvedThreadPath)
            }

            guard let event = try await session.receiveNext(timeout: min(remaining, 5)) else { continue }
            let type = event["type"]?.stringValue

            // Tool-call arguments can surface on a streaming update or on `message_end` depending
            // on Pi's version, so every event carrying content is scanned rather than one kind.
            let specs = QuestionnaireSpecParser.specs(inAssistantContent: event["message"]?["content"])
            if !specs.isEmpty { questionSpecs = specs }

            if type == "extension_ui_request" {
                registerInteraction(event, session: session, job: job, threadID: job.target.existingThreadID ?? resolvedThreadId, specs: questionSpecs)
            }

            if type == "message_end", let message = event["message"], message["role"]?.stringValue == "assistant" {
                lastAssistantText = Self.firstLine(from: message["content"]) ?? lastAssistantText
                lastAssistantIsError = message["isError"]?.boolValue ?? (message["stopReason"]?.stringValue == "error")
            }
            if type == "agent_settled" {
                return RunOutcome(
                    status: lastAssistantIsError ? .failed : .ok,
                    error: lastAssistantIsError ? (lastAssistantText ?? "The run finished with an error.") : nil,
                    summary: lastAssistantText,
                    resolvedThreadId: resolvedThreadId,
                    resolvedThreadPath: resolvedThreadPath
                )
            }
        }
    }

    /// Only the four dialog methods the app itself treats as blocking are surfaced. `notify`,
    /// `setStatus`, `setWidget`, `setTitle` and friends expect no reply at all, so registering
    /// them would invent a dialog nobody can dismiss; an unrecognised method is left alone for
    /// exactly the same reason, matching `AppStore.handleExtensionUI`'s own `default: break`.
    private static let blockingDialogMethods: Set<String> = ["select", "confirm", "input", "editor"]

    private func registerInteraction(_ event: PiJSONValue, session: PiRPCSession, job: RunJob, threadID: String?, specs: [QuestionSpec]) {
        guard let id = event["id"]?.stringValue, !id.isEmpty,
              let method = event["method"]?.stringValue,
              Self.blockingDialogMethods.contains(method) else { return }

        let cancel: @Sendable () -> Void = {
            try? session.sendRaw([
                "type": .string("extension_ui_response"), "id": .string(id), "cancelled": .bool(true)
            ])
        }
        guard let interactions else { return cancel() }

        let title = event["title"]?.stringValue ?? "Pi"
        let spec = QuestionnaireSpecParser.match(specs, title: title, method: method)
        let rawOptions = Array((event["options"]?.arrayValue?.compactMap(\.stringValue) ?? []).prefix(100))
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
            try? session.sendRaw(response)
        }
        if !registered {
            // Pi is blocked on this request; refusing it explicitly is the only safe way to stay
            // within the bound.
            logger.warn("Interaction \(id) refused: too many dialogs are already pending.")
            cancel()
        }
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
