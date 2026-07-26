import XCTest
@testable import PiDeskCLI

final class SSEParserTests: XCTestCase {
    func testSingleEvent() {
        var parser = SSEParser()
        var events: [ControlPlaneEvent] = []
        for line in ["event: thread", "data: {\"id\":\"t1\",\"name\":\"Nightly\"}", ""] {
            if let event = parser.feed(line) { events.append(event) }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].name, "thread")
        XCTAssertEqual(events[0].data["id"]?.stringValue, "t1")
    }

    func testMultipleEventsInSequence() {
        var parser = SSEParser()
        var events: [ControlPlaneEvent] = []
        let lines = [
            "event: run", "data: {\"id\":\"r1\",\"status\":\"running\"}", "",
            "event: run", "data: {\"id\":\"r1\",\"status\":\"ok\"}", ""
        ]
        for line in lines { if let event = parser.feed(line) { events.append(event) } }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].data["status"]?.stringValue, "ok")
    }

    func testKeepAliveCommentIsIgnored() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(": keep-alive"))
        var events: [ControlPlaneEvent] = []
        for line in ["event: activity", "data: {\"unreadCount\":2}", ""] {
            if let event = parser.feed(line) { events.append(event) }
        }
        XCTAssertEqual(events.count, 1)
    }

    func testMultiLineDataIsJoinedWithNewlines() {
        var parser = SSEParser()
        var event: ControlPlaneEvent?
        for line in ["event: thread", "data: {\"id\":\"t1\",", "data: \"name\":\"Nightly\"}", ""] {
            if let value = parser.feed(line) { event = value }
        }
        XCTAssertEqual(event?.data["name"]?.stringValue, "Nightly")
    }

    func testUnknownEventNameIsPassedThrough() {
        var parser = SSEParser()
        var event: ControlPlaneEvent?
        for line in ["event: futureEventKind", "data: {}", ""] {
            if let value = parser.feed(line) { event = value }
        }
        XCTAssertEqual(event?.name, "futureEventKind")
    }

    func testMissingEventNameDefaultsToMessage() {
        var parser = SSEParser()
        var event: ControlPlaneEvent?
        for line in ["data: {\"id\":\"t1\"}", ""] {
            if let value = parser.feed(line) { event = value }
        }
        XCTAssertEqual(event?.name, "message")
    }

    func testMalformedJSONDataIsDroppedNotThrown() {
        var parser = SSEParser()
        var events: [ControlPlaneEvent] = []
        for line in ["event: thread", "data: not json", ""] {
            if let value = parser.feed(line) { events.append(value) }
        }
        XCTAssertTrue(events.isEmpty)
    }

    func testStreamSurvivesAMalformedEventAndContinues() {
        var parser = SSEParser()
        var events: [ControlPlaneEvent] = []
        let lines = [
            "event: thread", "data: not json", "",
            "event: thread", "data: {\"id\":\"t2\"}", ""
        ]
        for line in lines { if let event = parser.feed(line) { events.append(event) } }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data["id"]?.stringValue, "t2")
    }

    func testIgnoredFieldsLikeIdAndRetryDoNotBreakParsing() {
        var parser = SSEParser()
        var event: ControlPlaneEvent?
        for line in ["id: 42", "retry: 3000", "event: thread", "data: {\"id\":\"t1\"}", ""] {
            if let value = parser.feed(line) { event = value }
        }
        XCTAssertEqual(event?.name, "thread")
    }
}
