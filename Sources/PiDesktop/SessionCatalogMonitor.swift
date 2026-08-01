import CoreServices
import Foundation
import PiDeskKit

struct SessionCatalogChange: Equatable, Sendable {
    var candidatePaths: Set<String> = []
    var activityPaths: Set<String> = []
    var requiresFullScan = false
}

/// One recursive FSEvents stream covers every enabled agent root. It listens only for topology
/// changes; ordinary transcript appends stay on the bounded activity path and never rescan the
/// sidebar catalog.
final class SessionCatalogMonitor: @unchecked Sendable {
    static let maximumEventsPerCallback = 4_096

    private final class CallbackBox {
        let roots: [SessionObservationRoot]
        let handler: @Sendable (SessionCatalogChange) -> Void

        init(
            roots: [SessionObservationRoot],
            handler: @escaping @Sendable (SessionCatalogChange) -> Void
        ) {
            self.roots = roots
            self.handler = handler
        }
    }

    private let queue = DispatchQueue(label: "com.pi-desktop.session-catalog", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var callbackBox: CallbackBox?

    func start(
        roots: [SessionObservationRoot],
        handler: @escaping @Sendable (SessionCatalogChange) -> Void
    ) {
        stop()
        guard !roots.isEmpty else { return }
        let streamPaths = Array(Set(roots.map {
            SessionCatalogMonitor.nearestExistingAncestor(of: $0.url).path
        }))
        let box = CallbackBox(roots: roots, handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<SessionCatalogMonitor.CallbackBox>
                .fromOpaque(info).takeUnretainedValue()
            let boundedCount = min(count, SessionCatalogMonitor.maximumEventsPerCallback)
            let pointers = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var paths: [String] = []
            paths.reserveCapacity(boundedCount)
            var eventFlags: [FSEventStreamEventFlags] = []
            eventFlags.reserveCapacity(boundedCount)
            for index in 0..<boundedCount {
                guard let pointer = pointers[index] else { continue }
                paths.append(String(cString: pointer))
                eventFlags.append(flags[index])
            }
            var change = SessionCatalogMonitor.classify(
                paths: paths, flags: eventFlags, roots: box.roots
            )
            if count > SessionCatalogMonitor.maximumEventsPerCallback {
                change.requiresFullScan = true
            }
            if change.requiresFullScan || !change.candidatePaths.isEmpty || !change.activityPaths.isEmpty {
                box.handler(change)
            }
        }
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            streamPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            createFlags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        lock.lock()
        callbackBox = box
        self.stream = stream
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        let retainedBox = callbackBox
        lock.unlock()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        queue.sync {}
        lock.lock()
        callbackBox = nil
        lock.unlock()
        withExtendedLifetime(retainedBox) {}
    }

    deinit { stop() }

    private static func nearestExistingAncestor(of url: URL) -> URL {
        let manager = FileManager.default
        var candidate = url.standardizedFileURL
        while candidate.path != "/", !manager.fileExists(atPath: candidate.path) {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    static func classify(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        roots: [SessionObservationRoot]
    ) -> SessionCatalogChange {
        var change = SessionCatalogChange()
        let count = min(paths.count, flags.count)
        for index in 0..<count {
            let path = URL(fileURLWithPath: paths[index]).standardizedFileURL.path
            let flag = flags[index]
            if flag & (
                FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
            ) != 0 {
                change.requiresFullScan = true
                continue
            }
            let topology = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
                | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
                | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
                | FSEventStreamEventFlags(kFSEventStreamEventFlagItemCloned)
            let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
            guard flag & (topology | modified) != 0,
                  let root = roots.sorted(by: { $0.url.path.count > $1.url.path.count }).first(where: {
                    path == $0.url.path || path.hasPrefix($0.url.path + "/")
                  }) else { continue }

            if let exact = root.exactFilePath {
                guard path == exact else { continue }
                if flag & modified != 0
                    || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
                    change.activityPaths.insert(path)
                }
                guard flag & topology != 0 else { continue }
                change.candidatePaths.insert(path)
                if flag & (
                    FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
                ) != 0 {
                    change.requiresFullScan = true
                }
                continue
            }

            let relative = String(path.dropFirst(root.url.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = relative.split(separator: "/")
            let descriptor = AgentCatalog.descriptor(for: root.agent)
            guard components.count <= descriptor.sessionScanDepth + 1 else { continue }

            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                if flag & (
                    FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemCloned)
                ) != 0 {
                    change.requiresFullScan = true
                }
                continue
            }
            guard path.lowercased().hasSuffix(".jsonl") else { continue }
            if let prefix = descriptor.sessionFilePrefix,
               !URL(fileURLWithPath: path).lastPathComponent.hasPrefix(prefix) {
                continue
            }
            if flag & modified != 0 || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
                change.activityPaths.insert(path)
            }
            guard flag & topology != 0 else { continue }
            change.candidatePaths.insert(path)
            if flag & (
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
            ) != 0 {
                change.requiresFullScan = true
            }
        }
        return change
    }
}
