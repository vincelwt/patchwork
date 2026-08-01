import Foundation
import os
import PatchworkKit

enum ConversationPerformance {
    private static let log = OSLog(subsystem: "app.patchwork.desktop", category: .pointsOfInterest)

    static func mark(
        _ name: StaticString,
        path: String,
        agent: AgentKind? = nil,
        count: Int = 0,
        milliseconds: Double = 0
    ) {
        os_signpost(
            .event,
            log: log,
            name: name,
            "%{public}@ agent=%{public}@ count=%d elapsed_ms=%.2f",
            path,
            agent?.rawValue ?? "unknown",
            count,
            milliseconds
        )
    }
}
