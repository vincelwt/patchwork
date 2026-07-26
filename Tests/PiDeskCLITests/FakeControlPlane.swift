import Foundation
@testable import PiDeskCLI

/// In-memory `ControlPlane` for command-level tests. Every method records its call and returns a
/// scripted result (or throws a scripted error), so no test in this target ever opens a socket or
/// talks to a real daemon — the hard rule the task calls for.
final class FakeControlPlane: ControlPlane, @unchecked Sendable {
    struct Call: Equatable {
        var method: String
        var detail: String
    }

    var calls: [Call] = []
    var error: Error?

    var healthResult = WireHealth(ok: true, version: "1.0.0", api: 1, startedAt: "2026-01-01T00:00:00Z", runningRuns: 0, queuedRuns: 0, piVersion: "0.82.1", schedulesEnabled: true)
    var threadListResult = WireThreadListResponse(threads: [], nextCursor: nil)
    var threadDetailResult = WireThreadDetailResponse(thread: WireThread(id: "t1"), messages: [])
    var createThreadResult = WireCreateThreadResponse(thread: WireThread(id: "t1"), runId: nil)
    var sendMessageResult = WireSendMessageResponse(runId: "run_1", queued: false)
    var abortResult = WireAbortResponse(aborted: true)
    var threadResponseResult = WireThreadResponse(thread: WireThread(id: "t1"))
    var scheduleListResult = WireScheduleListResponse(schedules: [])
    var scheduleCreateResult = WireScheduleResponse(schedule: WireSchedule(id: "sch_1"))
    var scheduleDetailResult = WireScheduleDetailResponse(schedule: WireSchedule(id: "sch_1"), runs: [])
    var scheduleDeleteResult = WireScheduleDeleteResponse(deleted: true)
    var scheduleRunResult = WireScheduleRunResponse(runId: "run_1")
    var limitsResult = WireLimits(report: .object(["accounts": .array([])]), generatedAt: "2026-01-01T00:00:00Z", stale: false)
    var eventsToEmit: [ControlPlaneEvent] = []
    var eventsError: Error?

    /// Captures every argument a command builds, for shape assertions independent of the fake's
    /// canned responses.
    var lastCreateThreadRequest: WireCreateThreadRequest?
    var lastSendMessageRequest: WireSendMessageRequest?
    var lastScheduleCreateRequest: WireScheduleCreateRequest?

    func health() async throws -> WireHealth {
        calls.append(Call(method: "health", detail: ""))
        if let error { throw error }
        return healthResult
    }

    func listThreads(query: String?, limit: Int, cursor: String?, archived: Bool?, running: Bool?) async throws -> WireThreadListResponse {
        calls.append(Call(method: "listThreads", detail: "query=\(query ?? "") limit=\(limit) cursor=\(cursor ?? "") archived=\(String(describing: archived)) running=\(String(describing: running))"))
        if let error { throw error }
        return threadListResult
    }

    func showThread(id: String, messages: Int) async throws -> WireThreadDetailResponse {
        calls.append(Call(method: "showThread", detail: "id=\(id) messages=\(messages)"))
        if let error { throw error }
        return threadDetailResult
    }

    func createThread(_ request: WireCreateThreadRequest) async throws -> WireCreateThreadResponse {
        calls.append(Call(method: "createThread", detail: "cwd=\(request.cwd) name=\(request.name ?? "") message=\(request.message ?? "") mode=\(request.mode ?? "")"))
        lastCreateThreadRequest = request
        if let error { throw error }
        return createThreadResult
    }

    func sendMessage(threadId: String, request: WireSendMessageRequest) async throws -> WireSendMessageResponse {
        calls.append(Call(method: "sendMessage", detail: "threadId=\(threadId) text=\(request.text) delivery=\(request.delivery)"))
        lastSendMessageRequest = request
        if let error { throw error }
        return sendMessageResult
    }

    func abortThread(id: String) async throws -> WireAbortResponse {
        calls.append(Call(method: "abortThread", detail: "id=\(id)"))
        if let error { throw error }
        return abortResult
    }

    func setArchived(id: String, archived: Bool) async throws -> WireThreadResponse {
        calls.append(Call(method: "setArchived", detail: "id=\(id) archived=\(archived)"))
        if let error { throw error }
        return threadResponseResult
    }

    func renameThread(id: String, name: String) async throws -> WireThreadResponse {
        calls.append(Call(method: "renameThread", detail: "id=\(id) name=\(name)"))
        if let error { throw error }
        return threadResponseResult
    }

    func listSchedules() async throws -> WireScheduleListResponse {
        calls.append(Call(method: "listSchedules", detail: ""))
        if let error { throw error }
        return scheduleListResult
    }

    func createSchedule(_ request: WireScheduleCreateRequest) async throws -> WireScheduleResponse {
        calls.append(Call(method: "createSchedule", detail: "name=\(request.name) trigger=\(request.trigger.kind) target=\(request.target.kind)"))
        lastScheduleCreateRequest = request
        if let error { throw error }
        return scheduleCreateResult
    }

    func showSchedule(id: String) async throws -> WireScheduleDetailResponse {
        calls.append(Call(method: "showSchedule", detail: "id=\(id)"))
        if let error { throw error }
        return scheduleDetailResult
    }

    func setSchedulePaused(id: String, paused: Bool) async throws -> WireScheduleResponse {
        calls.append(Call(method: "setSchedulePaused", detail: "id=\(id) paused=\(paused)"))
        if let error { throw error }
        return scheduleCreateResult
    }

    func deleteSchedule(id: String) async throws -> WireScheduleDeleteResponse {
        calls.append(Call(method: "deleteSchedule", detail: "id=\(id)"))
        if let error { throw error }
        return scheduleDeleteResult
    }

    func runSchedule(id: String) async throws -> WireScheduleRunResponse {
        calls.append(Call(method: "runSchedule", detail: "id=\(id)"))
        if let error { throw error }
        return scheduleRunResult
    }

    func limits() async throws -> WireLimits {
        calls.append(Call(method: "limits", detail: ""))
        if let error { throw error }
        return limitsResult
    }

    func events() -> AsyncThrowingStream<ControlPlaneEvent, Error> {
        calls.append(Call(method: "events", detail: ""))
        let events = eventsToEmit
        let streamError = eventsError
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let streamError {
                continuation.finish(throwing: streamError)
            } else {
                continuation.finish()
            }
        }
    }
}

struct FakeError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
