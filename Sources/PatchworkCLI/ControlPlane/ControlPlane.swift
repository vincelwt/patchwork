import Foundation

/// One SSE message from `/v1/events`, decoded just enough to route it: `name` is the `event:`
/// line ("thread"/"activity"/"run"/"schedule", or anything a newer daemon adds), `data` is the
/// parsed `data:` JSON. Consumers must tolerate unknown `name` values (docs/daemon-api.md,
/// "Compatibility rules").
struct ControlPlaneEvent: Equatable {
    var name: String
    var data: JSONValue
}

/// Everything a command needs from the daemon, and nothing about *how* it talks to it. This is
/// the seam the task calls for: `HTTPControlPlane` is today's standalone implementation (hand
/// -rolled HTTP over UDS/TCP, see RawHTTPClient.swift); tests use `FakeControlPlane`. See the
/// bottom of this file for exactly what changes when `PatchworkKit.PatchworkClient` lands.
protocol ControlPlane: Sendable {
    func health() async throws -> WireHealth

    func listThreads(query: String?, limit: Int, cursor: String?, archived: Bool?, running: Bool?, automated: Bool?, agent: String?) async throws -> WireThreadListResponse
    func showThread(id: String, messages: Int, offset: Int, includeTools: Bool) async throws -> WireThreadDetailResponse
    func createThread(_ request: WireCreateThreadRequest) async throws -> WireCreateThreadResponse
    func sendMessage(threadId: String, request: WireSendMessageRequest) async throws -> WireSendMessageResponse
    func abortThread(id: String) async throws -> WireAbortResponse
    func setArchived(id: String, archived: Bool) async throws -> WireThreadResponse
    func renameThread(id: String, name: String) async throws -> WireThreadResponse

    func listSchedules() async throws -> WireScheduleListResponse
    func createSchedule(_ request: WireScheduleCreateRequest) async throws -> WireScheduleResponse
    func showSchedule(id: String) async throws -> WireScheduleDetailResponse
    func setSchedulePaused(id: String, paused: Bool) async throws -> WireScheduleResponse
    func deleteSchedule(id: String) async throws -> WireScheduleDeleteResponse
    func runSchedule(id: String, request: WireScheduleRunRequest) async throws -> WireScheduleRunResponse
    func showRun(id: String) async throws -> WireRunResponse

    func limits() async throws -> WireLimits

    /// Long-lived; ends only when the connection drops or the caller cancels the consuming task.
    func events() -> AsyncThrowingStream<ControlPlaneEvent, Error>
}

/// Transport/protocol-level failure. Reachability (`.unreachable`) is kept distinct from every
/// other failure because it alone maps to exit code 3 (docs/daemon-api.md, "CLI surface").
enum ControlPlaneError: Error {
    case unreachable(String)
    case timedOut(String)
    case apiError(status: Int, code: String, message: String)
    case malformedResponse(String)
    case transportFailure(String)
    /// The mutation was attempted once, but this daemon did not advertise replay protection.
    case outcomeUnknown(String)
}

/*
 Adopting PatchworkKit.PatchworkClient once it lands:

 1. Delete Models/WireModels.swift and re-point every `Wire*` type alias at PatchworkKit's
    equivalents (Thread, Message, Schedule, Trigger, Run, Activity, LimitsReport, ErrorEnvelope) —
    field names were modeled directly from docs/daemon-api.md so they should already line up.
 2. Delete RawHTTPClient.swift/RawSocketTransport.swift and replace HTTPControlPlane's guts with
    calls into PatchworkKit.PatchworkClient, keeping this same `ControlPlane` protocol and the same
    method signatures so Commands/ and Tests/ don't change at all.
 3. Drop the transport-only tests (RawHTTPClientTests) — PatchworkKit owns that layer's coverage now.
 Everything else (argument parsing, JSON output shape, exit-code mapping) is unaffected because it
 only ever talks to `ControlPlane`.
 */
