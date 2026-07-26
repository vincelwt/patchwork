import Foundation

/// One decoded frame from `GET /v1/events`. `.unknown` is not an edge case to handle "just in
/// case" — it is the mechanism by which an older client stays compatible with a newer daemon
/// that starts emitting an event name this package predates, per the doc's compatibility rules.
public enum PiDeskEvent: Sendable {
    case thread(PiThread)
    case activity(ActivitySnapshot)
    case run(Run)
    case schedule(Schedule)
    case unknown(name: String, data: PiJSONValue)

    /// The SSE `event:` field this frame was published under.
    public var name: String {
        switch self {
        case .thread: "thread"
        case .activity: "activity"
        case .run: "run"
        case .schedule: "schedule"
        case let .unknown(name, _): name
        }
    }
}
