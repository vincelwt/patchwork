import Foundation

struct RuntimeEventTarget {
    let revision: Int
    let handler: ((PiJSONValue) -> Void)?
}

/// A bounded bridge from the runtime IO queue to the main queue. Streaming adapters publish the
/// complete message accumulated so far, so retaining only the newest update for one message is
/// lossless and prevents a fast token stream from scheduling thousands of main-queue blocks.
final class RuntimeEventMailbox: @unchecked Sendable {
    typealias Scheduler = @Sendable (@escaping @Sendable () -> Void) -> Void

    private struct Entry {
        let generation: RuntimeGeneration
        let target: RuntimeEventTarget
        var event: PiJSONValue
        var sourceBytes: Int
        let coalescingKey: String?
    }

    private let lock = NSLock()
    private let maximumRetainedEvents: Int
    private let maximumSourceBytes: Int
    private let deliveryBatchSize: Int
    private let schedule: Scheduler
    private var entries: [Entry] = []
    private var retainedSourceBytes = 0
    private var deliveryScheduled = false

    init(
        maximumRetainedEvents: Int = 512,
        maximumSourceBytes: Int = 16 * 1_024 * 1_024,
        deliveryBatchSize: Int = 64,
        schedule: @escaping Scheduler = { work in DispatchQueue.main.async(execute: work) }
    ) {
        self.maximumRetainedEvents = max(1, maximumRetainedEvents)
        self.maximumSourceBytes = max(1, maximumSourceBytes)
        self.deliveryBatchSize = max(1, deliveryBatchSize)
        self.schedule = schedule
    }

    @discardableResult
    func enqueue(
        _ event: PiJSONValue,
        sourceBytes: Int,
        generation: RuntimeGeneration,
        target: RuntimeEventTarget
    ) -> Bool {
        guard target.handler != nil else { return true }
        let admittedAndSchedule = lock.withLock { () -> (Bool, Bool) in
            let bytes = max(0, sourceBytes)
            let key = Self.coalescingKey(for: event)
            if let last = entries.indices.last,
               entries[last].generation === generation,
               entries[last].target.revision == target.revision,
               let key, entries[last].coalescingKey == key {
                let previousBytes = entries[last].sourceBytes
                guard bytes <= maximumSourceBytes,
                      retainedSourceBytes - previousBytes <= maximumSourceBytes - bytes else {
                    return (false, false)
                }
                entries[last].event = event
                entries[last].sourceBytes = bytes
                retainedSourceBytes = retainedSourceBytes - previousBytes + bytes
                return (true, false)
            }

            guard entries.count < maximumRetainedEvents,
                  bytes <= maximumSourceBytes,
                  retainedSourceBytes <= maximumSourceBytes - bytes else {
                return (false, false)
            }
            entries.append(Entry(
                generation: generation,
                target: target,
                event: event,
                sourceBytes: bytes,
                coalescingKey: key
            ))
            retainedSourceBytes += bytes
            guard !deliveryScheduled else { return (true, false) }
            deliveryScheduled = true
            return (true, true)
        }
        if admittedAndSchedule.1 { scheduleDrain() }
        return admittedAndSchedule.0
    }

    func reset() {
        lock.withLock {
            entries.removeAll(keepingCapacity: false)
            retainedSourceBytes = 0
            deliveryScheduled = false
        }
    }

    var retainedEventCount: Int { lock.withLock { entries.count } }
    var retainedByteCount: Int { lock.withLock { retainedSourceBytes } }

    private func scheduleDrain() {
        schedule { [weak self] in self?.drain() }
    }

    private func drain() {
        let batch = lock.withLock { () -> [Entry] in
            let count = min(deliveryBatchSize, entries.count)
            guard count > 0 else {
                deliveryScheduled = false
                return []
            }
            let batch = Array(entries.prefix(count))
            entries.removeFirst(count)
            retainedSourceBytes = max(0, retainedSourceBytes - batch.reduce(0) { $0 + $1.sourceBytes })
            return batch
        }

        for entry in batch where entry.generation.isValid {
            entry.target.handler?(entry.event)
        }

        let continueDraining = lock.withLock { () -> Bool in
            if entries.isEmpty {
                deliveryScheduled = false
                return false
            }
            return true
        }
        if continueDraining { scheduleDrain() }
    }

    private static func coalescingKey(for event: PiJSONValue) -> String? {
        guard event["type"]?.stringValue == "message_update",
              let id = event["message"]?["id"]?.stringValue,
              !id.isEmpty else { return nil }
        return "message_update:\(id)"
    }
}
