import Foundation
import XCTest
@testable import PiDesktop

final class OutboxPolicyTests: XCTestCase {
    private func entry(_ text: String, _ delivery: OutboxEntry.Delivery) -> OutboxEntry {
        OutboxEntry(text: text, delivery: delivery)
    }

    func testQueuedMessagesKeepTheirOrderAndStayBounded() {
        var entries: [OutboxEntry] = []
        for index in 0..<(OutboxPolicy.limit + 5) {
            entries = OutboxPolicy.append(entry("m\(index)", .steer), to: entries)
        }
        XCTAssertEqual(entries.count, OutboxPolicy.limit, "a runaway loop must not stack messages forever")
        XCTAssertEqual(entries.first?.text, "m5", "the oldest are dropped, newest kept")
        XCTAssertEqual(entries.last?.text, "m\(OutboxPolicy.limit + 4)")
    }

    func testEachBoundaryOnlyFlushesItsOwnMessages() {
        let entries = [
            entry("steer one", .steer),
            entry("later", .followUp),
            entry("steer two", .steer)
        ]
        XCTAssertEqual(OutboxPolicy.due(entries, at: .steer).map(\.text), ["steer one", "steer two"])
        XCTAssertEqual(OutboxPolicy.due(entries, at: .followUp).map(\.text), ["later"])
        XCTAssertEqual(OutboxPolicy.removing(.steer, from: entries).map(\.text), ["later"])
        XCTAssertEqual(OutboxPolicy.removing(.followUp, from: entries).map(\.text), ["steer one", "steer two"])
    }
}
