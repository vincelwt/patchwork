import Darwin
import Foundation
import PiDeskKit

/// Owns `pi-deskd`'s lifecycle from inside the app: starts the bundled daemon if nothing is
/// already serving the control socket, restarts it (bounded) if it dies unexpectedly, and stops
/// only the instance it started when the app quits. See docs/daemon-api.md's "Lifecycle" section
/// for the contract this implements, and `Sources/PiDeskCLI/Support/DaemonSupervisionRules.swift`
/// for the tested reference the pure decisions here mirror.
///
/// One poll loop drives everything after the initial decision: it starts once autos-management
/// is active and keeps re-evaluating `state` on a bounded interval so external changes (someone
/// installs the LaunchAgent, the owned process dies, a hung daemon needs a kick) are all handled
/// in one place instead of scattered timers.
@MainActor
final class DaemonSupervisor: ObservableObject {
    enum State: Equatable {
        case idle
        case disabledByUser
        case deferringToLaunchAgent
        case deferringToExternalProcess
        case starting
        case running
        case restarting(attempt: Int)
        case crashLooped(detail: String)
        case unavailable(detail: String)
        case stopped
    }

    /// Bounds how long `stopForQuit`/turning the setting off waits for a graceful exit before
    /// force-killing the daemon's whole process group. Comfortably above the daemon's own
    /// internal shutdown grace (`DaemonCore.stop`'s default 10s plus a ~2s `pi` teardown), so the
    /// common case never hits this ceiling.
    static let stopTimeout: TimeInterval = 15

    @Published private(set) var state: State = .idle
    @Published var autoManageEnabled: Bool {
        didSet {
            guard oldValue != autoManageEnabled else { return }
            DaemonSupervisorSettings.setAutoManageEnabled(autoManageEnabled)
            Task { await autoManageToggled() }
        }
    }

    private let spawner: DaemonProcessSpawning
    private let healthProbe: DaemonHealthProbing
    private let launchAgentProbe: LaunchAgentProbing
    private let binaryLocator: () -> URL?
    private let ownerFileURL: URL
    private let pollInterval: TimeInterval
    private let clock: () -> Date

    private var failureCount = 0
    /// Set while `stopOwnedDaemon` itself is sending the signal, so the poll loop recognises the
    /// resulting disappearance as an intentional stop rather than an unexpected death to restart.
    private var intentionalStopInFlight = false
    private var pollTask: Task<Void, Never>?

    init(
        spawner: DaemonProcessSpawning = SystemDaemonProcessSpawner(logFile: PiDeskPaths.logFile),
        healthProbe: DaemonHealthProbing = SocketHealthProbe(),
        launchAgentProbe: LaunchAgentProbing = SystemLaunchAgentProbe(),
        binaryLocator: @escaping () -> URL? = { DaemonBinaryLocator.resolve() },
        ownerFileURL: URL = PiDeskPaths.supportDirectory.appendingPathComponent("daemon-owner.json"),
        pollInterval: TimeInterval = 5,
        clock: @escaping () -> Date = Date.init
    ) {
        self.spawner = spawner
        self.healthProbe = healthProbe
        self.launchAgentProbe = launchAgentProbe
        self.binaryLocator = binaryLocator
        self.ownerFileURL = ownerFileURL
        self.pollInterval = pollInterval
        self.clock = clock
        autoManageEnabled = DaemonSupervisorSettings.autoManageEnabled()
    }

    // MARK: - Launch

    /// Called once from `AppDelegate.applicationDidFinishLaunching`.
    func appDidLaunch() async {
        guard autoManageEnabled else { state = .disabledByUser; return }
        await evaluateAndAct()
        beginPolling()
    }

    private func autoManageToggled() async {
        if autoManageEnabled {
            await evaluateAndAct()
            beginPolling()
        } else {
            await stopOwnedDaemon(timeout: Self.stopTimeout)
            pollTask?.cancel()
            pollTask = nil
            state = .disabledByUser
        }
    }

    /// Settings' "Try Again" after a crash loop or a missing binary: reset and start fresh.
    func retry() async {
        switch state {
        case .crashLooped, .unavailable: break
        default: return
        }
        failureCount = 0
        await evaluateAndAct()
        beginPolling()
    }

    /// The one-shot decision made at launch, on re-enable, and on manual retry: LaunchAgent wins
    /// unconditionally, then an already-reachable daemon (ours from an earlier run, or someone
    /// else's) is left alone, and only an empty field gets a spawn.
    private func evaluateAndAct() async {
        if launchAgentProbe.isLoaded() {
            state = .deferringToLaunchAgent
            return
        }
        if await healthProbe.probe() {
            // A stale *socket file* would fail this probe and fall through to `spawn()` below —
            // `pi-deskd`'s own listener setup unlinks and rebinds over one automatically
            // (`POSIXListener.unixSocket`), so "reachable" here always means a live daemon, never
            // a leftover file from a crash.
            let owned = DaemonOwnerFile.isLive(DaemonOwnerFile.read(from: ownerFileURL))
            state = owned ? .running : .deferringToExternalProcess
            return
        }
        await spawn()
    }

    // MARK: - Spawn + restart

    private func spawn() async {
        guard let binary = binaryLocator() else {
            state = .unavailable(detail: "pi-deskd was not found inside this app bundle.")
            return
        }
        state = failureCount > 0 ? .restarting(attempt: failureCount) : .starting
        do {
            let process = try spawner.spawn(binary: binary)
            try? DaemonOwnerFile.write(DaemonOwnerRecord(pid: process.pid, startedAt: clock()), to: ownerFileURL)
            // Give it a moment to bind the socket before judging whether it actually came up —
            // long enough for a normal start, short enough that a genuinely dead-on-arrival
            // process (bad build, lost a bind race) is still caught by the backoff loop below
            // rather than being declared healthy by mistake.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard kill(process.pid, 0) == 0 else {
                DaemonOwnerFile.remove(at: ownerFileURL)
                await handleUnexpectedDeath()
                return
            }
            state = .running
        } catch {
            state = .unavailable(detail: "Could not start pi-deskd: \(error.localizedDescription)")
        }
    }

    private func handleUnexpectedDeath() async {
        guard !intentionalStopInFlight else { return }
        failureCount += 1
        if RestartPolicy.hasExhausted(failureCount: failureCount) {
            pollTask?.cancel()
            pollTask = nil
            state = .crashLooped(detail: "pi-deskd exited \(failureCount) times in a row; automations are paused until you try again.")
            return
        }
        let delay = RestartPolicy.delay(forFailureCount: failureCount)
        state = .restarting(attempt: failureCount)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard autoManageEnabled else { return } // turned off while waiting to retry
        await spawn()
    }

    // MARK: - Polling (the one recurring loop)

    private func beginPolling() {
        guard pollTask == nil else { return }
        let intervalNanos = UInt64(max(pollInterval, 1) * 1_000_000_000)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanos)
                guard let self, !Task.isCancelled else { return }
                await self.poll()
            }
        }
    }

    private func poll() async {
        switch state {
        case .idle, .disabledByUser, .crashLooped, .unavailable, .stopped, .starting, .restarting:
            return // transient or terminal; nothing to reconcile on a timer
        case .deferringToLaunchAgent:
            if !launchAgentProbe.isLoaded() { await evaluateAndAct() }
        case .deferringToExternalProcess:
            if launchAgentProbe.isLoaded() { state = .deferringToLaunchAgent; return }
            if await !healthProbe.probe() { await spawn() }
        case .running:
            if launchAgentProbe.isLoaded() {
                // Someone installed the LaunchAgent while we were running our own: relinquish
                // rather than have two things think they own this daemon's lifecycle.
                await stopOwnedDaemon(timeout: Self.stopTimeout)
                state = .deferringToLaunchAgent
                return
            }
            if DaemonOwnerFile.isLive(DaemonOwnerFile.read(from: ownerFileURL)) {
                failureCount = 0 // a stable, still-alive daemon clears any earlier flapping history
            } else {
                await handleUnexpectedDeath()
            }
        }
    }

    // MARK: - Quit

    /// Called from `AppDelegate.applicationShouldTerminate`. Always safe to call even when this
    /// instance owns nothing: `stopOwnedDaemon` no-ops on anything it does not recognise as ours.
    func stopForQuit() async {
        pollTask?.cancel()
        pollTask = nil
        await stopOwnedDaemon(timeout: Self.stopTimeout)
    }

    /// Only ever signals the pid in `daemon-owner.json`, and only once that record's own
    /// liveness check passes — a LaunchAgent-managed or externally-started daemon never has a
    /// record here, so this is a no-op for both by construction, not by a state-based guard that
    /// could drift out of sync with reality.
    private func stopOwnedDaemon(timeout: TimeInterval) async {
        guard let owner = DaemonOwnerFile.read(from: ownerFileURL), DaemonOwnerFile.isLive(owner) else {
            state = .stopped
            return
        }
        intentionalStopInFlight = true
        defer { intentionalStopInFlight = false }

        await terminate(pid: owner.pid, timeout: timeout)
        DaemonOwnerFile.remove(at: ownerFileURL)
        state = .stopped
    }

    /// Graceful SIGTERM — the daemon's own handler drains in-flight runs (docs/daemon-api.md,
    /// "Shutdown") — with a bounded wait, then a last-resort SIGKILL of its whole process group
    /// (see `SystemDaemonProcessSpawner`'s `setpgid`) so a `pi` child it spawned for a run cannot
    /// outlive it either. That fallback abandons whatever was still running rather than finishing
    /// it: by the time `timeout` has elapsed the daemon already had its chance to shut down
    /// cleanly on its own.
    private func terminate(pid: Int32, timeout: TimeInterval) async {
        kill(pid, SIGTERM)
        let deadline = clock().addingTimeInterval(timeout)
        while kill(pid, 0) == 0, clock() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if kill(pid, 0) == 0 {
            kill(-pid, SIGKILL)
        }
    }
}
