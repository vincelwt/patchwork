import Foundation
import PiDeskKit
import XCTest
@testable import PiDesktop

private actor LeaseOperationGate {
    struct Call: Equatable {
        let path: String
        let release: Bool
        let owner: String
    }

    private var calls: [Call] = []
    private var blockNextAcquire = false
    private var acquireWaiter: CheckedContinuation<Void, Never>?

    func blockAcquire() { blockNextAcquire = true }

    func perform(path: String, request: LeaseRequest) async throws -> LeaseResponse {
        calls.append(Call(path: path, release: request.release == true, owner: request.owner))
        if request.release != true, blockNextAcquire {
            blockNextAcquire = false
            await withCheckedContinuation { acquireWaiter = $0 }
        }
        return LeaseResponse(
            leased: request.release != true,
            owner: request.release == true ? nil : request.owner,
            expiresAt: request.release == true ? nil : Date().addingTimeInterval(60)
        )
    }

    func releaseAcquire() {
        acquireWaiter?.resume()
        acquireWaiter = nil
    }

    func snapshot() -> [Call] { calls }
}

@MainActor
final class RuntimeLeaseCoordinatorTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    func testCloseWaitsBehindAnInFlightAcquireAndCannotResurrectTheLease() async {
        let gate = LeaseOperationGate()
        await gate.blockAcquire()
        let coordinator = RuntimeLeaseCoordinator { path, request in
            try await gate.perform(path: path, request: request)
        }
        let acquisition = Task { @MainActor in
            do {
                try await coordinator.acquire(path: "/tmp/thread.jsonl")
                return false
            } catch {
                return true
            }
        }
        let began = await waitUntil { await gate.snapshot().count == 1 }
        XCTAssertTrue(began)

        coordinator.close()
        await gate.releaseAcquire()

        let acquisitionFailed = await acquisition.value
        XCTAssertTrue(acquisitionFailed)
        let released = await waitUntil { await gate.snapshot().count == 2 }
        XCTAssertTrue(released)
        let calls = await gate.snapshot()
        XCTAssertEqual(calls.map(\.release), [false, true])
        XCTAssertEqual(Set(calls.map(\.owner)).count, 1)
    }

    func testSuccessfulSwitchAcquiresTheNewPathBeforeReleasingTheOldPath() async throws {
        let gate = LeaseOperationGate()
        let coordinator = RuntimeLeaseCoordinator { path, request in
            try await gate.perform(path: path, request: request)
        }

        try await coordinator.acquire(path: "/tmp/a.jsonl")
        try await coordinator.acquire(path: "/tmp/b.jsonl")
        coordinator.retainOnly(path: "/tmp/b.jsonl")

        let released = await waitUntil { await gate.snapshot().count == 3 }
        XCTAssertTrue(released)
        let calls = await gate.snapshot()
        XCTAssertEqual(calls.map(\.path), ["/tmp/a.jsonl", "/tmp/b.jsonl", "/tmp/a.jsonl"])
        XCTAssertEqual(calls.map(\.release), [false, false, true])
        XCTAssertTrue(coordinator.owns(path: "/tmp/b.jsonl"))
        coordinator.close()
    }
}
