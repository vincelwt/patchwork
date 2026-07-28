import Darwin
import Foundation
import PiDeskKit

/// The complete Pi Desktop control plane without a process policy. Pi Desktop hosts one of these
/// directly; the optional `pi-deskd` executable is only another host for the same service.
public final class PiDeskControlService: @unchecked Sendable {
    private let settings: DaemonSettings
    private let logger: DaemonLogger
    private let connectivity: DaemonConnectivityMonitor?
    private let core: DaemonCore
    private let router: DaemonRouter
    private let server: HTTPServer
    private let unixSocketPath: URL
    private let stateLock = NSLock()
    private var started = false
    private var stopped = false

    public convenience init() {
        let settings = DaemonSettings.load()
        let logger = DaemonLogger()
        let interactions = InteractionRegistry(logger: logger)
        let liveSessions = LiveSessionRegistry()
        let connectivity = DaemonConnectivityMonitor()
        let executor = PiProcessRunExecutor(
            logger: logger,
            interactions: interactions,
            liveSessions: liveSessions
        )
        let core = DaemonCore(
            settings: settings,
            logger: logger,
            executor: executor,
            networkAvailable: { connectivity.isOnline },
            piVersion: PiVersion.detect(),
            interactions: interactions,
            liveSessions: liveSessions
        )
        self.init(
            settings: settings,
            logger: logger,
            connectivity: connectivity,
            core: core,
            unixSocketPath: PiDeskPaths.controlSocket
        )
    }

    init(
        settings: DaemonSettings,
        logger: DaemonLogger,
        connectivity: DaemonConnectivityMonitor?,
        core: DaemonCore,
        unixSocketPath: URL
    ) {
        self.settings = settings
        self.logger = logger
        self.connectivity = connectivity
        self.core = core
        router = DaemonRouter(routes: Routes.all(core))
        server = HTTPServer(
            router: router,
            logger: logger,
            bus: core.bus,
            tokenProvider: { settings.remoteEnabled ? (try? DaemonToken.loadOrCreate()) : nil }
        )
        self.unixSocketPath = unixSocketPath
    }

    public func start() async throws {
        guard claimStart() else { return }
        guard !Task.isCancelled else {
            markStopped()
            throw CancellationError()
        }

        // A disconnected CLI/browser is routine. The host process must receive EPIPE rather than
        // terminate, whether the host is Pi Desktop or the optional standalone executable.
        signal(SIGPIPE, SIG_IGN)
        logger.info("Pi Desktop control service starting (concurrency=\(settings.concurrency), remoteEnabled=\(settings.remoteEnabled), port=\(settings.port))")
        connectivity?.start()
        var coreStarted = false
        do {
            try server.start(
                unixSocketPath: unixSocketPath,
                tcpPort: settings.remoteEnabled ? settings.port : nil
            )
            try Task.checkCancellation()
            await core.runHistoryStore.reconcileAfterHostRestart()
            try Task.checkCancellation()
            await core.start()
            coreStarted = true
            try Task.checkCancellation()
            await core.startRelay(router: router)
            logger.info("Pi Desktop control service ready")
        } catch {
            server.stop()
            if coreStarted { await core.stop(graceSeconds: 0) }
            connectivity?.stop()
            logger.error("Could not start Pi Desktop control service: \(error)")
            logger.flush()
            markStopped()
            throw error
        }
    }

    public func stop(graceSeconds: TimeInterval = 10) async {
        guard claimStop() else { return }

        logger.info("Pi Desktop control service shutting down")
        server.stop()
        await core.stop(graceSeconds: graceSeconds)
        connectivity?.stop()
        logger.flush()
    }

    private func claimStart() -> Bool {
        stateLock.withLock {
            guard !started, !stopped else { return false }
            started = true
            return true
        }
    }

    private func claimStop() -> Bool {
        stateLock.withLock {
            guard started, !stopped else { return false }
            stopped = true
            return true
        }
    }

    private func markStopped() {
        stateLock.withLock { stopped = true }
    }
}
