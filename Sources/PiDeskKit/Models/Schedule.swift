import Foundation

/// `{"from":"23:00","to":"07:00","timeZone":"Europe/Paris"}`. `from`/`to` are wall-clock
/// `HH:mm`; a window where `to` < `from` wraps past midnight, which is the normal case
/// ("no runs overnight").
public struct QuietHours: Codable, Hashable, Sendable {
    public var from: String
    public var to: String
    public var timeZone: String

    public init(from: String, to: String, timeZone: String) {
        self.from = from
        self.to = to
        self.timeZone = timeZone
    }
}

/// `{"kind":"existingThread","threadId":"…"}` or `{"kind":"newThread","cwd":"…","namePattern":"…"}`.
/// The agent lives on `Schedule.agent`, not here: an `existingThread` target already resolves to
/// a thread that knows its own agent, and only a `newThread` target has to remember one.
/// `.other` preserves an unrecognised kind (from a newer daemon/CLI) instead of failing decode;
/// the daemon rejects it at creation time the same way it rejects an unparseable cron expression.
public enum ScheduleTarget: Hashable, Sendable {
    case existingThread(threadId: String)
    case newThread(cwd: String, namePattern: String?)
    case other(kind: String)

    public var kind: String {
        switch self {
        case .existingThread: "existingThread"
        case .newThread: "newThread"
        case let .other(kind): kind
        }
    }

    /// The thread identity to key per-thread exclusivity on. A `newThread` target has none yet
    /// — each fire creates a brand-new thread, so it can never collide with anything.
    public var existingThreadID: String? {
        if case let .existingThread(threadId) = self { return threadId }
        return nil
    }
}

extension ScheduleTarget: Codable {
    private enum CodingKeys: String, CodingKey { case kind, threadId, cwd, namePattern }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        switch kind {
        case "existingThread":
            self = .existingThread(threadId: try container.decodeIfPresent(String.self, forKey: .threadId) ?? "")
        case "newThread":
            self = .newThread(
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd) ?? "",
                namePattern: try container.decodeIfPresent(String.self, forKey: .namePattern)
            )
        default:
            self = .other(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case let .existingThread(threadId):
            try container.encode(threadId, forKey: .threadId)
        case let .newThread(cwd, namePattern):
            try container.encode(cwd, forKey: .cwd)
            try container.encodeIfPresent(namePattern, forKey: .namePattern)
        case .other:
            break
        }
    }
}

/// The four trigger kinds from `docs/daemon-api.md`. `.other` is the forward-compat escape
/// hatch for a trigger kind this build predates; `TriggerEngine` refuses to compute a
/// `nextRunAt` for it and the create/update handlers reject it outright with a clear error,
/// matching the doc's "anything unparseable is rejected at creation time" rule for cron.
public enum ScheduleTrigger: Hashable, Sendable {
    case once(at: Date)
    case interval(everySeconds: Int, startAt: Date?)
    case cron(expression: String, timeZone: String?)
    case heartbeat(everySeconds: Int)
    case other(kind: String)

    public var kind: String {
        switch self {
        case .once: "once"
        case .interval: "interval"
        case .cron: "cron"
        case .heartbeat: "heartbeat"
        case let .other(kind): kind
        }
    }
}

extension ScheduleTrigger: Codable {
    private enum CodingKeys: String, CodingKey { case kind, at, everySeconds, startAt, expression, timeZone }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        switch kind {
        case "once":
            self = .once(at: try container.decodeIfPresent(Date.self, forKey: .at) ?? .distantFuture)
        case "interval":
            self = .interval(
                everySeconds: try container.decodeIfPresent(Int.self, forKey: .everySeconds) ?? 0,
                startAt: try container.decodeIfPresent(Date.self, forKey: .startAt)
            )
        case "cron":
            self = .cron(
                expression: try container.decodeIfPresent(String.self, forKey: .expression) ?? "",
                timeZone: try container.decodeIfPresent(String.self, forKey: .timeZone)
            )
        case "heartbeat":
            self = .heartbeat(everySeconds: try container.decodeIfPresent(Int.self, forKey: .everySeconds) ?? 0)
        default:
            self = .other(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case let .once(at):
            try container.encode(at, forKey: .at)
        case let .interval(everySeconds, startAt):
            try container.encode(everySeconds, forKey: .everySeconds)
            try container.encodeIfPresent(startAt, forKey: .startAt)
        case let .cron(expression, timeZone):
            try container.encode(expression, forKey: .expression)
            try container.encodeIfPresent(timeZone, forKey: .timeZone)
        case let .heartbeat(everySeconds):
            try container.encode(everySeconds, forKey: .everySeconds)
        case .other:
            break
        }
    }
}

/// One globally resilient scheduled occurrence. Presence means the work is still owed; there can
/// never be more than one per schedule, so a long time away coalesces instead of building a burst.
public struct ScheduleOccurrence: Codable, Hashable, Sendable {
    public struct Phase: TolerantRawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let pending = Phase(rawValue: "pending")
        public static let dispatching = Phase(rawValue: "dispatching")
        public static let accepted = Phase(rawValue: "accepted")
        public static var knownCases: [Phase] { [.pending, .dispatching, .accepted] }
        public static func other(_ rawValue: String) -> Phase { Phase(rawValue: rawValue) }
    }

    public var id: String
    public var scheduledAt: Date
    public var phase: Phase
    public var attemptCount: Int
    public var notBefore: Date
    public var runId: String?

    public init(
        id: String, scheduledAt: Date, phase: Phase = .pending,
        attemptCount: Int = 0, notBefore: Date, runId: String? = nil
    ) {
        self.id = id
        self.scheduledAt = scheduledAt
        self.phase = phase
        self.attemptCount = attemptCount
        self.notBefore = notBefore
        self.runId = runId
    }
}

public struct SchedulePolicy: Codable, Hashable, Sendable {
    public var skipIfRunning: Bool
    /// Retained for API compatibility. The scheduler now catches up globally and ignores this.
    public var catchUpMissed: Bool
    public var timeoutSeconds: Int?
    public var quietHours: QuietHours?

    public init(skipIfRunning: Bool = true, catchUpMissed: Bool = false, timeoutSeconds: Int? = nil, quietHours: QuietHours? = nil) {
        self.skipIfRunning = skipIfRunning
        self.catchUpMissed = catchUpMissed
        self.timeoutSeconds = timeoutSeconds
        self.quietHours = quietHours
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skipIfRunning = try container.decodeIfPresent(Bool.self, forKey: .skipIfRunning) ?? true
        catchUpMissed = try container.decodeIfPresent(Bool.self, forKey: .catchUpMissed) ?? false
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        quietHours = try container.decodeIfPresent(QuietHours.self, forKey: .quietHours)
    }
}

public struct Schedule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var target: ScheduleTarget
    public var prompt: String
    public var mode: String?
    public var trigger: ScheduleTrigger
    public var policy: SchedulePolicy
    /// Which agent this schedule runs. Absent in every pre-multi-agent `schedules.json`, which
    /// means Pi.
    public var agent: AgentKind?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastRunAt: Date?
    public var lastStatus: RunStatus?
    public var nextRunAt: Date?
    /// Durable work owed by this schedule. Optional so every pre-resilience schedules.json still
    /// decodes unchanged.
    public var pendingOccurrence: ScheduleOccurrence?

    public init(
        id: String,
        name: String,
        enabled: Bool = true,
        target: ScheduleTarget,
        prompt: String,
        mode: String? = nil,
        trigger: ScheduleTrigger,
        policy: SchedulePolicy = SchedulePolicy(),
        agent: AgentKind? = nil,
        createdAt: Date,
        updatedAt: Date,
        lastRunAt: Date? = nil,
        lastStatus: RunStatus? = nil,
        nextRunAt: Date? = nil,
        pendingOccurrence: ScheduleOccurrence? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.target = target
        self.prompt = prompt
        self.mode = mode
        self.trigger = trigger
        self.policy = policy
        self.agent = agent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.nextRunAt = nextRunAt
        self.pendingOccurrence = pendingOccurrence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled schedule"
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        target = try container.decode(ScheduleTarget.self, forKey: .target)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        trigger = try container.decode(ScheduleTrigger.self, forKey: .trigger)
        policy = try container.decodeIfPresent(SchedulePolicy.self, forKey: .policy) ?? SchedulePolicy()
        agent = try container.decodeIfPresent(AgentKind.self, forKey: .agent)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastStatus = try container.decodeIfPresent(RunStatus.self, forKey: .lastStatus)
        nextRunAt = try container.decodeIfPresent(Date.self, forKey: .nextRunAt)
        pendingOccurrence = try container.decodeIfPresent(ScheduleOccurrence.self, forKey: .pendingOccurrence)
    }
}

// MARK: - Request/response wrappers

public struct ScheduleCreateRequest: Codable, Sendable {
    /// Optional stable key for callers that may retry after an unconfirmed response.
    public var idempotencyKey: String?
    public var name: String
    public var enabled: Bool?
    public var target: ScheduleTarget
    public var prompt: String
    public var mode: String?
    public var trigger: ScheduleTrigger
    public var policy: SchedulePolicy?
    public var agent: AgentKind?

    public init(
        idempotencyKey: String? = nil,
        name: String,
        enabled: Bool? = nil,
        target: ScheduleTarget,
        prompt: String,
        mode: String? = nil,
        trigger: ScheduleTrigger,
        policy: SchedulePolicy? = nil,
        agent: AgentKind? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.name = name
        self.enabled = enabled
        self.target = target
        self.prompt = prompt
        self.mode = mode
        self.trigger = trigger
        self.policy = policy
        self.agent = agent
    }
}

/// Every field optional: only the fields present are changed. There is deliberately no way to
/// distinguish "omitted" from "explicitly clear this optional field" (e.g. `mode`); the daemon
/// treats an absent key as "leave unchanged", so clearing `mode` needs an empty string today.
public struct ScheduleUpdateRequest: Codable, Sendable {
    public var name: String?
    public var enabled: Bool?
    public var target: ScheduleTarget?
    public var prompt: String?
    public var mode: String?
    public var trigger: ScheduleTrigger?
    public var policy: SchedulePolicy?

    public init(
        name: String? = nil,
        enabled: Bool? = nil,
        target: ScheduleTarget? = nil,
        prompt: String? = nil,
        mode: String? = nil,
        trigger: ScheduleTrigger? = nil,
        policy: SchedulePolicy? = nil
    ) {
        self.name = name
        self.enabled = enabled
        self.target = target
        self.prompt = prompt
        self.mode = mode
        self.trigger = trigger
        self.policy = policy
    }
}

public struct ScheduleResponse: Codable, Sendable {
    public var schedule: Schedule
    public init(schedule: Schedule) { self.schedule = schedule }
}

public struct ScheduleListResponse: Codable, Sendable {
    public var schedules: [Schedule]
    public init(schedules: [Schedule]) { self.schedules = schedules }
}

public struct ScheduleDetailResponse: Codable, Sendable {
    public var schedule: Schedule
    public var runs: [Run]
    public init(schedule: Schedule, runs: [Run]) {
        self.schedule = schedule
        self.runs = runs
    }
}

public struct ScheduleRunResponse: Codable, Sendable {
    public var runId: String
    public init(runId: String) { self.runId = runId }
}

public struct SchedulePauseRequest: Codable, Sendable {
    public var paused: Bool
    public init(paused: Bool) { self.paused = paused }
}

public struct DeletedResponse: Codable, Sendable {
    public var deleted: Bool
    public init(deleted: Bool) { self.deleted = deleted }
}
