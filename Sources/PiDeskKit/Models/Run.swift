import Foundation

/// `queued|running|ok|failed|skipped|timeout|interrupted`. Also reused for
/// `Schedule.lastStatus` — one enum, no duplicated tolerant-decode boilerplate.
public struct RunStatus: TolerantRawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let queued = RunStatus(rawValue: "queued")
    public static let running = RunStatus(rawValue: "running")
    public static let ok = RunStatus(rawValue: "ok")
    public static let failed = RunStatus(rawValue: "failed")
    public static let skipped = RunStatus(rawValue: "skipped")
    public static let timeout = RunStatus(rawValue: "timeout")
    public static let interrupted = RunStatus(rawValue: "interrupted")

    public static var knownCases: [RunStatus] { [.queued, .running, .ok, .failed, .skipped, .timeout, .interrupted] }
    public static func other(_ rawValue: String) -> RunStatus { RunStatus(rawValue: rawValue) }
}

/// `schedule|manual|api` — what caused a run to start.
public struct RunTrigger: TolerantRawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let schedule = RunTrigger(rawValue: "schedule")
    public static let manual = RunTrigger(rawValue: "manual")
    public static let api = RunTrigger(rawValue: "api")

    public static var knownCases: [RunTrigger] { [.schedule, .manual, .api] }
    public static func other(_ rawValue: String) -> RunTrigger { RunTrigger(rawValue: rawValue) }
}

/// One execution record, as appended to `runs.jsonl` and returned by `/v1/runs`.
public struct Run: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var scheduleId: String?
    public var threadId: String?
    /// Physical transcript identity. Absent on records written before path-scoped routing.
    public var threadPath: String?
    public var trigger: RunTrigger
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: RunStatus
    public var error: String?
    public var summary: String?
    public var occurrenceId: String?
    public var scheduledAt: Date?
    public var attempt: Int?
    public var nextAttemptAt: Date?
    public var promptStartedAt: Date?
    public var promptAcceptedAt: Date?
    public var retryable: Bool?
    /// Which agent executed the run. Absent on every record written before multi-agent support.
    public var agent: AgentKind?

    public init(
        id: String,
        scheduleId: String? = nil,
        threadId: String? = nil,
        threadPath: String? = nil,
        trigger: RunTrigger,
        startedAt: Date,
        finishedAt: Date? = nil,
        status: RunStatus,
        error: String? = nil,
        summary: String? = nil,
        occurrenceId: String? = nil,
        scheduledAt: Date? = nil,
        attempt: Int? = nil,
        nextAttemptAt: Date? = nil,
        promptStartedAt: Date? = nil,
        promptAcceptedAt: Date? = nil,
        retryable: Bool? = nil,
        agent: AgentKind? = nil
    ) {
        self.id = id
        self.scheduleId = scheduleId
        self.threadId = threadId
        self.threadPath = threadPath
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.error = error
        self.summary = summary
        self.occurrenceId = occurrenceId
        self.scheduledAt = scheduledAt
        self.attempt = attempt
        self.nextAttemptAt = nextAttemptAt
        self.promptStartedAt = promptStartedAt
        self.promptAcceptedAt = promptAcceptedAt
        self.retryable = retryable
        self.agent = agent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        scheduleId = try container.decodeIfPresent(String.self, forKey: .scheduleId)
        threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
        threadPath = try container.decodeIfPresent(String.self, forKey: .threadPath)
        trigger = try container.decodeIfPresent(RunTrigger.self, forKey: .trigger) ?? .other("unknown")
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? .distantPast
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        status = try container.decodeIfPresent(RunStatus.self, forKey: .status) ?? .other("unknown")
        error = try container.decodeIfPresent(String.self, forKey: .error)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        occurrenceId = try container.decodeIfPresent(String.self, forKey: .occurrenceId)
        scheduledAt = try container.decodeIfPresent(Date.self, forKey: .scheduledAt)
        attempt = try container.decodeIfPresent(Int.self, forKey: .attempt)
        nextAttemptAt = try container.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
        promptStartedAt = try container.decodeIfPresent(Date.self, forKey: .promptStartedAt)
        promptAcceptedAt = try container.decodeIfPresent(Date.self, forKey: .promptAcceptedAt)
        retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable)
        agent = try container.decodeIfPresent(AgentKind.self, forKey: .agent)
    }
}

public struct RunListResponse: Codable, Sendable {
    public var runs: [Run]
    public init(runs: [Run]) { self.runs = runs }
}

public struct RunResponse: Codable, Sendable {
    public var run: Run
    public init(run: Run) { self.run = run }
}
