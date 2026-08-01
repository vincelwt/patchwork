import Foundation
import XCTest
@testable import Patchwork

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

    func testAggregateSamplerIncludesAppAndDescendantProcessesWithoutRunningThreads() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let snapshot = ProcessResourceSampler.sample(
            rootsByPath: [:],
            previous: [:],
            aggregateRoots: [pid]
        )

        XCTAssertTrue(snapshot.usageByPath.isEmpty)
        XCTAssertNotNil(snapshot.samples[pid])
        XCTAssertNotNil(snapshot.samples[child.processIdentifier])
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.aggregateUsage).memoryBytes, 0)
    }
}
