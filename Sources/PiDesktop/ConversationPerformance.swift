import Foundation
import os

enum ConversationPerformance {
    private static let log = OSLog(subsystem: "dev.pi.desktop", category: .pointsOfInterest)

    static func mark(_ name: StaticString, path: String, count: Int = 0, milliseconds: Double = 0) {
        os_signpost(
            .event,
            log: log,
            name: name,
            "%{public}@ count=%d elapsed_ms=%.2f",
            path,
            count,
            milliseconds
        )
    }
}
