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
        for try await event in plane.events() { events.append(event) }

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].name, "thread")
        XCTAssertEqual(events[0].data["id"]?.stringValue, "t1")
        XCTAssertEqual(events[1].name, "run")
        XCTAssertEqual(events[1].data["status"]?.stringValue, "ok")
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
