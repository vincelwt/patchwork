import Foundation

/// One of the contract's four trigger kinds, already validated and ready to become a
/// `WireTrigger`. Keeping this as its own type (rather than building `WireTrigger` directly)
/// makes the "exactly one of --at/--every/--cron/--heartbeat" rule testable independent of JSON
/// shape.
enum TriggerInput: Equatable {
    case once(at: Date)
    case interval(everySeconds: Int, startAt: Date?)
    case cron(expression: String, timeZone: String)
    case heartbeat(everySeconds: Int)

    var wire: WireTrigger {
        switch self {
        case let .once(at):
            return WireTrigger(kind: "once", at: FlexibleDate.iso8601(at), everySeconds: nil, startAt: nil, expression: nil, timeZone: nil)
        case let .interval(everySeconds, startAt):
            return WireTrigger(kind: "interval", at: nil, everySeconds: everySeconds, startAt: startAt.map(FlexibleDate.iso8601), expression: nil, timeZone: nil)
        case let .cron(expression, timeZone):
            return WireTrigger(kind: "cron", at: nil, everySeconds: nil, startAt: nil, expression: expression, timeZone: timeZone)
        case let .heartbeat(everySeconds):
            return WireTrigger(kind: "heartbeat", at: nil, everySeconds: everySeconds, startAt: nil, expression: nil, timeZone: nil)
        }
    }
}

struct TriggerFlags {
    var at: String?
    var every: String?
    var cron: String?
    var heartbeat: String?
    var timezone: String?
    var startAt: String?
}

/// Resolves the four mutually-exclusive trigger flags into one `TriggerInput`, or throws a
/// precise usage error. This is the single place "reject ambiguity loudly" is enforced for
/// `schedule add`.
func resolveTrigger(_ flags: TriggerFlags, localTimeZone: TimeZone = .current) throws -> TriggerInput {
    let present = ["--at": flags.at, "--every": flags.every, "--cron": flags.cron, "--heartbeat": flags.heartbeat]
        .compactMap { name, value in value != nil ? name : nil }

    guard !present.isEmpty else {
        throw UsageError.custom("one of --at, --every, --cron, or --heartbeat is required")
    }
    guard present.count == 1 else {
        throw UsageError.conflictingFlags(present)
    }
    if flags.timezone != nil, flags.cron == nil {
        throw UsageError.custom("--timezone only applies with --cron")
    }
    if flags.startAt != nil, flags.every == nil {
        throw UsageError.custom("--start-at only applies with --every")
    }

    if let at = flags.at {
        return .once(at: try FlexibleDate.parse(at, timeZone: localTimeZone))
    }
    if let every = flags.every {
        let startAt = try flags.startAt.map { try FlexibleDate.parse($0, timeZone: localTimeZone) }
        return .interval(everySeconds: Int(try parseDuration(every)), startAt: startAt)
    }
    if let cron = flags.cron {
        let expression = try CronExpression.validate(cron)
        return .cron(expression: expression, timeZone: flags.timezone ?? localTimeZone.identifier)
    }
    if let heartbeat = flags.heartbeat {
        return .heartbeat(everySeconds: Int(try parseDuration(heartbeat)))
    }
    // Unreachable: `present` guarantees exactly one of the four is non-nil.
    throw UsageError.custom("one of --at, --every, --cron, or --heartbeat is required")
}
