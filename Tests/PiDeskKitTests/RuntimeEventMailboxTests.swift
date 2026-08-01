import XCTest
@testable import PiDeskKit

final class RuntimeEventMailboxTests: XCTestCase {
    func testTenThousandMessageUpdatesCollapseToTheNewestPayloadInOneDelivery() {
        let scheduler = ManualScheduler()
        let mailbox = RuntimeEventMailbox(schedule: scheduler.schedule)
        let generation = RuntimeGeneration(sequence: 1)
        var delivered: [PiJSONValue] = []
        let target = RuntimeEventTarget(revision: 1) { delivered.append($0) }

        XCTAssertTrue(mailbox.enqueue(event("message_start", id: "answer"), sourceBytes: 20, generation: generation, target: target))
        for index in 0..<10_000 {
            XCTAssertTrue(mailbox.enqueue(
                event("message_update", id: "answer", text: "token-\(index)"),
                sourceBytes: 20,
                generation: generation,
                target: target
            ))
        }
        XCTAssertTrue(mailbox.enqueue(event("message_end", id: "answer"), sourceBytes: 20, generation: generation, target: target))

        XCTAssertEqual(mailbox.retainedEventCount, 3)
        XCTAssertEqual(scheduler.count, 1)
        scheduler.runAll()
        XCTAssertEqual(delivered.compactMap { $0["type"]?.stringValue }, ["message_start", "message_update", "message_end"])
        XCTAssertEqual(
            delivered[1]["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue,
            "token-9999"
        )
        XCTAssertEqual(mailbox.retainedEventCount, 0)
    }

    func testTerminalBoundariesPreventUpdatesFromCoalescingAcrossThem() {
        let scheduler = ManualScheduler()
        let mailbox = RuntimeEventMailbox(schedule: scheduler.schedule)
        let generation = RuntimeGeneration(sequence: 2)
        var types: [String] = []
        let target = RuntimeEventTarget(revision: 1) { value in
            if let type = value["type"]?.stringValue { types.append(type) }
        }

        XCTAssertTrue(mailbox.enqueue(event("message_update", id: "a", text: "one"), sourceBytes: 1, generation: generation, target: target))
        XCTAssertTrue(mailbox.enqueue(event("message_end", id: "a"), sourceBytes: 1, generation: generation, target: target))
        XCTAssertTrue(mailbox.enqueue(event("message_update", id: "a", text: "two"), sourceBytes: 1, generation: generation, target: target))
        scheduler.runAll()

        XCTAssertEqual(types, ["message_update", "message_end", "message_update"])
    }

    func testMailboxRejectsNewSemanticEventsAtItsExplicitBound() {
        let scheduler = ManualScheduler()
        let mailbox = RuntimeEventMailbox(
            maximumRetainedEvents: 2,
            maximumSourceBytes: 10,
            schedule: scheduler.schedule
        )
        let generation = RuntimeGeneration(sequence: 3)
        let target = RuntimeEventTarget(revision: 1) { _ in }

        XCTAssertTrue(mailbox.enqueue(event("turn_start", id: "a"), sourceBytes: 4, generation: generation, target: target))
        XCTAssertTrue(mailbox.enqueue(event("tool_execution_start", id: "b"), sourceBytes: 4, generation: generation, target: target))
        XCTAssertFalse(mailbox.enqueue(event("turn_end", id: "c"), sourceBytes: 1, generation: generation, target: target))
        XCTAssertEqual(mailbox.retainedEventCount, 2)
        XCTAssertEqual(mailbox.retainedByteCount, 8)
    }

    private func event(_ type: String, id: String, text: String? = nil) -> PiJSONValue {
        var message: [String: PiJSONValue] = [
            "id": .string(id),
            "role": .string("assistant")
        ]
        if let text {
            message["content"] = .array([.object(["type": .string("text"), "text": .string(text)])])
        }
        return AdapterEncoding.event(type, ["message": .object(message)])
    }
}

private final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [@Sendable () -> Void] = []

    var schedule: RuntimeEventMailbox.Scheduler {
        { [weak self] block in self?.lock.withLock { self?.work.append(block) } }
    }

    var count: Int { lock.withLock { work.count } }

    func runAll() {
        while true {
            let next = lock.withLock { work.isEmpty ? nil : work.removeFirst() }
            guard let next else { return }
            next()
        }
    }
}
