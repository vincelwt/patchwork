import Foundation
import PatchworkKit

/// The composition root: owns every store/service and wires them together. `main.swift` builds
/// exactly one of these for production; tests build their own with a fake `RunExecuting` and
/// (usually) a temp-directory `PatchworkPaths`-equivalent, never touching the real
/// `~/Library/Application Support/Patchwork` or `~/.pi/agent` locations.
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
    let activityPublisher: ActivityPublisher
    let limitsCache: LimitsCache
    let relay: RelayService
    let settings: DaemonSettings
    /// Dialogs daemon runs are currently blocked on. Shared with the executor, which is built
    /// before this type exists, so it is injected rather than created here.
    let interactions: InteractionRegistry
    /// Threads with a daemon-owned Pi turn in flight, for `delivery: steer|followUp`.
    let liveSessions: LiveSessionRegistry
    /// Replay protection for `POST /v1/threads/{id}/messages`, keyed by the caller's own id.
    let submissions: SubmissionRegistry
    /// Short-lived, query-only or setter-only Pi sessions for idle thread operations.
    let threadRPC: ThreadRPCServing
    let startedAt = Date()
    let version = "1.0.0"
    let piVersion: String?
    /// The app's `state.json`, read-only, for the folder tree `GET /v1/folders` exposes. A
    /// parameter purely so tests point at a throwaway file instead of the real one.
    let appStateURL: URL
    /// Injectable so worktree creation tests never touch the user's `~/.pi/worktrees`.
    let worktreeRootURL: URL
    /// Agent availability seam. Production resolves installed executables; tests inject a stable
    /// catalog so route behavior never depends on the developer machine.
    let isAgentInstalled: @Sendable (AgentKind) -> Bool

    init(
        settings: DaemonSettings,
        logger: DaemonLogger,
        executor: RunExecuting,
        sessionRootURL: URL = SessionScanner.defaultRootURL(),
        /// Injectable so a test can seed another agent's tree; production derives every root from
        /// the Pi root, which pins all of them when it is itself pinned.
        sessionRoots: [(agent: AgentKind, url: URL)]? = nil,
        activityDirectoryURL: URL = PatchworkPaths.activityDirectory,
        schedulesFileURL: URL = PatchworkPaths.schedules,
        runHistoryFileURL: URL = PatchworkPaths.runHistory,
        overlayFileURL: URL = PatchworkPaths.supportDirectory.appendingPathComponent("daemon-thread-overlay.json"),
        submissionFileURL: URL? = PatchworkPaths.submissionReplays,
        relayIdentityFileURL: URL = PatchworkPaths.relayIdentity,
        relayWebSocketOrigin: String = RelayService.websocketOrigin,
        schedulerPollInterval: TimeInterval = 1,
        schedulerRetryDelays: [TimeInterval] = Scheduler.defaultRetryDelays,
        networkAvailable: @escaping @Sendable () -> Bool = { true },
        piVersion: String? = nil,
        interactions: InteractionRegistry = InteractionRegistry(),
        liveSessions: LiveSessionRegistry = LiveSessionRegistry(),
        threadRPC: ThreadRPCServing? = nil,
        appStateURL: URL = AppStatePeek.defaultURL(),
        worktreeRootURL: URL = WorktreeService.root,
        isAgentInstalled: @escaping @Sendable (AgentKind) -> Bool = {
            AgentCatalog.executable(for: $0) != nil
        }
    ) {
        self.settings = settings
        self.logger = logger
        self.piVersion = piVersion
        self.interactions = interactions
        self.liveSessions = liveSessions
        submissions = SubmissionRegistry(fileURL: submissionFileURL, logger: logger)
        self.threadRPC = threadRPC ?? ThreadCreationService(logger: logger)
        self.appStateURL = appStateURL
        self.worktreeRootURL = worktreeRootURL.standardizedFileURL
        self.isAgentInstalled = isAgentInstalled

        let bus = EventBus(logger: logger)
        self.bus = bus
        interactions.attach(bus: bus)
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
        threadStore = ThreadStore(
            rootURL: sessionRootURL, roots: sessionRoots, activityDirectoryURL: activityDirectoryURL,
            appStateURL: appStateURL, logger: logger, overlay: overlay,
            indexFileURL: overlayFileURL.deletingLastPathComponent()
                .appendingPathComponent("daemon-thread-index.json")
        )
        limitsCache = LimitsCache()

        let queue = RunQueue(
            concurrencyLimit: settings.concurrency, executor: executor,
            historyStore: runHistoryStore, bus: bus, logger: logger,
            leaseStore: leaseStore
        )
        runQueue = queue
        scheduler = Scheduler(
            scheduleStore: scheduleStore, runHistoryStore: runHistoryStore,
            runQueue: queue, threadStore: threadStore, leaseStore: leaseStore,
            bus: bus, logger: logger, pollInterval: schedulerPollInterval,
            retryDelays: schedulerRetryDelays, networkAvailable: networkAvailable
        )
        let activityService = ActivityService(
            logger: logger, threadStore: threadStore, leaseStore: leaseStore, activityDirectoryURL: activityDirectoryURL,
            daemonActiveThreadKeys: { await queue.activeThreadKeys() }
        )
        self.activityService = activityService
        activityPublisher = ActivityPublisher(bus: bus) { await activityService.snapshot() }
    }

    func start() async {
        await scheduler.start()
        await activityPublisher.start()
    }

    func startRelay(router: DaemonRouter) async {
        await relay.start(router: router)
    }

    /// `graceSeconds` bounds how long a run in flight gets to finish naturally before this
    /// forcibly cancels it — see `RunQueue.shutdown(graceSeconds:)` and docs/daemon-api.md's
    /// "Shutdown" section for the full contract. The scheduler stops first so nothing new can
    /// start while the queue is draining.
    func stop(graceSeconds: TimeInterval = 10) async {
        await activityPublisher.stop()
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
            scheduleIdempotency: true,
            threadCreationIdempotency: true,
            messageSubmissionIdempotency: true,
            scheduleRunIdempotency: true,
            issues: quarantine
        )
    }

    /// The bearer token for the loopback listener, created on first use exactly like
    /// `patchwork remote enable`/`token` would expect.
    func currentToken() -> String? {
        try? DaemonToken.loadOrCreate()
    }
}
