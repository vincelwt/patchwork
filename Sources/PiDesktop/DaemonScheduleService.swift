import Foundation
import PiDeskKit

/// The automations panel talking to the real control plane over the daemon's Unix socket.
/// Everything the window can do here, `pidesk` and the web remote can do too, because all three
/// go through the same API.
@MainActor
final class DaemonScheduleService: ScheduleServing {
    private let client: PiDeskClient

    init(client: PiDeskClient = .unixSocket()) { self.client = client }

    func loadSchedules() async throws -> [ScheduleEntry] {
        do {
            return try await client.listSchedules().schedules.map(ScheduleEntry.init(wire:))
        } catch {
            throw Self.surfaced(error)
        }
    }

    func save(_ schedule: ScheduleEntry) async throws -> ScheduleEntry {
        do {
            // A schedule the daemon has never seen is created; anything else is patched, so an
            // edit never resurrects a deleted automation under a stale id.
            let known = try await client.listSchedules().schedules.contains { $0.id == schedule.id }
            let wire = known
                ? try await client.updateSchedule(id: schedule.id, schedule.updateRequest).schedule
                : try await client.createSchedule(schedule.createRequest).schedule
            return ScheduleEntry(wire: wire)
        } catch {
            throw Self.surfaced(error)
        }
    }

    func delete(id: String) async throws {
        do {
            _ = try await client.deleteSchedule(id: id)
        } catch {
            throw Self.surfaced(error)
        }
    }

    func setPaused(id: String, paused: Bool) async throws -> ScheduleEntry {
        do {
            return ScheduleEntry(wire: try await client.pauseSchedule(id: id, paused: paused).schedule)
        } catch {
            throw Self.surfaced(error)
        }
    }

    func runNow(id: String) async throws {
        do {
            _ = try await client.runSchedule(id: id)
        } catch {
            throw Self.surfaced(error)
        }
    }

    /// A missing daemon is the common case on a fresh install, so it gets a sentence a person
    /// can act on instead of a socket error.
    private static func surfaced(_ error: Error) -> Error {
        if case PiDeskClientError.daemonUnreachable = error { return ScheduleServiceError.daemonUnavailable }
        return error
    }
}

extension ScheduleEntry {
    init(wire: Schedule) {
        self.init(
            id: wire.id,
            name: wire.name,
            enabled: wire.enabled,
            target: Target(wire: wire.target),
            prompt: wire.prompt,
            mode: wire.mode,
            trigger: Trigger(wire: wire.trigger),
            skipIfRunning: wire.policy.skipIfRunning,
            timeoutSeconds: wire.policy.timeoutSeconds,
            lastRunAt: wire.lastRunAt,
            lastStatus: wire.lastStatus?.rawValue,
            nextRunAt: wire.nextRunAt
        )
    }

    var createRequest: ScheduleCreateRequest {
        ScheduleCreateRequest(
            name: name,
            enabled: enabled,
            target: target.wire,
            prompt: prompt,
            mode: mode,
            trigger: trigger.wire,
            policy: SchedulePolicy(skipIfRunning: skipIfRunning, timeoutSeconds: timeoutSeconds)
        )
    }

    var updateRequest: ScheduleUpdateRequest {
        ScheduleUpdateRequest(
            name: name,
            enabled: enabled,
            target: target.wire,
            prompt: prompt,
            mode: mode,
            trigger: trigger.wire,
            policy: SchedulePolicy(skipIfRunning: skipIfRunning, timeoutSeconds: timeoutSeconds)
        )
    }
}

extension ScheduleEntry.Target {
    init(wire: ScheduleTarget) {
        switch wire {
        case let .existingThread(threadId): self = .existingThread(threadID: threadId)
        case let .newThread(cwd, namePattern): self = .newThread(cwd: cwd, namePattern: namePattern)
        // A target kind this build does not know still round-trips as an existing thread with an
        // empty id, which the editor rejects rather than silently rewriting.
        case .other: self = .existingThread(threadID: "")
        }
    }

    var wire: ScheduleTarget {
        switch self {
        case let .existingThread(threadID): .existingThread(threadId: threadID)
        case let .newThread(cwd, namePattern): .newThread(cwd: cwd, namePattern: namePattern)
        }
    }
}

extension ScheduleEntry.Trigger {
    init(wire: ScheduleTrigger) {
        switch wire {
        case let .once(at): self = .once(at: at)
        case let .interval(everySeconds, _): self = .interval(everySeconds: everySeconds)
        case let .cron(expression, timeZone): self = .cron(expression: expression, timeZone: timeZone)
        case let .heartbeat(everySeconds): self = .heartbeat(everySeconds: everySeconds)
        case .other: self = .interval(everySeconds: 3_600)
        }
    }

    var wire: ScheduleTrigger {
        switch self {
        case let .once(at): .once(at: at)
        case let .interval(everySeconds): .interval(everySeconds: everySeconds, startAt: nil)
        case let .cron(expression, timeZone): .cron(expression: expression, timeZone: timeZone)
        case let .heartbeat(everySeconds): .heartbeat(everySeconds: everySeconds)
        }
    }
}
