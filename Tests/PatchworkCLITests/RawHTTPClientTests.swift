import XCTest
@testable import PatchworkCLI

/// Exercises the hand-rolled transport (RawSocketTransport.swift) against a real Unix domain
/// socket, since it's the one piece of this target that can't be verified through a fake
/// ControlPlane. The server is an in-process, hermetic test double (TestUnixHTTPServer) — this
/// never talks to a real patchworkd.
final class RawHTTPClientTests: XCTestCase {
    func testSimpleJSONResponseWithContentLength() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        try server.start { _ in
            TestUnixHTTPServer.httpResponse(headers: ["Content-Type": "application/json"], body: Data(#"{"ok":true}"#.utf8))
        }

        let client = RawHTTPClient(target: .unixSocket(path: server.socketPath), timeout: 5)
        let response = try await client.perform(method: "GET", path: "/v1/health", headers: [:], body: nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "application/json")
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), #"{"ok":true}"#)
    }

    func testRequestLineAndHeadersAreWellFormed() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        var capturedRequest = ""
        try server.start { request in
            capturedRequest = request
            return TestUnixHTTPServer.httpResponse(body: Data())
        }

        let client = RawHTTPClient(target: .unixSocket(path: server.socketPath), timeout: 5)
        _ = try await client.perform(method: "POST", path: "/v1/threads", headers: ["Content-Type": "application/json"], body: Data(#"{"cwd":"/x"}"#.utf8))

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(capturedRequest.hasPrefix("POST /v1/threads HTTP/1.1\r\n"))
        XCTAssertTrue(capturedRequest.contains("Content-Length: 12\r\n"))
        XCTAssertTrue(capturedRequest.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(capturedRequest.hasSuffix(#"{"cwd":"/x"}"#))
    }

    func testChunkedTransferEncodingIsDecoded() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        try server.start { _ in
            let chunked = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
            return Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8) + Data(chunked.utf8)
        }

        let client = RawHTTPClient(target: .unixSocket(path: server.socketPath), timeout: 5)
        let response = try await client.perform(method: "GET", path: "/v1/health", headers: [:], body: nil)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "hello world")
    }

    func testResponseSplitAcrossMultiplePacketsIsReassembled() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        let bigBody = String(repeating: "x", count: 5000)
        try server.start(writeInChunks: true) { _ in
            TestUnixHTTPServer.httpResponse(body: Data(bigBody.utf8))
        }

        let client = RawHTTPClient(target: .unixSocket(path: server.socketPath), timeout: 5)
        let response = try await client.perform(method: "GET", path: "/v1/health", headers: [:], body: nil)
        XCTAssertEqual(response.body.count, 5000)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), bigBody)
    }

    func testNon2xxStatusMapsToApiErrorThroughControlPlane() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        try server.start { _ in
            TestUnixHTTPServer.httpResponse(status: "404 Not Found", body: Data(#"{"error":{"code":"not_found","message":"no such thread"}}"#.utf8))
        }

        let plane = HTTPControlPlane(target: .unixSocket(path: server.socketPath), token: nil, timeout: 5)
        do {
            _ = try await plane.showThread(id: "missing", messages: 20, offset: 0, includeTools: false)
            XCTFail("expected apiError")
        } catch ControlPlaneError.apiError(let status, let code, let message) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(code, "not_found")
            XCTAssertEqual(message, "no such thread")
        }
    }

    func testSSEStreamIsParsedIntoEvents() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        try server.start(writeInChunks: true) { _ in
            var head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
            head += "event: thread\ndata: {\"id\":\"t1\"}\n\n"
            head += ": keep-alive\n"
            head += "event: run\ndata: {\"id\":\"r1\",\"status\":\"ok\"}\n\n"
            return Data(head.utf8)
        }

        let plane = HTTPControlPlane(target: .unixSocket(path: server.socketPath), token: nil, timeout: 5)
        var events: [ControlPlaneEvent] = []
        do {
            for try await event in plane.events() { events.append(event) }
            XCTFail("an event stream ending without cancellation must be reported")
        } catch ControlPlaneError.transportFailure {
            // Expected after the scripted server closes its long-lived stream.
        }

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].name, "thread")
        XCTAssertEqual(events[0].data["id"]?.stringValue, "t1")
        XCTAssertEqual(events[1].name, "run")
        XCTAssertEqual(events[1].data["status"]?.stringValue, "ok")
    }

    func testPrematureContentLengthEOFIsNotAcceptedAsAResponse() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        try server.start { _ in
            Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort".utf8)
        }

        let client = RawHTTPClient(target: .unixSocket(path: server.socketPath), timeout: 5)
        do {
            _ = try await client.perform(method: "GET", path: "/v1/health", headers: [:], body: nil)
            XCTFail("expected a malformed response")
        } catch ControlPlaneError.malformedResponse(_) {
            // Expected.
        }
    }

    func testSendRetriesATruncatedAcceptedResponseWithTheSameClientID() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        let lock = NSLock()
        var requests: [String] = []
        try server.start(maxRequests: 4) { request in
            lock.withLock { requests.append(request) }
            if request.hasPrefix("GET /v1/health ") {
                return TestUnixHTTPServer.httpResponse(
                    body: Data(#"{"ok":true,"messageSubmissionIdempotency":true}"#.utf8)
                )
            }
            let count = lock.withLock {
                requests.filter { $0.hasPrefix("POST /v1/threads/t1/messages ") }.count
            }
            if count == 1 {
                return Data("HTTP/1.1 200 OK\r\nContent-Length: 200\r\n\r\n{\"runId\":\"run_1\"}".utf8)
            }
            return TestUnixHTTPServer.httpResponse(
                body: Data(#"{"runId":"run_1","queued":false}"#.utf8)
            )
        }

        let plane = HTTPControlPlane(target: .unixSocket(path: server.socketPath), token: nil, timeout: 5)
        let response = try await plane.sendMessage(
            threadId: "t1",
            request: WireSendMessageRequest(
                text: "hello", delivery: "auto", attachments: [], clientId: "stable-client-id"
            )
        )

        XCTAssertEqual(response.runId, "run_1")
        let captured = lock.withLock { requests }
        let posts = captured.filter { $0.hasPrefix("POST /v1/threads/t1/messages ") }
        XCTAssertEqual(posts.count, 2)
        XCTAssertTrue(posts.allSatisfy { $0.contains(#""clientId":"stable-client-id""#) })
        XCTAssertEqual(captured.filter { $0.hasPrefix("GET /v1/health ") }.count, 2)
    }

    func testFinalConnectRefusalDoesNotEraseAnEarlierAmbiguousSend() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        let lock = NSLock()
        var requests: [String] = []
        // Initial health plus three (POST, health) pairs. The fourth POST then fails before
        // connect, after three earlier responses were truncated after acceptance.
        try server.start(maxRequests: 7) { request in
            lock.withLock { requests.append(request) }
            if request.hasPrefix("GET /v1/health ") {
                return TestUnixHTTPServer.httpResponse(
                    body: Data(#"{"ok":true,"messageSubmissionIdempotency":true}"#.utf8)
                )
            }
            return Data(
                "HTTP/1.1 200 OK\r\nContent-Length: 200\r\n\r\n{\"runId\":\"accepted\"}".utf8
            )
        }

        let plane = HTTPControlPlane(
            target: .unixSocket(path: server.socketPath), token: nil, timeout: 1
        )
        do {
            _ = try await plane.sendMessage(
                threadId: "t1",
                request: WireSendMessageRequest(
                    text: "hello", delivery: "auto", attachments: [],
                    clientId: "stable-client-id"
                )
            )
            XCTFail("expected an ambiguous response failure")
        } catch ControlPlaneError.unreachable {
            XCTFail("the final unsent attempt erased an earlier ambiguous acceptance")
        } catch ControlPlaneError.malformedResponse {
            // The earlier ambiguous response remains authoritative for retry guidance.
        } catch {
            XCTFail("expected malformedResponse, got \(error)")
        }

        let posts = lock.withLock {
            requests.filter { $0.hasPrefix("POST /v1/threads/t1/messages ") }
        }
        XCTAssertEqual(posts.count, 3)
        XCTAssertTrue(posts.allSatisfy { $0.contains(#""clientId":"stable-client-id""#) })
    }

    func testSendDoesNotRetryWhenOlderDaemonOmitsMessageCapability() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        let lock = NSLock()
        var requests: [String] = []
        try server.start(maxRequests: 2) { request in
            lock.withLock { requests.append(request) }
            if request.hasPrefix("GET /v1/health ") {
                return TestUnixHTTPServer.httpResponse(body: Data(#"{"ok":true}"#.utf8))
            }
            return Data("HTTP/1.1 200 OK\r\nContent-Length: 200\r\n\r\n{\"runId\":\"run_1\"}".utf8)
        }

        let plane = HTTPControlPlane(target: .unixSocket(path: server.socketPath), token: nil, timeout: 5)
        do {
            _ = try await plane.sendMessage(
                threadId: "t1",
                request: WireSendMessageRequest(
                    text: "hello", delivery: "auto", attachments: [], clientId: "stable-client-id"
                )
            )
            XCTFail("expected an unknown outcome")
        } catch ControlPlaneError.outcomeUnknown {
            // One attempt only. The older daemon did not promise that the id was replay-safe.
        }

        XCTAssertEqual(
            lock.withLock { requests.filter { $0.hasPrefix("POST /v1/threads/t1/messages ") }.count },
            1
        )
    }

    func testProtectedSendPreservesUnreachableWhenNoListenerExists() async {
        let path = NSTemporaryDirectory() + "patchwork-protected-missing-\(UUID().uuidString).sock"
        let plane = HTTPControlPlane(target: .unixSocket(path: path), token: nil, timeout: 0.1)
        do {
            _ = try await plane.sendMessage(
                threadId: "t1",
                request: WireSendMessageRequest(
                    text: "hello", delivery: "auto", attachments: [], clientId: "stable-client-id"
                )
            )
            XCTFail("expected unreachable")
        } catch ControlPlaneError.unreachable {
            // Definitely unsent, so this must retain the daemon-start exit path.
        } catch {
            XCTFail("expected unreachable, got \(error)")
        }
    }

    func testCreateRetriesATruncatedAcceptedResponseWithTheSameClientID() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        let lock = NSLock()
        var requests: [String] = []
        try server.start(maxRequests: 4) { request in
            if request.hasPrefix("GET /v1/health ") {
                lock.withLock { requests.append(request) }
                return TestUnixHTTPServer.httpResponse(
                    body: Data(#"{"ok":true,"threadCreationIdempotency":true}"#.utf8)
                )
            }
            let postCount = lock.withLock {
                requests.append(request)
                return requests.filter { $0.hasPrefix("POST /v1/threads ") }.count
            }
            if postCount == 1 {
                return Data("HTTP/1.1 200 OK\r\nContent-Length: 200\r\n\r\n{\"thread\":{\"id\":\"t1\"}}".utf8)
            }
            return TestUnixHTTPServer.httpResponse(
                body: Data(#"{"thread":{"id":"t1"}}"#.utf8)
            )
        }

        let plane = HTTPControlPlane(target: .unixSocket(path: server.socketPath), token: nil, timeout: 5)
        let response = try await plane.createThread(
            WireCreateThreadRequest(cwd: "/code", clientId: "stable-create-id")
        )

        XCTAssertEqual(response.thread.id, "t1")
        let captured = lock.withLock { requests }
        let posts = captured.filter { $0.hasPrefix("POST /v1/threads ") }
        XCTAssertEqual(posts.count, 2)
        XCTAssertTrue(posts.allSatisfy { $0.contains(#""clientId":"stable-create-id""#) })
        XCTAssertEqual(captured.filter { $0.hasPrefix("GET /v1/health ") }.count, 2)
    }

    func testCreateRetriesServerDeclaredSafeStatesWithTheSameClientID() async throws {
        for code in ["create_retryable", "creation_pending"] {
            let server = TestUnixHTTPServer()
            do {
                defer { server.stop() }
                let lock = NSLock()
                var requests: [String] = []
                try server.start(maxRequests: 4) { request in
                    if request.hasPrefix("GET /v1/health ") {
                        lock.withLock { requests.append(request) }
                        return TestUnixHTTPServer.httpResponse(
                            body: Data(#"{"ok":true,"threadCreationIdempotency":true}"#.utf8)
                        )
                    }
                    let postCount = lock.withLock {
                        requests.append(request)
                        return requests.filter { $0.hasPrefix("POST /v1/threads ") }.count
                    }
                    if postCount == 1 {
                        return TestUnixHTTPServer.httpResponse(
                            status: "503 Service Unavailable",
                            body: Data(
                                #"{"error":{"code":"\#(code)","message":"retry safely"}}"#.utf8
                            )
                        )
                    }
                    return TestUnixHTTPServer.httpResponse(
                        body: Data(#"{"thread":{"id":"t1"}}"#.utf8)
                    )
                }

                let plane = HTTPControlPlane(
                    target: .unixSocket(path: server.socketPath), token: nil, timeout: 5
                )
                let response = try await plane.createThread(
                    WireCreateThreadRequest(cwd: "/code", clientId: "stable-create-id")
                )

                XCTAssertEqual(response.thread.id, "t1", "code: \(code)")
                let posts = lock.withLock {
                    requests.filter { $0.hasPrefix("POST /v1/threads ") }
                }
                XCTAssertEqual(posts.count, 2, "code: \(code)")
                XCTAssertTrue(
                    posts.allSatisfy { $0.contains(#""clientId":"stable-create-id""#) },
                    "code: \(code)"
                )
            }
        }
    }

    func testCreateDoesNotRetryWhenOlderDaemonOmitsCapability() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        let lock = NSLock()
        var requests: [String] = []
        try server.start(maxRequests: 2) { request in
            lock.withLock { requests.append(request) }
            if request.hasPrefix("GET /v1/health ") {
                return TestUnixHTTPServer.httpResponse(body: Data(#"{"ok":true}"#.utf8))
            }
            return Data("HTTP/1.1 200 OK\r\nContent-Length: 200\r\n\r\n{\"thread\":{\"id\":\"t1\"}}".utf8)
        }

        let plane = HTTPControlPlane(target: .unixSocket(path: server.socketPath), token: nil, timeout: 5)
        do {
            _ = try await plane.createThread(
                WireCreateThreadRequest(cwd: "/code", clientId: "stable-create-id")
            )
            XCTFail("expected the one ambiguous response to remain an error")
        } catch ControlPlaneError.outcomeUnknown {
            // Safe: no second creation was attempted against an older daemon.
        }

        let captured = lock.withLock { requests }
        XCTAssertEqual(captured.filter { $0.hasPrefix("POST /v1/threads ") }.count, 1)
    }

    func testManualRunRetriesOnlyWhenTheDaemonAdvertisesReplayProtection() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        let lock = NSLock()
        var requests: [String] = []
        try server.start(maxRequests: 4) { request in
            lock.withLock { requests.append(request) }
            if request.hasPrefix("GET /v1/health ") {
                return TestUnixHTTPServer.httpResponse(
                    body: Data(#"{"ok":true,"scheduleRunIdempotency":true}"#.utf8)
                )
            }
            let postCount = lock.withLock {
                requests.filter { $0.hasPrefix("POST /v1/schedules/s1/run ") }.count
            }
            if postCount == 1 {
                return Data("HTTP/1.1 200 OK\r\nContent-Length: 200\r\n\r\n{\"runId\":\"run_1\"}".utf8)
            }
            return TestUnixHTTPServer.httpResponse(body: Data(#"{"runId":"run_1"}"#.utf8))
        }

        let plane = HTTPControlPlane(target: .unixSocket(path: server.socketPath), token: nil, timeout: 5)
        let response = try await plane.runSchedule(
            id: "s1", request: WireScheduleRunRequest(clientId: "stable-run-id")
        )

        XCTAssertEqual(response.runId, "run_1")
        let posts = lock.withLock { requests.filter { $0.hasPrefix("POST /v1/schedules/s1/run ") } }
        XCTAssertEqual(posts.count, 2)
        XCTAssertTrue(posts.allSatisfy { $0.contains(#""clientId":"stable-run-id""#) })
    }

    func testManualRunDoesNotRetryAgainstAnOlderDaemon() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        let lock = NSLock()
        var requests: [String] = []
        try server.start(maxRequests: 2) { request in
            lock.withLock { requests.append(request) }
            if request.hasPrefix("GET /v1/health ") {
                return TestUnixHTTPServer.httpResponse(body: Data(#"{"ok":true}"#.utf8))
            }
            return Data("HTTP/1.1 200 OK\r\nContent-Length: 200\r\n\r\n{\"runId\":\"run_1\"}".utf8)
        }

        let plane = HTTPControlPlane(target: .unixSocket(path: server.socketPath), token: nil, timeout: 5)
        do {
            _ = try await plane.runSchedule(
                id: "s1", request: WireScheduleRunRequest(clientId: "stable-run-id")
            )
            XCTFail("expected an unknown outcome")
        } catch ControlPlaneError.outcomeUnknown {
            // The CLI must tell the caller to inspect run history instead of posting again.
        }

        XCTAssertEqual(
            lock.withLock { requests.filter { $0.hasPrefix("POST /v1/schedules/s1/run ") }.count },
            1
        )
    }

    func testUnreachableWhenNoListenerAtSocketPath() async {
        let path = NSTemporaryDirectory() + "patchwork-nonexistent-\(UUID().uuidString).sock"
        let client = RawHTTPClient(target: .unixSocket(path: path), timeout: 5)
        do {
            _ = try await client.perform(method: "GET", path: "/v1/health", headers: [:], body: nil)
            XCTFail("expected unreachable")
        } catch ControlPlaneError.unreachable {
            // expected
        } catch {
            XCTFail("expected ControlPlaneError.unreachable, got \(error)")
        }
    }

    func testBearerTokenSentOnlyForTCPNotUnixSocket() async throws {
        let server = TestUnixHTTPServer()
        defer { server.stop() }
        var capturedRequest = ""
        try server.start { request in
            capturedRequest = request
            return TestUnixHTTPServer.httpResponse(body: Data(#"{"ok":true}"#.utf8))
        }

        let plane = HTTPControlPlane(target: .unixSocket(path: server.socketPath), token: "should-not-be-sent", timeout: 5)
        _ = try await plane.health()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(capturedRequest.lowercased().contains("authorization"))
    }
}
