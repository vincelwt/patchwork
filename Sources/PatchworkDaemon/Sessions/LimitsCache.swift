import Foundation
import PatchworkKit

/// Backs `GET /v1/limits`. Deliberately just a cache with nothing wired to populate it yet: the
/// daemon has no notion of a "current" thread the way the app's status bar does, and refreshing
/// on every `GET` would make a read endpoint spawn a Pi process with unpredictable latency. See
/// the top-level report for why this is left as a documented gap rather than guessed at.
actor LimitsCache {
    private var report = LimitsReportData(accounts: [])
    private var generatedAt: Date?
    private let staleAfter: TimeInterval

    init(staleAfter: TimeInterval = 300) {
        self.staleAfter = staleAfter
    }

    func snapshot(now: Date = Date()) -> LimitsSnapshot {
        guard let generatedAt else { return LimitsSnapshot(report: report, generatedAt: .distantPast, stale: true) }
        let stale = now.timeIntervalSince(generatedAt) > staleAfter
        return LimitsSnapshot(report: report, generatedAt: generatedAt, stale: stale)
    }

    /// The hook a future caller (a run that happens to capture `/limits` output) would use.
    func apply(text: String, now: Date = Date()) {
        report = LimitsTextParser.parse(text, now: now)
        generatedAt = now
    }
}
