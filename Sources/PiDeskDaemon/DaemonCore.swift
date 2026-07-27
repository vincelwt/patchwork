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
    let relay: RelayService
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
        relayIdentityFileURL: URL = PiDeskPaths.relayIdentity,
        relayWebSocketOrigin: String = RelayService.websocketOrigin,
        schedulerPollInterval: TimeInterval = 1,
        piVersion: String? = nil
    ) {
        self.settings = settings
        self.logger = logger
        self.piVersion = piVersion

        let bus = EventBus(logger: logger)
        self.bus = bus
        relay = RelayService(
            identityFileURL: relayIdentityFileURL,
            websocketOrigin: relayWebSocketOrigin,
            logger: logger,
            bus: bus
        )
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

    func startRelay(router: DaemonRouter) async {
        await relay.start(router: router)
    }

    /// `graceSeconds` bounds how long a run in flight gets to finish naturally before this
    /// forcibly cancels it — see `RunQueue.shutdown(graceSeconds:)` and docs/daemon-api.md's
    /// "Shutdown" section for the full contract. The scheduler stops first so nothing new can
    /// start while the queue is draining.
    func stop(graceSeconds: TimeInterval = 10) async {
        await relay.stop()
        await scheduler.stop()
        let running = await runQueue.activeCount()
        if running > 0 {
            logger.info("Shutting down with \(running) run(s) in flight; waiting up to \(Int(graceSeconds))s before cancelling.")
        }
        await runQueue.shutdown(graceSeconds: graceSeconds)
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
