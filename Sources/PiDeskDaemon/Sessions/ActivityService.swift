import Foundation
import PiDeskKit

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
    var activityDirectoryURL: URL = PiDeskPaths.activityDirectory
    /// Injected rather than a concrete `RunQueue` dependency, so this stays testable without
    /// spinning up the whole runner.
    let daemonActiveThreadKeys: @Sendable () async -> Set<ThreadInstanceKey>

    func snapshot(now: Date = Date()) async -> ActivitySnapshot {
        let heartbeats = ActivityReader.readHeartbeats(directory: activityDirectoryURL, logger: logger)
        let runningHeartbeats = heartbeats.filter { ActivityReader.isRunning($0, now: now) }
        let activeInDaemon = await daemonActiveThreadKeys()

        var runningByIdentity: [String: RunningThread] = [:]
        // Sessions started before the heartbeat extension existed still have to be reported
        // correctly, so their files are classified with the same rules the window applies.
        let heartbeatPaths = Set(heartbeats.compactMap(\.sessionFile).map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        let legacyHeartbeatIDs = Set(heartbeats.filter { $0.sessionFile == nil }.map(\.sessionId))
        let projection = await threadStore.activityProjection(
            excludingPaths: heartbeatPaths,
            legacyIDs: legacyHeartbeatIDs,
            heartbeats: heartbeats,
            runningHeartbeats: runningHeartbeats,
            now: now
        )
        for thread in projection.threadsWithoutHeartbeat {
            let threadKey = ThreadInstanceKey(path: thread.path)
            let source: ActivitySource
            if activeInDaemon.contains(threadKey) {
                source = .daemon
            } else if await leaseStore.isLeased(thread: threadKey, now: now) {
                source = .app
            } else {
                source = .terminal
            }
            Self.merge(RunningThread(
                threadId: thread.id, threadPath: thread.path,
                since: thread.updatedAt, source: source
            ), into: &runningByIdentity)
        }
        for heartbeat in runningHeartbeats {
            let threadId = heartbeat.sessionId
            let threadKey = heartbeat.sessionFile.map { ThreadInstanceKey(path: $0) }
            let source: ActivitySource
            if let threadKey, activeInDaemon.contains(threadKey) {
                source = .daemon
            } else if let threadKey, await leaseStore.isLeased(thread: threadKey, now: now) {
                source = .app
            } else {
                source = .terminal
            }
            Self.merge(RunningThread(
                threadId: threadId,
                threadPath: heartbeat.sessionFile.map {
                    URL(fileURLWithPath: $0).standardizedFileURL.path
                },
                since: heartbeat.startedAt ?? heartbeat.updatedAt, source: source
            ), into: &runningByIdentity)
        }

        // Queue ownership is authoritative. Codex and Claude Code have no Pi heartbeat extension,
        // and their foreign lifecycle records may not be durable yet when a daemon run starts.
        for threadKey in activeInDaemon {
            let identity = "path:\(threadKey.path)"
            guard runningByIdentity[identity] == nil,
                  let thread = await threadStore.thread(idOrPath: threadKey.path) else { continue }
            Self.merge(RunningThread(
                threadId: thread.id,
                threadPath: thread.path,
                since: thread.updatedAt,
                source: .daemon
            ), into: &runningByIdentity)
        }
        Self.coalesceUnambiguousIDOnlyRows(
            in: &runningByIdentity, sessionIDCounts: projection.sessionIDCounts
        )

        let running = runningByIdentity.values.sorted {
            [$0.threadPath ?? "", $0.threadId, $0.source.rawValue]
                .lexicographicallyPrecedes([$1.threadPath ?? "", $1.threadId, $1.source.rawValue])
        }
        return ActivitySnapshot(
            running: running,
            unreadCount: projection.unreadCount,
            observedAt: now
        )
    }

    private static func merge(
        _ candidate: RunningThread, into values: inout [String: RunningThread]
    ) {
        let identity = candidate.threadPath.map { "path:\($0)" } ?? "id:\(candidate.threadId)"
        guard let existing = values[identity] else {
            values[identity] = candidate
            return
        }
        let source = sourcePriority(candidate.source) > sourcePriority(existing.source)
            ? candidate.source : existing.source
        values[identity] = RunningThread(
            threadId: existing.threadId,
            threadPath: existing.threadPath ?? candidate.threadPath,
            since: min(existing.since, candidate.since),
            source: source
        )
    }

    /// Older or in-memory writers may omit `sessionFile`. Only a catalog-unique id can safely be
    /// attached to a path. Live-row uniqueness is insufficient because another copied transcript
    /// with the same id may currently be idle or may be represented only by file fallback.
    private static func coalesceUnambiguousIDOnlyRows(
        in values: inout [String: RunningThread], sessionIDCounts: [String: Int]
    ) {
        let idOnlyKeys = values.keys.filter { $0.hasPrefix("id:") }
        for idKey in idOnlyKeys {
            guard let idOnly = values[idKey], sessionIDCounts[idOnly.threadId] == 1 else {
                continue
            }
            let pathMatches = values.compactMap { key, value in
                key.hasPrefix("path:") && value.threadId == idOnly.threadId ? key : nil
            }
            guard pathMatches.count == 1,
                  let pathKey = pathMatches.first,
                  let pathValue = values[pathKey] else { continue }
            values.removeValue(forKey: idKey)
            let source = sourcePriority(idOnly.source) > sourcePriority(pathValue.source)
                ? idOnly.source : pathValue.source
            values[pathKey] = RunningThread(
                threadId: pathValue.threadId,
                threadPath: pathValue.threadPath,
                since: min(pathValue.since, idOnly.since),
                source: source
            )
        }
    }

    private static func sourcePriority(_ source: ActivitySource) -> Int {
        if source == .daemon { return 3 }
        if source == .app { return 2 }
        if source == .terminal { return 1 }
        return 0
    }
}
