import XCTest
@testable import PiDesktop

final class ProcessResourceSamplerTests: XCTestCase {
    func testLiveSamplerReadsTheCurrentProcess() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let snapshot = ProcessResourceSampler.sample(rootsByPath: ["thread": [pid]], previous: [:])

        XCTAssertNotNil(snapshot.samples[pid])
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.usageByPath["thread"]).memoryBytes, 0)
    }

    func testUsageSumsProcessTreeCPUAndMemory() throws {
        let before = Date(timeIntervalSince1970: 10)
        let after = before.addingTimeInterval(2)
        let previous: [Int32: ProcessResourceSample] = [
            1: ProcessResourceSample(cpuNanoseconds: 1_000_000_000, memoryBytes: 0, sampledAt: before),
            2: ProcessResourceSample(cpuNanoseconds: 2_000_000_000, memoryBytes: 0, sampledAt: before)
        ]
        let current: [Int32: ProcessResourceSample] = [
            1: ProcessResourceSample(cpuNanoseconds: 2_000_000_000, memoryBytes: 100, sampledAt: after),
            2: ProcessResourceSample(cpuNanoseconds: 2_500_000_000, memoryBytes: 200, sampledAt: after),
            3: ProcessResourceSample(cpuNanoseconds: 500_000_000, memoryBytes: 50, sampledAt: after)
        ]

        let usage = try XCTUnwrap(ProcessResourceSampler.usage(
            processIDsByPath: ["thread": [1, 2, 3]],
            current: current,
            previous: previous
        )["thread"])

        XCTAssertEqual(usage.cpuPercent, 75, accuracy: 0.001)
        XCTAssertEqual(usage.memoryBytes, 350)
    }

    func testThreadUsageAggregationFeedsTheFooter() throws {
        let total = try XCTUnwrap(ThreadResourceUsage.sum([
            ThreadResourceUsage(cpuPercent: 12.5, memoryBytes: 100),
            ThreadResourceUsage(cpuPercent: 25, memoryBytes: 200)
        ]))

        XCTAssertEqual(total, ThreadResourceUsage(cpuPercent: 37.5, memoryBytes: 300))
        XCTAssertNil(ThreadResourceUsage.sum([]))
    }
}
