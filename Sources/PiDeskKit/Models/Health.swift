import Foundation

/// `GET /v1/health`. `issues` is additive (not in the literal example payload in
/// `docs/daemon-api.md`) and carries things like a quarantined schedule file — additive fields
/// never bump `api`, per the compatibility rules.
public struct HealthStatus: Codable, Hashable, Sendable {
    public var ok: Bool
    public var version: String
    public var api: Int
    public var startedAt: Date
    public var runningRuns: Int
    public var queuedRuns: Int
    public var piVersion: String?
    public var schedulesEnabled: Bool
    /// True when `POST /v1/schedules` honors `idempotencyKey`.
    public var scheduleIdempotency: Bool
    /// True when `POST /v1/threads` honors `clientId` for replay-safe creation.
    public var threadCreationIdempotency: Bool
    /// True when message submission honors `clientId` across daemon restarts.
    public var messageSubmissionIdempotency: Bool
    /// True when manual schedule runs honor `clientId` for replay-safe admission.
    public var scheduleRunIdempotency: Bool
    /// True when `POST /v1/threads` accepts `worktree:true`.
    public var threadWorktrees: Bool
    public var issues: [HealthIssue]

    public init(
        ok: Bool,
        version: String,
        api: Int = PiDeskAPI.apiVersion,
        startedAt: Date,
        runningRuns: Int,
        queuedRuns: Int,
        piVersion: String?,
        schedulesEnabled: Bool,
        scheduleIdempotency: Bool = true,
        threadCreationIdempotency: Bool = true,
        messageSubmissionIdempotency: Bool = true,
        scheduleRunIdempotency: Bool = true,
        threadWorktrees: Bool = true,
        issues: [HealthIssue] = []
    ) {
        self.ok = ok
        self.version = version
        self.api = api
        self.startedAt = startedAt
        self.runningRuns = runningRuns
        self.queuedRuns = queuedRuns
        self.piVersion = piVersion
        self.schedulesEnabled = schedulesEnabled
        self.scheduleIdempotency = scheduleIdempotency
        self.threadCreationIdempotency = threadCreationIdempotency
        self.messageSubmissionIdempotency = messageSubmissionIdempotency
        self.scheduleRunIdempotency = scheduleRunIdempotency
        self.threadWorktrees = threadWorktrees
        self.issues = issues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        api = try container.decodeIfPresent(Int.self, forKey: .api) ?? PiDeskAPI.apiVersion
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        runningRuns = try container.decodeIfPresent(Int.self, forKey: .runningRuns) ?? 0
        queuedRuns = try container.decodeIfPresent(Int.self, forKey: .queuedRuns) ?? 0
        piVersion = try container.decodeIfPresent(String.self, forKey: .piVersion)
        schedulesEnabled = try container.decodeIfPresent(Bool.self, forKey: .schedulesEnabled) ?? true
        scheduleIdempotency = try container.decodeIfPresent(Bool.self, forKey: .scheduleIdempotency) ?? false
        threadCreationIdempotency = try container.decodeIfPresent(Bool.self, forKey: .threadCreationIdempotency) ?? false
        messageSubmissionIdempotency = try container.decodeIfPresent(Bool.self, forKey: .messageSubmissionIdempotency) ?? false
        scheduleRunIdempotency = try container.decodeIfPresent(Bool.self, forKey: .scheduleRunIdempotency) ?? false
        threadWorktrees = try container.decodeIfPresent(Bool.self, forKey: .threadWorktrees) ?? false
        issues = try container.decodeIfPresent([HealthIssue].self, forKey: .issues) ?? []
    }
}

/// A non-fatal daemon-side problem surfaced instead of crashing or refusing to start, e.g. a
/// malformed `schedules.json` entry that was quarantined.
public struct HealthIssue: Codable, Hashable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
