import Darwin
import Foundation

struct ThreadResourceUsage: Equatable, Sendable {
    var cpuPercent: Double
    var memoryBytes: UInt64

    static func sum(_ values: [Self]) -> Self? {
        guard !values.isEmpty else { return nil }
        return values.reduce(into: Self(cpuPercent: 0, memoryBytes: 0)) { total, value in
            total.cpuPercent += value.cpuPercent
            let bytes = total.memoryBytes.addingReportingOverflow(value.memoryBytes)
            total.memoryBytes = bytes.overflow ? .max : bytes.partialValue
        }
    }
}

struct ProcessResourceSample: Equatable, Sendable {
    var cpuNanoseconds: UInt64
    var memoryBytes: UInt64
    var sampledAt: Date
}

/// Samples a live Pi process and its descendants with libproc. CPU is the change in cumulative
/// process time since the previous poll; memory is the current physical footprint.
enum ProcessResourceSampler {
    static let maxProcessesPerThread = 1_024

    static func sample(
        rootsByPath: [String: Set<Int32>],
        previous: [Int32: ProcessResourceSample],
        now: Date = Date()
    ) -> (usageByPath: [String: ThreadResourceUsage], samples: [Int32: ProcessResourceSample]) {
        var processIDsByPath: [String: Set<Int32>] = [:]
        for (path, roots) in rootsByPath {
            var ids: Set<Int32> = []
            for root in roots.sorted() {
                for pid in descendants(including: root) where ids.count < maxProcessesPerThread {
                    ids.insert(pid)
                }
                if ids.count == maxProcessesPerThread { break }
            }
            processIDsByPath[path] = ids
        }

        let allProcessIDs = Set(processIDsByPath.values.flatMap { $0 })
        let samples = Dictionary(uniqueKeysWithValues: allProcessIDs.compactMap { pid in
            taskSample(pid: pid, at: now).map { (pid, $0) }
        })
        return (usage(processIDsByPath: processIDsByPath, current: samples, previous: previous), samples)
    }

    static func usage(
        processIDsByPath: [String: Set<Int32>],
        current: [Int32: ProcessResourceSample],
        previous: [Int32: ProcessResourceSample]
    ) -> [String: ThreadResourceUsage] {
        processIDsByPath.reduce(into: [:]) { result, entry in
            var cpuPercent = 0.0
            var memoryBytes: UInt64 = 0
            var sampled = false
            for pid in entry.value {
                guard let sample = current[pid] else { continue }
                sampled = true
                let bytes = memoryBytes.addingReportingOverflow(sample.memoryBytes)
                memoryBytes = bytes.overflow ? .max : bytes.partialValue
                guard let old = previous[pid], sample.cpuNanoseconds >= old.cpuNanoseconds else { continue }
                let elapsed = sample.sampledAt.timeIntervalSince(old.sampledAt)
                guard elapsed > 0 else { continue }
                cpuPercent += Double(sample.cpuNanoseconds - old.cpuNanoseconds) / 1_000_000_000 / elapsed * 100
            }
            if sampled {
                result[entry.key] = ThreadResourceUsage(cpuPercent: cpuPercent, memoryBytes: memoryBytes)
            }
        }
    }

    private static func descendants(including root: Int32) -> [Int32] {
        guard root > 0 else { return [] }
        var seen: Set<Int32> = [root]
        var queue: [Int32] = [root]
        var cursor = 0
        var children = [pid_t](repeating: 0, count: maxProcessesPerThread)
        while cursor < queue.count, queue.count < maxProcessesPerThread {
            let parent = queue[cursor]
            cursor += 1
            let count = children.withUnsafeMutableBytes {
                proc_listchildpids(parent, $0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { continue }
            for child in children.prefix(min(Int(count), children.count)) where child > 0 {
                if seen.insert(child).inserted { queue.append(child) }
                if queue.count == maxProcessesPerThread { break }
            }
        }
        return queue
    }

    private static func taskSample(pid: Int32, at date: Date) -> ProcessResourceSample? {
        var info = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard read == 0 else { return nil }
        let cpu = info.ri_user_time.addingReportingOverflow(info.ri_system_time)
        return ProcessResourceSample(
            cpuNanoseconds: cpu.overflow ? .max : cpu.partialValue,
            memoryBytes: info.ri_phys_footprint,
            sampledAt: date
        )
    }
}
