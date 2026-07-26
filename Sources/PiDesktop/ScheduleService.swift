import Foundation
import PiDeskKit

/// The app's view of the control plane. The window never talks to the daemon's socket directly:
/// everything goes through this seam, so the UI is testable without a daemon and degrades to a
/// clear "not running" state instead of failing.
///
/// The wire shapes are documented in `docs/daemon-api.md`. They are declared here rather than
/// imported from `PiDeskKit` while that module's public models are still landing; adopting them
/// later is a type-alias change, not a rewrite.
@MainActor
protocol ScheduleServing: AnyObject {
    func loadSchedules() async throws -> [ScheduleEntry]
    func save(_ schedule: ScheduleEntry) async throws -> ScheduleEntry
    func delete(id: String) async throws
    func setPaused(id: String, paused: Bool) async throws -> ScheduleEntry
    func runNow(id: String) async throws
}

/// One scheduled automation. Mirrors `Schedule` in the API contract.
struct ScheduleEntry: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var name: String
    var enabled: Bool
    var target: Target
    var prompt: String
    var mode: String?
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

    /// The four trigger kinds the contract defines. Anything Pi Desktop cannot express is
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
        self.trigger = trigger
        self.skipIfRunning = skipIfRunning
        self.timeoutSeconds = timeoutSeconds
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.nextRunAt = nextRunAt
    }
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
    var failure: Error?

    init(entries: [ScheduleEntry] = []) { self.entries = entries }

    func loadSchedules() async throws -> [ScheduleEntry] {
        if let failure { throw failure }
        return entries
    }

    func save(_ schedule: ScheduleEntry) async throws -> ScheduleEntry {
        if let failure { throw failure }
        if let index = entries.firstIndex(where: { $0.id == schedule.id }) { entries[index] = schedule }
        else { entries.append(schedule) }
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

    func runNow(id: String) async throws {
        if let failure { throw failure }
        guard entries.contains(where: { $0.id == id }) else { throw ScheduleServiceError.notFound }
    }
}

enum ScheduleServiceError: LocalizedError {
    case notFound
    case daemonUnavailable

    var errorDescription: String? {
        switch self {
        case .notFound: "That automation no longer exists."
        case .daemonUnavailable:
            // Honest about *why* rather than a single generic sentence: a user who turned the
            // service off in Settings needs a different next step than one whose daemon just
            // hasn't started yet or crashed — see DaemonSupervisor.swift.
            DaemonSupervisorSettings.autoManageEnabled()
                ? "The Pi Desktop background service is not running."
                : "The Pi Desktop background service is turned off. Turn it on in Settings to use automations."
        }
    }
}

@MainActor
extension AppStore {
    /// The control-plane client the automations panel uses. Schedules live in the daemon, so
    /// the window, `pidesk`, and the web remote all see the same automations.
    var scheduleService: any ScheduleServing {
        if let existing = cachedScheduleService { return existing }
        let service = DaemonScheduleService()
        cachedScheduleService = service
        return service
    }
}
