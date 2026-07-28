import Darwin
import Foundation
import PiDeskDaemon
import PiDeskKit

protocol ControlServiceLifecycle: AnyObject, Sendable {
    func start() async throws
    func stop(graceSeconds: TimeInterval) async
}

extension PiDeskControlService: ControlServiceLifecycle {}

typealias ControlServiceFactory = @MainActor () async -> any ControlServiceLifecycle

/// Hosts the control plane inside Pi Desktop. The optional LaunchAgent/standalone daemon still
/// wins when explicitly installed, but the default path has no child `pi-deskd` process: closing
/// the app closes the service and every Pi runtime it owns.
@MainActor
final class DaemonSupervisor: ObservableObject {
    enum State: Equatable {
        case idle
        case deferringToLaunchAgent
        case deferringToExternalProcess
        case starting
        case running
        case unavailable(detail: String)
        case stopped
    }

    static let legacyStopTimeout: TimeInterval = 15

    @Published private(set) var state: State = .idle

    private let serviceFactory: ControlServiceFactory
    private let healthProbe: DaemonHealthProbing
    private let launchAgentProbe: LaunchAgentProbing
    private let ownerFileURL: URL
    private let currentPID: Int32
    private let pollInterval: TimeInterval
    private let clock: () -> Date
    private let isProcessAlive: (Int32) -> Bool
    private let isLegacyDaemon: (DaemonOwnerRecord) -> Bool
    private let signalProcess: (Int32, Int32) -> Void
    private var service: (any ControlServiceLifecycle)?
    private var pollTask: Task<Void, Never>?
    private var takeoverTask: Task<Void, Never>?
    private var isTerminating = false

    init(
        serviceFactory: @escaping ControlServiceFactory = {
            await Task.detached(priority: .utility) { PiDeskControlService() }.value
        },
        healthProbe: DaemonHealthProbing = SocketHealthProbe(),
        launchAgentProbe: LaunchAgentProbing = SystemLaunchAgentProbe(),
        ownerFileURL: URL = PiDeskPaths.supportDirectory.appendingPathComponent("daemon-owner.json"),
        currentPID: Int32 = getpid(),
        pollInterval: TimeInterval = 5,
        clock: @escaping () -> Date = Date.init,
        isProcessAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 },
        isLegacyDaemon: @escaping (DaemonOwnerRecord) -> Bool = { LegacyDaemonProcess.matches($0) },
        signalProcess: @escaping (Int32, Int32) -> Void = { pid, signal in _ = kill(pid, signal) }
    ) {
        self.serviceFactory = serviceFactory
        self.healthProbe = healthProbe
        self.launchAgentProbe = launchAgentProbe
        self.ownerFileURL = ownerFileURL
        self.currentPID = currentPID
        self.pollInterval = pollInterval
        self.clock = clock
        self.isProcessAlive = isProcessAlive
        self.isLegacyDaemon = isLegacyDaemon
        self.signalProcess = signalProcess
    }

    func appDidLaunch() async {
        guard !isTerminating else { return }
        await retireLegacyAppManagedDaemon()
        guard !isTerminating else { return }

        if launchAgentProbe.isLoaded() {
            state = .deferringToLaunchAgent
            beginDeferralPolling()
            return
        }
        if await healthProbe.probe() {
            state = .deferringToExternalProcess
            beginDeferralPolling()
            return
        }
        await startService()
    }

    func retry() async {
        guard case .unavailable = state else { return }
        await appDidLaunch()
    }

    func stopForQuit() async {
        isTerminating = true
        let polling = pollTask
        let takeover = takeoverTask
        pollTask = nil
        takeoverTask = nil
        polling?.cancel()
        takeover?.cancel()
        await polling?.value
        await takeover?.value
        guard let service else {
            state = .stopped
            return
        }
        self.service = nil
        // Quit means stop. Cancellation is cooperative, so Pi still gets its own bounded teardown
        // without holding the app open for an additional finish-naturally grace period.
        await service.stop(graceSeconds: 0)
        DaemonOwnerFile.remove(at: ownerFileURL)
        state = .stopped
    }

    private func startService() async {
        guard !isTerminating else { return }
        pollTask?.cancel()
        pollTask = nil
        state = .starting
        let candidate = await serviceFactory()
        guard !isTerminating else {
            await candidate.stop(graceSeconds: 0)
            return
        }
        do {
            try await candidate.start()
            guard !isTerminating else {
                await candidate.stop(graceSeconds: 0)
                state = .stopped
                return
            }
            service = candidate
            try DaemonOwnerFile.write(
                DaemonOwnerRecord(pid: currentPID, startedAt: clock(), host: "app"),
                to: ownerFileURL
            )
            state = .running
        } catch {
            await candidate.stop(graceSeconds: 0)
            DaemonOwnerFile.remove(at: ownerFileURL)
            state = .unavailable(detail: error.localizedDescription)
        }
    }

    private func beginDeferralPolling() {
        guard pollTask == nil else { return }
        let delay = UInt64(max(0.05, pollInterval) * 1_000_000_000)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled else { return }
                await self.reconcileDeferredHost()
            }
        }
    }

    private func reconcileDeferredHost() async {
        guard !isTerminating else { return }
        switch state {
        case .deferringToLaunchAgent:
            if launchAgentProbe.isLoaded() { return }
            let healthy = await healthProbe.probe()
            guard !isTerminating else { return }
            if healthy {
                state = .deferringToExternalProcess
            } else {
                beginTakeover()
            }
        case .deferringToExternalProcess:
            if launchAgentProbe.isLoaded() {
                state = .deferringToLaunchAgent
            } else {
                let healthy = await healthProbe.probe()
                guard !isTerminating else { return }
                if !healthy { beginTakeover() }
            }
        default:
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func beginTakeover() {
        guard !isTerminating, takeoverTask == nil else { return }
        pollTask?.cancel()
        pollTask = nil
        takeoverTask = Task { [weak self] in
            guard let self else { return }
            await self.startService()
            self.takeoverTask = nil
        }
    }

    /// One-release migration: an older Pi Desktop may have crashed after spawning a standalone
    /// app-managed daemon. Retire only the PID in its ownership record, then reuse the same file
    /// for this app process so existing `pidesk daemon status` keeps reporting app-managed mode.
    private func retireLegacyAppManagedDaemon() async {
        guard let owner = DaemonOwnerFile.read(from: ownerFileURL) else { return }
        if owner.pid == currentPID || !isProcessAlive(owner.pid) {
            DaemonOwnerFile.remove(at: ownerFileURL)
            return
        }
        // A live app-hosted record belongs to another Pi Desktop instance, not to the legacy
        // child-daemon migration. Its healthy socket is handled by the ordinary deferral path.
        guard owner.host == nil else { return }
        guard isLegacyDaemon(owner) else {
            DaemonOwnerFile.remove(at: ownerFileURL)
            return
        }

        signalProcess(owner.pid, SIGTERM)
        let deadline = clock().addingTimeInterval(Self.legacyStopTimeout)
        while isProcessAlive(owner.pid), isLegacyDaemon(owner), clock() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if isProcessAlive(owner.pid), isLegacyDaemon(owner) { signalProcess(-owner.pid, SIGKILL) }
        DaemonOwnerFile.remove(at: ownerFileURL)
    }
}
