import Foundation

/// `running|ok|failed|skipped|timeout`. Also reused for `Schedule.lastStatus`, whose doc'd range
/// (`ok|failed|skipped`) is a subset — one enum, no duplicated tolerant-decode boilerplate.
public struct RunStatus: TolerantRawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let running = RunStatus(rawValue: "running")
    public static let ok = RunStatus(rawValue: "ok")
    public static let failed = RunStatus(rawValue: "failed")
    public static let skipped = RunStatus(rawValue: "skipped")
    public static let timeout = RunStatus(rawValue: "timeout")

    public static var knownCases: [RunStatus] { [.running, .ok, .failed, .skipped, .timeout] }
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
    public var trigger: RunTrigger
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: RunStatus
    public var error: String?
    public var summary: String?

    public init(
        id: String,
        scheduleId: String? = nil,
        threadId: String? = nil,
        trigger: RunTrigger,
        startedAt: Date,
        finishedAt: Date? = nil,
        status: RunStatus,
        error: String? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.scheduleId = scheduleId
        self.threadId = threadId
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.error = error
        self.summary = summary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        scheduleId = try container.decodeIfPresent(String.self, forKey: .scheduleId)
        threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
        trigger = try container.decodeIfPresent(RunTrigger.self, forKey: .trigger) ?? .other("unknown")
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? .distantPast
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        status = try container.decodeIfPresent(RunStatus.self, forKey: .status) ?? .other("unknown")
        error = try container.decodeIfPresent(String.self, forKey: .error)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
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
