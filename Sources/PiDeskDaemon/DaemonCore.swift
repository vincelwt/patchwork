import Foundation
import PiDeskKit

/// The composition root: owns every store/service and wires them together. `main.swift` builds
/// exactly one of these for production; tests build their own with a fake `RunExecuting` and
/// (usually) a temp-directory `PiDeskPaths`-equivalent, never touching the real
/// `~/Library/Application Support/Pi Desktop` or `~/.pi/agent` locations.
final class DaemonCore: @unchecked Sendable {
    let logger: DaemonLogger
    let bus: EventBus
    let scheduleStore: ScheduleStore
    let runHistoryStore: RunHistoryStore
    let leaseStore: LeaseStore
    let threadStore: ThreadStore
    let runQueue: RunQueue
    let scheduler: Scheduler
    let activityService: ActivityService
    let limitsCache: LimitsCache
    let settings: DaemonSettings
    let startedAt = Date()
    let version = "1.0.0"
    let piVersion: String?

    init(
        settings: DaemonSettings,
        logger: DaemonLogger,
        executor: RunExecuting,
        sessionRootURL: URL = SessionScanner.defaultRootURL(),
        activityDirectoryURL: URL = PiDeskPaths.activityDirectory,
        schedulesFileURL: URL = PiDeskPaths.schedules,
        runHistoryFileURL: URL = PiDeskPaths.runHistory,
        overlayFileURL: URL = PiDeskPaths.supportDirectory.appendingPathComponent("daemon-thread-overlay.json"),
        schedulerPollInterval: TimeInterval = 1,
        piVersion: String? = nil
    ) {
        self.settings = settings
        self.logger = logger
        self.piVersion = piVersion

        let bus = EventBus(logger: logger)
        self.bus = bus
        scheduleStore = ScheduleStore(fileURL: schedulesFileURL, logger: logger)
        runHistoryStore = RunHistoryStore(fileURL: runHistoryFileURL, logger: logger)
        leaseStore = LeaseStore()
        let overlay = DaemonOverlayStore(fileURL: overlayFileURL)
        threadStore = ThreadStore(rootURL: sessionRootURL, activityDirectoryURL: activityDirectoryURL, logger: logger, overlay: overlay)
        limitsCache = LimitsCache()

        let queue = RunQueue(concurrencyLimit: settings.concurrency, executor: executor, historyStore: runHistoryStore, bus: bus, logger: logger)
        runQueue = queue
        scheduler = Scheduler(scheduleStore: scheduleStore, runQueue: queue, threadStore: threadStore, leaseStore: leaseStore, bus: bus, logger: logger, pollInterval: schedulerPollInterval)
        activityService = ActivityService(
            logger: logger, threadStore: threadStore, leaseStore: leaseStore, activityDirectoryURL: activityDirectoryURL,
            daemonActiveThreadIDs: { await queue.activeThreadIDs() }
        )
    }

    func start() async {
        await scheduler.start()
    }

    func stop() async {
        await scheduler.stop()
    }

    func health() async -> HealthStatus {
        let runningRuns = await runQueue.activeCount()
        let queuedRuns = await runQueue.queuedCount()
        let quarantine = await scheduleStore.quarantineIssues
        return HealthStatus(
            ok: true,
            version: version,
            startedAt: startedAt,
            runningRuns: runningRuns,
            queuedRuns: queuedRuns,
            piVersion: piVersion,
            schedulesEnabled: await scheduler.enabled,
            issues: quarantine
        )
    }

    /// The bearer token for the loopback listener, created on first use exactly like
    /// `pidesk remote enable`/`token` would expect.
    func currentToken() -> String? {
        try? DaemonToken.loadOrCreate()
    }
}
