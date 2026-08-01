import XCTest
import PatchworkKit
@testable import PatchworkDaemon

final class ActivityPublisherTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ActivitySnapshot] = []

        func append(_ value: ActivitySnapshot) {
            lock.lock(); values.append(value); lock.unlock()
        }

        func snapshot() -> [ActivitySnapshot] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    actor Fixture {
        var value = ActivitySnapshot(running: [], unreadCount: 0, observedAt: .distantPast)

        func snapshot() -> ActivitySnapshot { value }
        func set(_ value: ActivitySnapshot) { self.value = value }
    }

    func testPublishesOnlySemanticActivityChanges() async throws {
        let bus = EventBus()
        let fixture = Fixture()
        let publisher = ActivityPublisher(bus: bus) { await fixture.snapshot() }
        let delivered = expectation(description: "activity changes")
        delivered.expectedFulfillmentCount = 2
        let collector = Collector()
        let subscription = bus.subscribe { name, payload in
            guard name == "activity",
                  let value = try? PatchworkJSON.decoder.decode(ActivitySnapshot.self, from: payload) else { return }
            collector.append(value)
            delivered.fulfill()
        }
        defer { bus.unsubscribe(subscription) }

        let publishedInitial = await publisher.publishIfChanged()
        XCTAssertTrue(publishedInitial)
        await fixture.set(ActivitySnapshot(running: [], unreadCount: 0, observedAt: Date()))
        let publishedTimestamp = await publisher.publishIfChanged()
        XCTAssertFalse(publishedTimestamp, "observedAt alone is not a state change")
        await fixture.set(ActivitySnapshot(
            running: [RunningThread(
                threadId: "thread", threadPath: "/tmp/thread.jsonl",
                since: Date(timeIntervalSince1970: 10), source: .terminal
            )],
            unreadCount: 1,
            observedAt: Date()
        ))
        let publishedChange = await publisher.publishIfChanged()
        XCTAssertTrue(publishedChange)

        await fulfillment(of: [delivered], timeout: 1)
        let received = collector.snapshot()
        XCTAssertEqual(received.map(\.unreadCount), [0, 1])
        XCTAssertEqual(received.last?.running.first?.threadPath, "/tmp/thread.jsonl")
    }
}
