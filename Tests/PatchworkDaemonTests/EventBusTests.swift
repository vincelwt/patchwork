import Foundation
import XCTest
@testable import PatchworkDaemon

final class EventBusTests: XCTestCase {
    func testInitialReadyFramePrecedesSubsequentPublication() {
        let bus = EventBus()
        let delivered = LockedNames()
        let expectation = expectation(description: "ready and thread delivered")
        expectation.expectedFulfillmentCount = 2

        _ = bus.subscribe(initialName: "ready", initialPayload: Data("{}".utf8)) { name, _ in
            delivered.append(name)
            expectation.fulfill()
        }
        bus.publish(.unknown(name: "thread", data: .object(["id": .string("t1")])))

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(delivered.values, ["ready", "thread"])
    }

    func testOverflowDisconnectCallbackRunsInsteadOfSilentlyDropping() {
        let bus = EventBus(maxPendingPerSubscriber: 1)
        let releaseDelivery = DispatchSemaphore(value: 0)
        let deliveryStarted = expectation(description: "delivery started")
        let deliveryFinished = expectation(description: "delivery finished")
        let overflowed = expectation(description: "overflow callback")
        let unexpectedDelivery = expectation(description: "no delivery after overflow")
        unexpectedDelivery.isInverted = true
        let callbackCount = LockedCounter()
        let delivered = LockedNames()

        let id = bus.subscribe(onOverflow: {
            if callbackCount.increment() == 1 { overflowed.fulfill() }
        }) { name, _ in
            delivered.append(name)
            guard name == "first" else {
                unexpectedDelivery.fulfill()
                return
            }
            deliveryStarted.fulfill()
            releaseDelivery.wait()
            deliveryFinished.fulfill()
        }
        bus.publish(.unknown(name: "first", data: .object([:])))
        wait(for: [deliveryStarted], timeout: 2)
        bus.publish(.unknown(name: "second", data: .object([:])))
        wait(for: [overflowed], timeout: 2)
        bus.publish(.unknown(name: "third", data: .object([:])))
        releaseDelivery.signal()
        wait(for: [deliveryFinished], timeout: 2)
        bus.publish(.unknown(name: "fourth", data: .object([:])))
        wait(for: [unexpectedDelivery], timeout: 0.1)

        XCTAssertEqual(callbackCount.value, 1)
        XCTAssertEqual(delivered.values, ["first"])
        bus.unsubscribe(id)
        XCTAssertEqual(bus.subscriberCount, 0)
    }

    func testOverflowedSubscriberCanBeReplacedWithAReadyBarrier() {
        let bus = EventBus(maxPendingPerSubscriber: 1)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstStarted = expectation(description: "first delivery started")
        let firstFinished = expectation(description: "first delivery finished")
        let replaced = expectation(description: "replacement installed")
        let replacementDelivered = expectation(description: "replacement ready and event")
        replacementDelivered.expectedFulfillmentCount = 2
        let replacementNames = LockedNames()

        let originalID = bus.subscribe(onOverflow: {
            _ = bus.subscribe(
                initialName: "ready", initialPayload: Data("{}".utf8)
            ) { name, _ in
                replacementNames.append(name)
                replacementDelivered.fulfill()
            }
            replaced.fulfill()
        }) { _, _ in
            firstStarted.fulfill()
            releaseFirst.wait()
            firstFinished.fulfill()
        }

        bus.publish(.unknown(name: "first", data: .object([:])))
        wait(for: [firstStarted], timeout: 2)
        bus.publish(.unknown(name: "overflow", data: .object([:])))
        wait(for: [replaced], timeout: 2)
        bus.publish(.unknown(name: "after", data: .object([:])))
        wait(for: [replacementDelivered], timeout: 2)
        releaseFirst.signal()
        wait(for: [firstFinished], timeout: 2)

        XCTAssertEqual(replacementNames.values, ["ready", "after"])
        bus.unsubscribe(originalID)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
