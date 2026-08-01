import Foundation
import PiDeskKit

enum ScheduleHandlers {
    static func routes(_ core: DaemonCore) -> [Route] {
        [
            Route("GET", "/v1/schedules") { _, _ in
                .json(ScheduleListResponse(schedules: await core.scheduleStore.all()))
            },

            Route("POST", "/v1/schedules") { request, _ in
                let requestedAgent = try request.decodeKnownAgent()
                let body = try request.decodeJSON(ScheduleCreateRequest.self)
                let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw DaemonHTTPError.badRequest(code: "invalid_name", message: "name must not be empty.") }
                try validateBytes(name, field: "name", maximum: 256)
                let prompt = body.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prompt.isEmpty else { throw DaemonHTTPError.badRequest(code: "invalid_prompt", message: "prompt must not be empty.") }
                try validateBytes(prompt, field: "prompt", maximum: RunQueue.defaultMaxPromptBytes)
                let mode = try boundedMode(body.mode)
                try validate(body.trigger)
                if let policy = body.policy { try validate(policy) }

                let enabled = body.enabled ?? true
                let policy = body.policy ?? SchedulePolicy()
                let id: String
                let isIdempotentCreate: Bool
                if let key = body.idempotencyKey {
                    guard (16...64).contains(key.count), key.unicodeScalars.allSatisfy({ scalar in
                        (48...57).contains(scalar.value) || (65...90).contains(scalar.value)
                            || (97...122).contains(scalar.value) || scalar.value == 45 || scalar.value == 95
                    }) else {
                        throw DaemonHTTPError.badRequest(
                            code: "invalid_idempotency_key",
                            message: "idempotencyKey must be 16-64 letters, numbers, dashes, or underscores."
                        )
                    }
                    id = "sch_req_\(key)"
                    isIdempotentCreate = true
                } else {
                    id = "sch_\(UUID().uuidString)"
                    isIdempotentCreate = false
                }
                let requestTargetFingerprint = isIdempotentCreate
                    ? creationTargetFingerprint(body.target)
                    : nil

                // A completed replay must win before canonical thread lookup or installed-agent
                // checks. Both are mutable machine state and can change after the first create.
                if isIdempotentCreate,
                   let existing = await core.scheduleStore.get(id: id) {
                    guard matchesCreateRequestIgnoringTarget(
                        existing, name: name, enabled: enabled, prompt: prompt, mode: mode,
                        trigger: body.trigger, policy: policy, agent: requestedAgent
                    ) else {
                        throw DaemonHTTPError.badRequest(
                            code: "idempotency_conflict",
                            message: "idempotencyKey was already used for a different schedule."
                        )
                    }
                    if existing.target == body.target
                        || requestTargetFingerprint.map({
                            existing.creationTargetFingerprint == $0
                        }) == true {
                        return .json(ScheduleResponse(schedule: existing))
                    }
                    // Only an alternate spelling of the same target needs canonical lookup. Any
                    // other changed target is a definite reuse of the key for new work.
                }

                let target = try await canonicalTarget(body.target, core: core)
                try validate(target)
                try await validateAgentAndMode(
                    target: target, requestedAgent: requestedAgent, mode: mode, core: core
                )

                let now = Date()
                let nextRunAt = await core.scheduler.computeInitialNextRunAt(for: body.trigger)
                let schedule = Schedule(
                    id: id, name: name, enabled: enabled,
                    target: target, prompt: prompt, mode: mode, trigger: body.trigger,
                    policy: policy, agent: requestedAgent, createdAt: now, updatedAt: now,
                    nextRunAt: nextRunAt,
                    creationTargetFingerprint: requestTargetFingerprint
                )
                let saved: Schedule
                if isIdempotentCreate {
                    switch try await core.scheduleStore.insertIfAbsent(schedule) {
                    case let .inserted(inserted):
                        saved = inserted
                    case let .existing(existing):
                        guard matchesCreateRequestIgnoringTarget(
                            existing, name: name, enabled: enabled, prompt: prompt, mode: mode,
                            trigger: body.trigger, policy: policy, agent: requestedAgent
                        ), existing.target == target || requestTargetFingerprint.map({
                            existing.creationTargetFingerprint == $0
                        }) == true else {
                            throw DaemonHTTPError.badRequest(
                                code: "idempotency_conflict",
                                message: "idempotencyKey was already used for a different schedule."
                            )
                        }
                        let replay = await backfillCreationTargetFingerprint(
                            existing, fingerprint: requestTargetFingerprint, core: core
                        )
                        return .json(ScheduleResponse(schedule: replay))
                    }
                } else {
                    saved = try await core.scheduleStore.upsert(schedule)
                }
                core.bus.publish(.schedule(saved))
                return .json(ScheduleResponse(schedule: saved), status: 201)
            },

            Route("GET", "/v1/schedules/:id") { _, params in
                let schedule = try await requireSchedule(core, params)
                let runs = await core.runHistoryStore.query(scheduleId: schedule.id, threadId: nil, limit: 50)
                return .json(ScheduleDetailResponse(schedule: schedule, runs: runs))
            },

            Route("PATCH", "/v1/schedules/:id") { request, params in
                guard let id = params["id"], !id.isEmpty else {
                    throw DaemonHTTPError.badRequest(code: "missing_id", message: "Missing schedule id.")
                }
                let requestedAgent = try request.decodeKnownAgent()
                let agentWasSupplied = request.containsJSONField("agent")
                let body = try request.decodeJSON(ScheduleUpdateRequest.self)
                let cleanName = body.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let cleanName, cleanName.isEmpty {
                    throw DaemonHTTPError.badRequest(code: "invalid_name", message: "name must not be empty.")
                }
                if let cleanName { try validateBytes(cleanName, field: "name", maximum: 256) }
                let cleanPrompt = body.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let cleanPrompt, cleanPrompt.isEmpty {
                    throw DaemonHTTPError.badRequest(code: "invalid_prompt", message: "prompt must not be empty.")
                }
                if let cleanPrompt {
                    try validateBytes(cleanPrompt, field: "prompt", maximum: RunQueue.defaultMaxPromptBytes)
                }
                let cleanMode = try boundedMode(body.mode)
                let target: ScheduleTarget?
                if let requestedTarget = body.target {
                    target = try await canonicalTarget(requestedTarget, core: core)
                } else {
                    target = nil
                }
                if let target { try validate(target) }
                if let trigger = body.trigger { try validate(trigger) }
                if let policy = body.policy { try validate(policy) }
                let nextRunAt = if let trigger = body.trigger {
                    await core.scheduler.computeInitialNextRunAt(for: trigger)
                } else {
                    nil as Date?
                }
                let now = Date()
                let invalidatesCreationFingerprint = cleanName != nil
                    || body.enabled != nil || target != nil || cleanPrompt != nil
                    || body.mode != nil || body.trigger != nil || body.policy != nil
                    || agentWasSupplied

                var saved: Schedule?
                for _ in 0..<3 {
                    guard let current = await core.scheduleStore.get(id: id) else {
                        throw DaemonHTTPError.notFound("Schedule \(id)")
                    }
                    let effectiveTarget = target ?? current.target
                    let effectiveMode = body.mode != nil ? cleanMode : current.mode
                    let effectiveAgent: AgentKind? = if case .newThread = effectiveTarget {
                        if agentWasSupplied {
                            requestedAgent
                        } else if case .newThread = current.target {
                            current.agent
                        } else {
                            nil
                        }
                    } else {
                        nil
                    }
                    if case .existingThread = effectiveTarget, agentWasSupplied {
                        throw DaemonHTTPError.badRequest(
                            code: "agent_not_supported",
                            message: "agent only applies to a newThread schedule target."
                        )
                    }
                    let targetChanged = target.map { $0 != current.target } ?? false
                    let agentChanged = agentWasSupplied
                        && (effectiveAgent ?? .pi) != (current.agent ?? .pi)
                    if current.pendingOccurrence != nil, targetChanged || agentChanged {
                        throw DaemonHTTPError.conflict(
                            code: "schedule_occurrence_in_flight",
                            message: "Wait for the pending automation run to finish before changing its target or agent."
                        )
                    }
                    try await validateAgentAndMode(
                        target: effectiveTarget,
                        requestedAgent: effectiveAgent,
                        mode: effectiveMode,
                        core: core
                    )

                    saved = try await core.scheduleStore.update(
                        id: id, matching: current
                    ) { updated in
                        if let cleanName { updated.name = cleanName }
                        if let enabled = body.enabled { updated.enabled = enabled }
                        if let target { updated.target = target }
                        if agentWasSupplied || target != nil { updated.agent = effectiveAgent }
                        if let cleanPrompt { updated.prompt = cleanPrompt }
                        if body.mode != nil { updated.mode = cleanMode }
                        if let trigger = body.trigger {
                            updated.trigger = trigger
                            updated.nextRunAt = nextRunAt
                        }
                        if let policy = body.policy { updated.policy = policy }
                        if invalidatesCreationFingerprint {
                            updated.creationTargetFingerprint = nil
                        }
                        updated.updatedAt = now
                    }
                    if saved != nil { break }
                }
                guard let saved else {
                    guard await core.scheduleStore.get(id: id) != nil else {
                        throw DaemonHTTPError.notFound("Schedule \(id)")
                    }
                    throw DaemonHTTPError.conflict(
                        code: "schedule_changed",
                        message: "The automation changed while this edit was being saved. Try again."
                    )
                }
                core.bus.publish(.schedule(saved))
                return .json(ScheduleResponse(schedule: saved))
            },

            Route("DELETE", "/v1/schedules/:id") { _, params in
                guard let id = params["id"] else { throw DaemonHTTPError.badRequest(code: "missing_id", message: "Missing schedule id.") }
                guard try await core.scheduleStore.remove(id: id) else { throw DaemonHTTPError.notFound("Schedule \(id)") }
                // A deleted schedule has no `Schedule` value left to publish. Keep the deletion
                // signal additive and forward-compatible so older clients ignore it while newer
                // clients can remove the row immediately instead of waiting for a reconnect.
                core.bus.publish(.unknown(
                    name: "schedule_deleted",
                    data: .object(["id": .string(id)])
                ))
                return .json(DeletedResponse(deleted: true))
            },

            Route("POST", "/v1/schedules/:id/run") { request, params in
                guard let id = params["id"] else { throw DaemonHTTPError.badRequest(code: "missing_id", message: "Missing schedule id.") }
                let body = request.body.isEmpty
                    ? ScheduleRunRequest()
                    : try request.decodeJSON(ScheduleRunRequest.self)
                let clientID = try validatedClientID(body.clientId)
                var ownership: SubmissionRegistry.Ownership?
                if let clientID {
                    switch await core.submissions.claimScheduleRun(
                        scheduleID: id, clientID: clientID
                    ) {
                    case let .replay(response):
                        return .json(response)
                    case .inFlight:
                        if let response = await core.submissions.waitForScheduleRun(
                            scheduleID: id, clientID: clientID
                        ) {
                            return .json(response)
                        }
                        throw DaemonHTTPError.conflict(
                            code: "schedule_run_in_flight",
                            message: "This manual schedule run is already being started."
                        )
                    case .outcomeUnknown:
                        throw DaemonHTTPError.conflict(
                            code: "schedule_run_outcome_unknown",
                            message: "The run may have started before the service restarted. Review this schedule's run history before retrying."
                        )
                    case .conflict:
                        throw DaemonHTTPError.conflict(
                            code: "run_id_conflict",
                            message: "This clientId already belongs to different work."
                        )
                    case .overloaded:
                        throw DaemonHTTPError.serviceUnavailable(
                            code: "submissions_busy",
                            message: "The protected replay ledger is full. Retry after an older entry expires."
                        )
                    case let .unavailable(message):
                        throw DaemonHTTPError.serviceUnavailable(
                            code: "submission_ledger_unavailable", message: message
                        )
                    case let .proceed(owner):
                        ownership = owner
                    }
                }
                do {
                    let response = ScheduleRunResponse(
                        runId: try await core.scheduler.runNow(scheduleId: id)
                    )
                    if let clientID, let ownership {
                        await core.submissions.completeScheduleRun(
                            scheduleID: id, clientID: clientID,
                            ownership: ownership, response: response
                        )
                    }
                    return .json(response)
                } catch {
                    if let clientID, let ownership {
                        await core.submissions.abandonScheduleRun(
                            scheduleID: id, clientID: clientID, ownership: ownership
                        )
                    }
                    throw error
                }
            },

            Route("POST", "/v1/schedules/:id/pause") { request, params in
                guard let id = params["id"], !id.isEmpty else {
                    throw DaemonHTTPError.badRequest(code: "missing_id", message: "Missing schedule id.")
                }
                let body = try request.decodeJSON(SchedulePauseRequest.self)
                let now = Date()
                guard let saved = try await core.scheduleStore.update(id: id, { updated in
                    updated.enabled = !body.paused
                    updated.creationTargetFingerprint = nil
                    updated.updatedAt = now
                    return true
                }) else { throw DaemonHTTPError.notFound("Schedule \(id)") }
                core.bus.publish(.schedule(saved))
                return .json(ScheduleResponse(schedule: saved))
            }
        ]
    }

    private static func creationTargetFingerprint(_ target: ScheduleTarget) -> String {
        let parts: [String]
        switch target {
        case let .existingThread(threadID):
            parts = ["schedule-create-target-v1", "existingThread", threadID]
        case let .newThread(cwd, namePattern):
            parts = [
                "schedule-create-target-v1", "newThread", cwd,
                namePattern == nil ? "nil" : "value", namePattern ?? ""
            ]
        case let .other(kind):
            parts = ["schedule-create-target-v1", "other", kind]
        }
        return "v1:\(SubmissionRegistry.fingerprint(parts: parts))"
    }

    private static func backfillCreationTargetFingerprint(
        _ existing: Schedule,
        fingerprint: String?,
        core: DaemonCore
    ) async -> Schedule {
        guard existing.creationTargetFingerprint == nil, let fingerprint else { return existing }
        do {
            return try await core.scheduleStore.update(
                id: existing.id, matching: existing
            ) { updated in
                updated.creationTargetFingerprint = fingerprint
            } ?? existing
        } catch {
            core.logger.warn("Could not save schedule create replay metadata: \(error)")
            return existing
        }
    }

    private static func matchesCreateRequestIgnoringTarget(
        _ existing: Schedule,
        name: String,
        enabled: Bool,
        prompt: String,
        mode: String?,
        trigger: ScheduleTrigger,
        policy: SchedulePolicy,
        agent: AgentKind?
    ) -> Bool {
        existing.name == name && existing.enabled == enabled
            && existing.prompt == prompt && existing.mode == mode
            && existing.trigger == trigger && existing.policy == policy
            && existing.agent == agent
    }

    private static func validateBytes(_ value: String, field: String, maximum: Int) throws {
        guard value.lengthOfBytes(using: .utf8) <= maximum else {
            throw DaemonHTTPError.payloadTooLarge(
                code: "\(field)_too_large",
                message: "\(field) exceeds the \(maximum)-byte limit."
            )
        }
    }

    private static func validatedClientID(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let bytes = raw.utf8
        let allowed = bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte)
                || (97...122).contains(byte) || byte == 45 || byte == 95
        }
        guard (1...128).contains(bytes.count), allowed else {
            throw DaemonHTTPError.badRequest(
                code: "invalid_client_id",
                message: "clientId must be 1-128 letters, numbers, dashes, or underscores."
            )
        }
        return raw
    }

    private static func boundedMode(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        try validateBytes(value, field: "mode", maximum: 256)
        return value
    }

    private static func requireSchedule(_ core: DaemonCore, _ params: [String: String]) async throws -> Schedule {
        guard let id = params["id"], !id.isEmpty else {
            throw DaemonHTTPError.badRequest(code: "missing_id", message: "Missing schedule id.")
        }
        guard let schedule = await core.scheduleStore.get(id: id) else {
            throw DaemonHTTPError.notFound("Schedule \(id)")
        }
        return schedule
    }

    private static func canonicalTarget(_ target: ScheduleTarget, core: DaemonCore) async throws -> ScheduleTarget {
        guard case let .existingThread(threadID) = target else { return target }
        guard let thread = try await core.threadStore.resolveForMutation(idOrPath: threadID) else {
            return target
        }
        // Schedules persist a session id, not a path. Re-resolving the canonical id rejects
        // copied histories instead of accepting a target that later cannot run safely.
        guard try await core.threadStore.resolveForMutation(idOrPath: thread.id) != nil else {
            return target
        }
        return .existingThread(threadId: thread.id)
    }

    /// Anything unparseable or unrecognised is rejected here at creation/update time, never
    /// silently stored as a schedule that can never fire.
    private static func validate(_ target: ScheduleTarget) throws {
        switch target {
        case let .existingThread(threadId):
            guard !threadId.isEmpty else { throw DaemonHTTPError.badRequest(code: "invalid_target", message: "target.threadId must not be empty.") }
        case let .newThread(cwd, namePattern):
            guard !cwd.isEmpty else { throw DaemonHTTPError.badRequest(code: "invalid_target", message: "target.cwd must not be empty.") }
            if let namePattern {
                try validateBytes(
                    namePattern, field: "target.namePattern",
                    maximum: ThreadCreationService.initialNameByteLimit
                )
            }
        case let .other(kind):
            throw DaemonHTTPError.badRequest(code: "invalid_target", message: "Unknown target kind \"\(kind)\".")
        }
    }

    private static func validateAgentAndMode(
        target: ScheduleTarget,
        requestedAgent: AgentKind?,
        mode: String?,
        core: DaemonCore
    ) async throws {
        switch target {
        case .newThread:
            if mode != nil, (requestedAgent ?? .pi) != .pi {
                throw DaemonHTTPError.badRequest(
                    code: "mode_not_supported",
                    message: "The mode field is only supported for Pi schedules."
                )
            }
        case let .existingThread(threadID):
            if requestedAgent != nil {
                throw DaemonHTTPError.badRequest(
                    code: "agent_not_supported",
                    message: "agent only applies to a newThread schedule target."
                )
            }
            guard mode != nil else { return }
            guard let thread = try await core.threadStore.resolveForMutation(idOrPath: threadID) else {
                throw DaemonHTTPError.notFound("Thread \(threadID)")
            }
            if thread.agent != .pi {
                throw DaemonHTTPError.badRequest(
                    code: "mode_not_supported",
                    message: "The mode field is only supported for Pi schedules."
                )
            }
        case .other:
            return
        }
    }

    private static func validate(_ trigger: ScheduleTrigger) throws {
        switch trigger {
        case .once:
            return
        case let .interval(everySeconds, _):
            guard everySeconds > 0 else { throw DaemonHTTPError.badRequest(code: "invalid_trigger", message: "interval.everySeconds must be positive.") }
        case let .cron(expression, timeZone):
            do { _ = try CronExpression(parsing: expression) }
            catch { throw DaemonHTTPError.badRequest(code: "invalid_cron", message: "\(error)") }
            if let timeZone, TimeZone(identifier: timeZone) == nil {
                throw DaemonHTTPError.badRequest(code: "invalid_timezone", message: "\"\(timeZone)\" is not a known time zone identifier.")
            }
        case let .heartbeat(everySeconds):
            guard everySeconds > 0 else { throw DaemonHTTPError.badRequest(code: "invalid_trigger", message: "heartbeat.everySeconds must be positive.") }
        case let .other(kind):
            throw DaemonHTTPError.badRequest(code: "invalid_trigger", message: "Unknown trigger kind \"\(kind)\".")
        }
    }

    private static func validate(_ quietHours: QuietHours) throws {
        guard TimeZone(identifier: quietHours.timeZone) != nil else {
            throw DaemonHTTPError.badRequest(code: "invalid_timezone", message: "\"\(quietHours.timeZone)\" is not a known time zone identifier.")
        }
        func minutes(_ text: String) throws -> Int {
            let parts = text.split(separator: ":")
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0...23).contains(hour), (0...59).contains(minute) else {
                throw DaemonHTTPError.badRequest(code: "invalid_quiet_hours", message: "quietHours times must be \"HH:mm\"; got \"\(text)\".")
            }
            return hour * 60 + minute
        }
        _ = try minutes(quietHours.from)
        _ = try minutes(quietHours.to)
    }

    private static func validate(_ policy: SchedulePolicy) throws {
        if let seconds = policy.timeoutSeconds,
           !(1...ScheduleEngine.maximumTimeoutSeconds).contains(seconds) {
            throw DaemonHTTPError.badRequest(
                code: "invalid_timeout",
                message: "policy.timeoutSeconds must be between 1 and \(ScheduleEngine.maximumTimeoutSeconds)."
            )
        }
        if let quietHours = policy.quietHours { try validate(quietHours) }
    }
}
