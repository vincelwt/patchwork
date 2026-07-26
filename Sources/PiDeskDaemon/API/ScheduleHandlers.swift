import Foundation
import PiDeskKit

enum ScheduleHandlers {
    static func routes(_ core: DaemonCore) -> [Route] {
        [
            Route("GET", "/v1/schedules") { _, _ in
                .json(ScheduleListResponse(schedules: await core.scheduleStore.all()))
            },

            Route("POST", "/v1/schedules") { request, _ in
                let body = try request.decodeJSON(ScheduleCreateRequest.self)
                let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw DaemonHTTPError.badRequest(code: "invalid_name", message: "name must not be empty.") }
                let prompt = body.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prompt.isEmpty else { throw DaemonHTTPError.badRequest(code: "invalid_prompt", message: "prompt must not be empty.") }
                try validate(body.target)
                try validate(body.trigger)
                if let quietHours = body.policy?.quietHours { try validate(quietHours) }

                let now = Date()
                let nextRunAt = await core.scheduler.computeInitialNextRunAt(for: body.trigger)
                let schedule = Schedule(
                    id: "sch_\(UUID().uuidString)", name: name, enabled: body.enabled ?? true,
                    target: body.target, prompt: prompt, mode: body.mode, trigger: body.trigger,
                    policy: body.policy ?? SchedulePolicy(), createdAt: now, updatedAt: now, nextRunAt: nextRunAt
                )
                let saved = try await core.scheduleStore.upsert(schedule)
                core.bus.publish(.schedule(saved))
                return .json(ScheduleResponse(schedule: saved), status: 201)
            },

            Route("GET", "/v1/schedules/:id") { _, params in
                let schedule = try await requireSchedule(core, params)
                let runs = await core.runHistoryStore.query(scheduleId: schedule.id, threadId: nil, limit: 50)
                return .json(ScheduleDetailResponse(schedule: schedule, runs: runs))
            },

            Route("PATCH", "/v1/schedules/:id") { request, params in
                let existing = try await requireSchedule(core, params)
                let body = try request.decodeJSON(ScheduleUpdateRequest.self)
                var updated = existing

                if let name = body.name {
                    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { throw DaemonHTTPError.badRequest(code: "invalid_name", message: "name must not be empty.") }
                    updated.name = clean
                }
                if let enabled = body.enabled { updated.enabled = enabled }
                if let target = body.target { try validate(target); updated.target = target }
                if let prompt = body.prompt {
                    let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { throw DaemonHTTPError.badRequest(code: "invalid_prompt", message: "prompt must not be empty.") }
                    updated.prompt = clean
                }
                if let mode = body.mode { updated.mode = mode }
                var triggerChanged = false
                if let trigger = body.trigger {
                    try validate(trigger)
                    updated.trigger = trigger
                    triggerChanged = true
                }
                if let policy = body.policy {
                    if let quietHours = policy.quietHours { try validate(quietHours) }
                    updated.policy = policy
                }
                if triggerChanged {
                    updated.nextRunAt = await core.scheduler.computeInitialNextRunAt(for: updated.trigger)
                }
                updated.updatedAt = Date()

                let saved = try await core.scheduleStore.upsert(updated)
                core.bus.publish(.schedule(saved))
                return .json(ScheduleResponse(schedule: saved))
            },

            Route("DELETE", "/v1/schedules/:id") { _, params in
                guard let id = params["id"] else { throw DaemonHTTPError.badRequest(code: "missing_id", message: "Missing schedule id.") }
                guard try await core.scheduleStore.remove(id: id) else { throw DaemonHTTPError.notFound("Schedule \(id)") }
                return .json(DeletedResponse(deleted: true))
            },

            Route("POST", "/v1/schedules/:id/run") { _, params in
                guard let id = params["id"] else { throw DaemonHTTPError.badRequest(code: "missing_id", message: "Missing schedule id.") }
                let runId = try await core.scheduler.runNow(scheduleId: id)
                return .json(ScheduleRunResponse(runId: runId))
            },

            Route("POST", "/v1/schedules/:id/pause") { request, params in
                let existing = try await requireSchedule(core, params)
                let body = try request.decodeJSON(SchedulePauseRequest.self)
                var updated = existing
                updated.enabled = !body.paused
                updated.updatedAt = Date()
                let saved = try await core.scheduleStore.upsert(updated)
                core.bus.publish(.schedule(saved))
                return .json(ScheduleResponse(schedule: saved))
            }
        ]
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

    /// Anything unparseable/unrecognised is rejected here, at creation/update time, with a
    /// clear error \u2014 never silently stored as a schedule that can never fire.
    private static func validate(_ target: ScheduleTarget) throws {
        switch target {
        case let .existingThread(threadId):
            guard !threadId.isEmpty else { throw DaemonHTTPError.badRequest(code: "invalid_target", message: "target.threadId must not be empty.") }
        case let .newThread(cwd, _):
            guard !cwd.isEmpty else { throw DaemonHTTPError.badRequest(code: "invalid_target", message: "target.cwd must not be empty.") }
        case let .other(kind):
            throw DaemonHTTPError.badRequest(code: "invalid_target", message: "Unknown target kind \"\(kind)\".")
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
}
