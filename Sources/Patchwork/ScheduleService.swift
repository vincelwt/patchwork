import Foundation
import PatchworkKit

/// The app's view of the control plane. The window never talks to the daemon's socket directly:
/// everything goes through this seam, so the UI is testable without a daemon and degrades to a
/// clear "not running" state instead of failing.
///
/// The wire shapes are documented in `docs/daemon-api.md`. They are declared here rather than
/// imported from `PatchworkKit` while that module's public models are still landing; adopting them
/// later is a type-alias change, not a rewrite.
@MainActor
protocol ScheduleServing: AnyObject {
    func loadSchedules() async throws -> [ScheduleEntry]
    func save(_ schedule: ScheduleEntry, isNew: Bool) async throws -> ScheduleEntry
    func delete(id: String) async throws
    func setPaused(id: String, paused: Bool) async throws -> ScheduleEntry
    func runNow(id: String, clientID: String) async throws
    /// The daemon's retained execution records for one automation: status, timing, and a stored
    /// error or summary. Full output remains in the target conversation.
    func loadRuns(scheduleID: String) async throws -> [Run]
}

/// One scheduled automation. Mirrors `Schedule` in the API contract.
struct ScheduleEntry: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var name: String
    var enabled: Bool
    var target: Target
    var prompt: String
    var mode: String?
    /// Only new-conversation targets choose an agent. Nil preserves the historical Pi default.
    var agent: AgentKind?
    var trigger: Trigger
    var skipIfRunning: Bool
    var timeoutSeconds: Int?
    var lastRunAt: Date?
    var lastStatus: String?
    var nextRunAt: Date?

    enum Target: Hashable, Sendable, Codable {
        case existingThread(threadID: String)
        case newThread(cwd: String, namePattern: String?)
    }

    var isInternalPullRequestReviewWatch: Bool {
        id.hasPrefix("sch_req_pr_review_") && prompt.hasPrefix("/patchwork-pr-review ")
    }

    /// The four trigger kinds the contract defines. Anything Patchwork cannot express is
    /// rejected before it reaches the daemon, never silently dropped.
    enum Trigger: Hashable, Sendable, Codable {
        case once(at: Date)
        case interval(everySeconds: Int)
        case cron(expression: String, timeZone: String?)
        case heartbeat(everySeconds: Int)
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        enabled: Bool = true,
        target: Target,
        prompt: String,
        mode: String? = nil,
        agent: AgentKind? = nil,
        trigger: Trigger,
        skipIfRunning: Bool = true,
        timeoutSeconds: Int? = 3_600,
        lastRunAt: Date? = nil,
        lastStatus: String? = nil,
        nextRunAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.target = target
        self.prompt = prompt
        self.mode = mode
        self.agent = agent
        self.trigger = trigger
        self.skipIfRunning = skipIfRunning
        self.timeoutSeconds = timeoutSeconds
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.nextRunAt = nextRunAt
    }
}

/// Durable-before-send recovery for the two automation mutations whose outcome can be
/// ambiguous. The app owns this metadata; schedule and run truth still lives in the daemon.
struct ScheduleMutationIntent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case creation, manualRun }
    enum Phase: String, Codable, Sendable { case dispatching, retryable, needsReview }

    var kind: Kind
    var phase: Phase
    var clientID: String
    var scheduleID: String?
    var creationDraft: ScheduleEntry?
    var startedAt: Date

    static let creationKey = "creation"
    static let runPrefix = "run:"
    static let maximumRunCount = 32
    static let replayTTL: TimeInterval = 30 * 60
    static let maximumCreationBytes = 1_500_000

    static func runKey(_ scheduleID: String) -> String { runPrefix + scheduleID }

    func isValid(for key: String) -> Bool {
        let bytes = clientID.utf8
        let validID = (1...128).contains(bytes.count) && bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte)
                || (97...122).contains(byte) || byte == 45 || byte == 95
        }
        guard validID, startedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        switch kind {
        case .creation:
            guard key == Self.creationKey, scheduleID == nil,
                  let creationDraft, creationDraft.id == clientID,
                  let encoded = try? JSONEncoder().encode(creationDraft),
                  encoded.count <= Self.maximumCreationBytes else { return false }
        case .manualRun:
            guard let scheduleID, !scheduleID.isEmpty,
                  scheduleID.utf8.count <= 256,
                  key == Self.runKey(scheduleID), creationDraft == nil else { return false }
        }
        return true
    }

    static func boundedDecoded(_ raw: [String: ScheduleMutationIntent]) -> [String: ScheduleMutationIntent] {
        let valid = raw.filter { $0.value.isValid(for: $0.key) }
        var result: [String: ScheduleMutationIntent] = [:]
        if let creation = valid[creationKey] { result[creationKey] = creation }
        for pair in valid
            .filter({ $0.value.kind == .manualRun })
            .sorted(by: { $0.value.startedAt < $1.value.startedAt })
            .suffix(maximumRunCount) {
            result[pair.key] = pair.value
        }
        return result
    }

    static func isWithinNormalBounds(_ values: [String: ScheduleMutationIntent]) -> Bool {
        values.count <= maximumRunCount + 1
            && values.filter { $0.value.kind == .creation }.count <= 1
            && values.filter { $0.value.kind == .manualRun }.count <= maximumRunCount
            && values.allSatisfy { $0.value.isValid(for: $0.key) }
    }
}

@MainActor
protocol ScheduleMutationIntentPersisting: AnyObject {
    var scheduleMutationIntents: [String: ScheduleMutationIntent] { get }
    @discardableResult
    func replaceScheduleMutationIntents(_ values: [String: ScheduleMutationIntent]) -> Bool
}

/// Pure validation shared by the editor and its tests, so a schedule that cannot fire is
/// impossible to save rather than merely discouraged.
enum ScheduleValidation {
    static func problem(with entry: ScheduleEntry, now: Date = Date()) -> String? {
        if entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the automation a name." }
        if entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write the prompt Pi should run." }
        switch entry.target {
        case let .existingThread(threadID) where threadID.isEmpty:
            return "Choose the conversation to run in."
        case let .newThread(cwd, _) where cwd.isEmpty:
            return "Choose the folder for the new conversation."
        default:
            break
        }
        if case .newThread = entry.target,
           (entry.agent ?? .pi) != .pi,
           entry.mode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "Modes are only available for Pi automations."
        }
        switch entry.trigger {
        case let .once(at) where at <= now:
            return "Pick a time in the future."
        case let .interval(seconds) where seconds < 60:
            return "Repeat at most once a minute."
        case let .heartbeat(seconds) where seconds < 60:
            return "Check at most once a minute."
        case let .cron(expression, _) where CronExpressionCheck.problem(with: expression) != nil:
            return CronExpressionCheck.problem(with: expression)
        default:
            break
        }
        return nil
    }
}

/// A shape check only: the daemon owns real cron evaluation. This exists so the editor can
/// reject an obviously broken expression while the user is still looking at it.
enum CronExpressionCheck {
    static func problem(with expression: String) -> String? {
        let fields = expression.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 5 else { return "A cron expression has five fields, like 0 9 * * 1-5." }
        for field in fields where !isPlausible(String(field)) {
            return "“\(field)” is not a valid cron field."
        }
        return nil
    }

    private static func isPlausible(_ field: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789*,-/").union(.letters)
        return !field.isEmpty && field.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// Human wording for a trigger, used in the list and in accessibility labels.
extension ScheduleEntry.Trigger {
    var summary: String {
        switch self {
        case let .once(at):
            "Once, \(at.formatted(date: .abbreviated, time: .shortened))"
        case let .interval(seconds):
            "Every \(NumberFormatting.duration(TimeInterval(seconds)))"
        case let .cron(expression, _):
            "Cron · \(expression)"
        case let .heartbeat(seconds):
            "Every \(NumberFormatting.duration(TimeInterval(seconds))) when idle"
        }
    }
}

/// Used until the daemon client lands, and in every test: schedules live in memory and nothing
/// ever runs. The UI is identical either way.
@MainActor
final class InMemoryScheduleService: ScheduleServing {
    private(set) var entries: [ScheduleEntry]
    var runs: [Run]
    var failure: Error?
    private(set) var runClientIDs: [String] = []
    private(set) var savedIDs: [String] = []
    private(set) var loadCount = 0
    var runHandler: ((String, String) async throws -> Void)?
    var loadHandler: (() async throws -> [ScheduleEntry])?
    var saveHandler: ((ScheduleEntry, Bool) async throws -> ScheduleEntry)?
    var runsHandler: ((String) async throws -> [Run])?

    init(entries: [ScheduleEntry] = [], runs: [Run] = []) {
        self.entries = entries
        self.runs = runs
    }

    func loadSchedules() async throws -> [ScheduleEntry] {
        loadCount += 1
        if let loadHandler { return try await loadHandler() }
        if let failure { throw failure }
        return entries
    }

    func save(_ schedule: ScheduleEntry, isNew: Bool) async throws -> ScheduleEntry {
        savedIDs.append(schedule.id)
        if let saveHandler { return try await saveHandler(schedule, isNew) }
        if let failure { throw failure }
        if isNew {
            if let index = entries.firstIndex(where: { $0.id == schedule.id }) {
                entries[index] = schedule
            } else {
                entries.append(schedule)
            }
        } else {
            guard let index = entries.firstIndex(where: { $0.id == schedule.id }) else {
                throw ScheduleServiceError.notFound
            }
            entries[index] = schedule
        }
        return schedule
    }

    func delete(id: String) async throws {
        if let failure { throw failure }
        entries.removeAll { $0.id == id }
    }

    func setPaused(id: String, paused: Bool) async throws -> ScheduleEntry {
        if let failure { throw failure }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw ScheduleServiceError.notFound }
        entries[index].enabled = !paused
        return entries[index]
    }

    func runNow(id: String, clientID: String) async throws {
        runClientIDs.append(clientID)
        if let runHandler { return try await runHandler(id, clientID) }
        if let failure { throw failure }
        guard entries.contains(where: { $0.id == id }) else { throw ScheduleServiceError.notFound }
    }

    func loadRuns(scheduleID: String) async throws -> [Run] {
        if let runsHandler { return try await runsHandler(scheduleID) }
        if let failure { throw failure }
        return runs.filter { $0.scheduleId == scheduleID }
    }
}

enum ScheduleServiceError: LocalizedError {
    case notFound
    case daemonUnavailable
    case outcomeUnknown
    case creationOutcomeUnknown
    case recoveryStorageUnavailable
    case mutationAlreadyInFlight

    var errorDescription: String? {
        switch self {
        case .notFound: "That automation no longer exists."
        case .daemonUnavailable:
            "Patchwork’s control service is still starting or unavailable."
        case .outcomeUnknown:
            "The run result could not be confirmed. Review run history before starting another run."
        case .creationOutcomeUnknown:
            "The automation creation result could not be confirmed. Review the automation list before creating another one."
        case .recoveryStorageUnavailable:
            "The automation request could not be saved safely, so it was not sent."
        case .mutationAlreadyInFlight:
            "That automation request is already being submitted."
        }
    }
}

@MainActor
extension AppStore {
    /// The control-plane client the automations panel uses. Schedules live in the daemon, so
    /// the window, `patchwork`, and the web remote all see the same automations.
    var scheduleService: any ScheduleServing {
        if let existing = cachedScheduleService { return existing }
        let service = DaemonScheduleService()
        cachedScheduleService = service
        return service
    }
}
