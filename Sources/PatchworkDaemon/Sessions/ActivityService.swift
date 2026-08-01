import Foundation
import PatchworkKit

/// Builds the `GET /v1/activity` payload from heartbeat files, cross-referenced against what the
/// daemon itself is running and who holds a lease, to answer `source`. The heartbeat contract
/// (`sessionId`, `sessionFile`, `cwd`, `pid`, `state`, `startedAt`, `updatedAt`) has no `source`
/// field of its own, so it is inferred: a thread the daemon is actively running is `daemon`; a
/// leased thread the daemon is *not* running is presumed to be the app driving it directly
/// (`app`); anything else running is presumed to be a human's terminal (`terminal`), which is
/// also the correct fallback if inspection fails entirely.
struct ActivityService {
    let logger: DaemonLogger
    let threadStore: ThreadStore
    let leaseStore: LeaseStore
    var activityDirectoryURL: URL = PatchworkPaths.activityDirectory
    /// Injected rather than a concrete `RunQueue` dependency, so this stays testable without
    /// spinning up the whole runner.
    let daemonActiveThreadIDs: @Sendable () async -> Set<String>

    func snapshot(now: Date = Date()) async -> ActivitySnapshot {
        let heartbeats = ActivityReader.readHeartbeats(directory: activityDirectoryURL, logger: logger)
        let activeInDaemon = await daemonActiveThreadIDs()

        var running: [RunningThread] = []
        // Sessions started before the heartbeat extension existed still have to be reported
        // correctly, so their files are classified with the same rules the window applies.
        let heartbeatIDs = Set(heartbeats.map(\.sessionId))
        for thread in await threadStore.threadsWithoutHeartbeat(excluding: heartbeatIDs) {
            guard FileRunStateFallback.isRunning(sessionFile: URL(fileURLWithPath: thread.path), now: now) else { continue }
            let source: ActivitySource = await leaseStore.isLeased(threadId: thread.id, now: now) ? .app : .terminal
            running.append(RunningThread(threadId: thread.id, since: thread.updatedAt, source: source))
        }
        for heartbeat in heartbeats where ActivityReader.isRunning(heartbeat, now: now) {
            let threadId = heartbeat.sessionId
            let source: ActivitySource
            if activeInDaemon.contains(threadId) {
                source = .daemon
            } else if await leaseStore.isLeased(threadId: threadId, now: now) {
                source = .app
            } else {
                source = .terminal
            }
            running.append(RunningThread(threadId: threadId, since: heartbeat.startedAt ?? heartbeat.updatedAt, source: source))
        }

        let unreadCount = await threadStore.unreadCount()
        return ActivitySnapshot(running: running, unreadCount: unreadCount, observedAt: now)
    }
}
