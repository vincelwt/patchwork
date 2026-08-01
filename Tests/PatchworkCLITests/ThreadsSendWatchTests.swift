import XCTest
@testable import PatchworkCLI

final class ThreadsSendTests: XCTestCase {
    func testRequiresIdAndText() async {
        let result = await runCLI(["threads", "send"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func testDefaultDeliveryIsAuto() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["threads", "send", "t1", "hello"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.lastSendMessageRequest?.delivery, "auto")
        XCTAssertEqual(plane.lastSendMessageRequest?.attachments, [])
    }

    func testSteerFlagSetsSteerDelivery() async {
        let plane = FakeControlPlane()
        _ = await runCLI(["threads", "send", "t1", "hello", "--steer"], controlPlane: plane)
        XCTAssertEqual(plane.lastSendMessageRequest?.delivery, "steer")
    }

    func testFollowUpFlagSetsFollowUpDelivery() async {
        let plane = FakeControlPlane()
        _ = await runCLI(["threads", "send", "t1", "hello", "--follow-up"], controlPlane: plane)
        XCTAssertEqual(plane.lastSendMessageRequest?.delivery, "followUp")
    }

    func testSteerAndFollowUpTogetherIsBadUsage() async {
        let result = await runCLI(["threads", "send", "t1", "hello", "--steer", "--follow-up"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func testDashReadsTextFromStdin() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["threads", "send", "t1", "-"], controlPlane: plane, stdin: Data("from stdin".utf8))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.lastSendMessageRequest?.text, "from stdin")
    }

    func testEmptyMessageIsRejected() async {
        let result = await runCLI(["threads", "send", "t1", ""])
        XCTAssertEqual(result.exitCode, 2)
    }

    func testUnquotedMultiWordMessageIsTooManyPositionals() async {
        // A common mistake: forgetting to quote the message. Must fail cleanly, not silently join.
        let result = await runCLI(["threads", "send", "t1", "hello", "world"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func testWithoutWaitReportsRunIdImmediately() async {
        let plane = FakeControlPlane()
        plane.sendMessageResult = WireSendMessageResponse(runId: "run_1", queued: false)
        let result = await runCLI(["threads", "send", "t1", "hello", "--json"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.calls.map(\.method), ["sendMessage"]) // no events() call without --wait
        let decoded = try? JSONDecoder().decode(WireSendMessageWithRunResponse.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded?.runId, "run_1")
        XCTAssertNil(decoded?.run)
    }

    func testWaitSucceedsWhenRunReachesOk() async throws {
        let plane = FakeControlPlane()
        plane.sendMessageResult = WireSendMessageResponse(runId: "run_1", queued: false)
        plane.eventsToEmit = [
            ControlPlaneEvent(name: "run", data: .object(["id": .string("run_1"), "status": .string("running")])),
            ControlPlaneEvent(name: "run", data: .object(["id": .string("run_1"), "status": .string("ok"), "summary": .string("done")]))
        ]
        let result = await runCLI(["threads", "send", "t1", "hello", "--wait", "--json"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        // The "waiting..." progress line must not land on stdout and corrupt the JSON.
        let decoded = try JSONDecoder().decode(WireSendMessageWithRunResponse.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.run?.status, "ok")
        XCTAssertTrue(result.stderr.contains("Waiting for run"))
    }

    func testWaitProgressTextNeverPollutesJSONStdout() async throws {
        // threads send --json prints one pretty-printed (multi-line) JSON document, so the
        // regression to guard against is stray text breaking that document, not line count.
        let plane = FakeControlPlane()
        plane.sendMessageResult = WireSendMessageResponse(runId: "run_1", queued: false)
        plane.eventsToEmit = [ControlPlaneEvent(name: "run", data: .object(["id": .string("run_1"), "status": .string("ok")]))]
        let result = await runCLI(["threads", "send", "t1", "hello", "--wait", "--json"], controlPlane: plane)
        XCTAssertFalse(result.stdout.contains("Waiting for run"))
        _ = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) // throws if anything else snuck in
    }

    func testWaitFailsWhenRunFails() async {
        let plane = FakeControlPlane()
        plane.sendMessageResult = WireSendMessageResponse(runId: "run_1", queued: false)
        plane.eventsToEmit = [
            ControlPlaneEvent(name: "run", data: .object(["id": .string("run_1"), "status": .string("failed"), "error": .string("boom")]))
        ]
        let result = await runCLI(["threads", "send", "t1", "hello", "--wait"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("failed"))
    }

    func testWaitIgnoresEventsForOtherRuns() async {
        let plane = FakeControlPlane()
        plane.sendMessageResult = WireSendMessageResponse(runId: "run_2", queued: false)
        plane.eventsToEmit = [
            ControlPlaneEvent(name: "run", data: .object(["id": .string("run_other"), "status": .string("ok")])),
            ControlPlaneEvent(name: "run", data: .object(["id": .string("run_2"), "status": .string("ok")]))
        ]
        let result = await runCLI(["threads", "send", "t1", "hello", "--wait"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testWaitFailsCleanlyWhenStreamEndsBeforeTerminalStatus() async {
        let plane = FakeControlPlane()
        plane.sendMessageResult = WireSendMessageResponse(runId: "run_1", queued: false)
        plane.eventsToEmit = [] // stream ends immediately
        let result = await runCLI(["threads", "send", "t1", "hello", "--wait"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("run_1"))
    }
}

final class ThreadsWatchTests: XCTestCase {
    func testWatchPrintsOneJSONObjectPerLine() async {
        let plane = FakeControlPlane()
        plane.eventsToEmit = [
            ControlPlaneEvent(name: "thread", data: .object(["id": .string("t1")])),
            ControlPlaneEvent(name: "run", data: .object(["id": .string("r1"), "threadId": .string("t1")]))
        ]
        let result = await runCLI(["threads", "watch", "--json"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let decoded = try? JSONDecoder().decode(WatchEventLine.self, from: Data(line.utf8))
            XCTAssertNotNil(decoded)
        }
        // The "watching..." progress line belongs on stderr, never mixed into the NDJSON stream.
        XCTAssertTrue(result.stderr.contains("Watching for events"))
    }

    func testWatchFiltersByThreadIdWhenGiven() async {
        let plane = FakeControlPlane()
        plane.eventsToEmit = [
            ControlPlaneEvent(name: "thread", data: .object(["id": .string("t1")])),
            ControlPlaneEvent(name: "thread", data: .object(["id": .string("t2")])),
            ControlPlaneEvent(name: "run", data: .object(["id": .string("r1"), "threadId": .string("t1")]))
        ]
        let result = await runCLI(["threads", "watch", "t1", "--json"], controlPlane: plane)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
    }

    func testWatchAlwaysPassesThroughActivityEvents() async {
        let plane = FakeControlPlane()
        plane.eventsToEmit = [ControlPlaneEvent(name: "activity", data: .object(["unreadCount": .number(2)]))]
        let result = await runCLI(["threads", "watch", "some-other-thread", "--json"], controlPlane: plane)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1)
    }

    func testWatchSurfacesStreamErrorAsRequestFailed() async {
        let plane = FakeControlPlane()
        plane.eventsError = FakeError("connection reset")
        let result = await runCLI(["threads", "watch"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 1)
    }

    func testWatchTooManyPositionalsIsBadUsage() async {
        let result = await runCLI(["threads", "watch", "t1", "t2"])
        XCTAssertEqual(result.exitCode, 2)
    }
}
