import Foundation

/// Shared human-table rendering for wire models, used by both `threads` and `schedule`. Every
/// free-text column is truncated so one huge name/prompt/preview can't blow up terminal output.
enum Rendering {
    static let previewWidth = 120
    static let nameWidth = 32
    static let locationWidth = 48

    /// Older daemons do not accept abbreviations, so only use the compact id they advertise.
    static func threadID(_ thread: WireThread) -> String {
        thread.shortId ?? thread.id
    }

    static func threadStatus(_ thread: WireThread, colorEnabled: Bool) -> String {
        var parts: [String] = []
        if thread.running == true { parts.append(colorize("running", ANSI.green, enabled: colorEnabled)) }
        if thread.archived == true { parts.append(colorize("archived", ANSI.dim, enabled: colorEnabled)) }
        if thread.unread == true { parts.append(colorize("unread", ANSI.yellow, enabled: colorEnabled)) }
        if thread.automated == true { parts.append("automated") }
        return parts.isEmpty ? "-" : parts.joined(separator: ",")
    }

    static func threadRow(_ thread: WireThread, colorEnabled: Bool) -> [String] {
        let location: String
        if let worktree = thread.worktree {
            let project = thread.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? thread.folder ?? "-"
            location = "\(project) [wt:\(URL(fileURLWithPath: worktree).lastPathComponent)]"
        } else {
            location = thread.folder ?? "-"
        }
        return [
            threadID(thread),
            truncated(thread.name ?? "(unnamed)", max: nameWidth),
            truncated(location, max: locationWidth),
            threadStatus(thread, colorEnabled: colorEnabled),
            FlexibleDate.displayLocal(thread.updatedAt),
            truncated(thread.preview ?? "", max: previewWidth)
        ]
    }

    static func scheduleStatus(_ schedule: WireSchedule, colorEnabled: Bool) -> String {
        let enabled = schedule.enabled ?? true
        if !enabled { return colorize("paused", ANSI.dim, enabled: colorEnabled) }
        switch schedule.lastStatus {
        case "failed", "timeout", "interrupted": return colorize("enabled (last failed)", ANSI.red, enabled: colorEnabled)
        default: return colorize("enabled", ANSI.green, enabled: colorEnabled)
        }
    }

    static func triggerSummary(_ trigger: WireTrigger?) -> String {
        guard let trigger else { return "-" }
        switch trigger.kind {
        case "once": return "once at \(FlexibleDate.displayLocal(trigger.at))"
        case "interval": return "every \(formatDuration(Double(trigger.everySeconds ?? 0)))"
        case "cron": return "cron \"\(trigger.expression ?? "")\" (\(trigger.timeZone ?? "local"))"
        case "heartbeat": return "heartbeat every \(formatDuration(Double(trigger.everySeconds ?? 0)))"
        default: return trigger.kind
        }
    }

    static func scheduleRow(_ schedule: WireSchedule, colorEnabled: Bool) -> [String] {
        [
            schedule.id,
            truncated(schedule.name ?? "(unnamed)", max: nameWidth),
            scheduleStatus(schedule, colorEnabled: colorEnabled),
            triggerSummary(schedule.trigger),
            FlexibleDate.displayLocal(schedule.nextRunAt)
        ]
    }

    static func runRow(_ run: WireRun, colorEnabled: Bool) -> [String] {
        let statusColor: String?
        switch run.status {
        case "ok": statusColor = ANSI.green
        case "failed", "timeout": statusColor = ANSI.red
        case "interrupted", "queued", "running": statusColor = ANSI.yellow
        default: statusColor = nil
        }
        let status = statusColor.map { colorize(run.status ?? "-", $0, enabled: colorEnabled) } ?? (run.status ?? "-")
        return [
            run.id,
            status,
            run.trigger ?? "-",
            FlexibleDate.displayLocal(run.startedAt),
            truncated(run.summary ?? run.error ?? "", max: previewWidth)
        ]
    }
}
