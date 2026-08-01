import Foundation

// Mirrors docs/daemon-api.md exactly: field names match the wire JSON so Codable needs no custom
// CodingKeys. These are a stand-in for the `Thread`/`Schedule`/`Run`/... models PatchworkKit will
// eventually export — see ControlPlane.swift for the swap-over plan.
//
// Timestamps stay `String` (raw passthrough) rather than `Date`: the exact server format isn't
// pinned down by the doc, and a strict Date decode would make the whole object fail to parse over
// a timestamp we don't even need to compute with. `FlexibleDate.displayLocal` does a best-effort
// parse for human output and falls back to the raw string.

struct WireThread: Codable, Equatable {
    var id: String
    var path: String?
    var name: String?
    var cwd: String?
    var folder: String?
    var createdAt: String?
    var updatedAt: String?
    var running: Bool?
    var unread: Bool?
    var archived: Bool?
    var preview: String?
    /// `pi|codex|claude`. Kept a raw `String` like every other tolerant field here: an agent a
    /// newer daemon knows about must show up in the table, not fail the whole list decode.
    var agent: String? = nil
    var cost: Double?
    var contextPercent: Double?
    var shortId: String? = nil
    var automated: Bool? = nil
    var project: String? = nil
    var worktree: String? = nil
}

struct WireMessage: Codable, Equatable {
    var id: String?
    var role: String?
    var text: String?
    var at: String?
    var isError: Bool?
}

struct WireThreadListResponse: Codable, Equatable {
    var threads: [WireThread]
    var nextCursor: String?
}

struct WireThreadDetailResponse: Codable, Equatable {
    var thread: WireThread
    var messages: [WireMessage]
    var nextOffset: Int? = nil
}

struct WireCreateThreadRequest: Codable {
    var cwd: String
    var name: String?
    var message: String?
    var mode: String?
    var worktree: Bool? = nil
    var agent: String? = nil
    var clientId: String? = nil
}

struct WireCreateThreadResponse: Codable, Equatable {
    var thread: WireThread
    var runId: String?
    var firstMessageError: String? = nil
}

struct WireSendMessageRequest: Codable {
    var text: String
    var delivery: String
    var attachments: [String]
    var clientId: String? = nil
}

struct WireSendMessageResponse: Codable, Equatable {
    var runId: String
    var queued: Bool = false
    var delivery: String? = nil
}

struct WireAbortResponse: Codable, Equatable {
    var aborted: Bool
}

struct WireThreadResponse: Codable, Equatable {
    var thread: WireThread
}

struct WireTrigger: Codable, Equatable {
    var kind: String
    var at: String?
    var everySeconds: Int?
    var startAt: String?
    var expression: String?
    var timeZone: String?
}

struct WireScheduleTarget: Codable, Equatable {
    var kind: String
    var threadId: String?
    var cwd: String?
    var namePattern: String?
}

struct WireQuietHours: Codable, Equatable {
    var from: String
    var to: String
    var timeZone: String?
}

struct WireSchedulePolicy: Codable, Equatable {
    var skipIfRunning: Bool?
    var catchUpMissed: Bool?
    var timeoutSeconds: Int?
    var quietHours: WireQuietHours?
}

struct WireSchedule: Codable, Equatable {
    var id: String
    var name: String?
    var enabled: Bool?
    var target: WireScheduleTarget?
    var prompt: String?
    var mode: String?
    var trigger: WireTrigger?
    var policy: WireSchedulePolicy?
    var agent: String? = nil
    var createdAt: String?
    var updatedAt: String?
    var lastRunAt: String?
    var lastStatus: String?
    var nextRunAt: String?
}

struct WireScheduleCreateRequest: Codable {
    var idempotencyKey: String? = nil
    var name: String
    var enabled: Bool?
    var target: WireScheduleTarget
    var prompt: String
    var mode: String?
    var trigger: WireTrigger
    var policy: WireSchedulePolicy?
    /// Only meaningful for a `--cwd` target: an existing thread already knows its own agent, and
    /// the scheduler reads it from the thread at every fire rather than from here.
    var agent: String? = nil
}

struct WireScheduleListResponse: Codable, Equatable {
    var schedules: [WireSchedule]
}

struct WireScheduleResponse: Codable, Equatable {
    var schedule: WireSchedule
}

struct WireScheduleDetailResponse: Codable, Equatable {
    var schedule: WireSchedule
    var runs: [WireRun]
}

struct WireScheduleDeleteResponse: Codable, Equatable {
    var deleted: Bool
}

struct WireScheduleRunResponse: Codable, Equatable {
    var runId: String
}

struct WireScheduleRunRequest: Codable, Equatable {
    var clientId: String? = nil
}

struct WireRun: Codable, Equatable {
    var id: String
    var scheduleId: String?
    var threadId: String?
    var threadPath: String?
    var trigger: String?
    var startedAt: String?
    var finishedAt: String?
    var status: String?
    var error: String?
    var summary: String?
    var promptStartedAt: String?
    var promptAcceptedAt: String?
    var retryable: Bool?
    var occurrenceId: String? = nil
    var scheduledAt: String? = nil
    var attempt: Int? = nil
    var nextAttemptAt: String? = nil
    var agent: String? = nil
}

struct WireRunResponse: Codable, Equatable {
    var run: WireRun
}

struct WireHealth: Codable, Equatable {
    var ok: Bool
    var version: String?
    var api: Int?
    var startedAt: String?
    var runningRuns: Int?
    var queuedRuns: Int?
    var piVersion: String?
    var schedulesEnabled: Bool?
    var scheduleIdempotency: Bool? = nil
    var threadCreationIdempotency: Bool? = nil
    var messageSubmissionIdempotency: Bool? = nil
    var scheduleRunIdempotency: Bool? = nil
    var threadWorktrees: Bool? = nil
}

struct WireLimits: Codable, Equatable {
    var report: JSONValue
    var generatedAt: String?
    var stale: Bool?
}

struct WireErrorDetail: Codable, Equatable {
    var code: String
    var message: String
}

struct WireErrorEnvelope: Codable, Equatable {
    var error: WireErrorDetail
}

/// Terminal run statuses per the doc's Run schema; used to decide `threads send --wait`'s exit
/// code. Anything not "ok" (including statuses this CLI doesn't know about yet) counts as
/// non-success rather than being assumed fine.
enum RunStatus {
    static let terminal: Set<String> = ["ok", "failed", "skipped", "timeout", "interrupted"]
    static func isSuccess(_ status: String?) -> Bool { status == "ok" }
    static func isTerminal(_ status: String?) -> Bool { status.map(terminal.contains) ?? false }
}
