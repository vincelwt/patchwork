import Darwin
import XCTest
@testable import PatchworkKit

final class RawSocketTimeoutTests: XCTestCase {
    func testZeroClearsAnInstalledSocketTimeout() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }

        RawSocket.setTimeouts(fd: descriptors[0], timeout: 0.25)
        XCTAssertGreaterThan(try timeout(fd: descriptors[0], option: SO_RCVTIMEO).tv_usec, 0)

        RawSocket.setTimeouts(fd: descriptors[0], timeout: 0)
        let receive = try timeout(fd: descriptors[0], option: SO_RCVTIMEO)
        let send = try timeout(fd: descriptors[0], option: SO_SNDTIMEO)
        XCTAssertEqual(receive.tv_sec, 0)
        XCTAssertEqual(receive.tv_usec, 0)
        XCTAssertEqual(send.tv_sec, 0)
        XCTAssertEqual(send.tv_usec, 0)
    }

    func testBrokenPipeSignalsAreSuppressedOnClientSockets() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }

        try RawSocket.suppressBrokenPipeSignal(fd: descriptors[0])
        var enabled: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, &length), 0)
        XCTAssertEqual(enabled, 1)
    }

    func testNonFiniteTimeoutsAreConvertedWithoutTrapping() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }

        RawSocket.setTimeouts(fd: descriptors[0], timeout: .nan)
        XCTAssertEqual(try timeout(fd: descriptors[0], option: SO_RCVTIMEO).tv_sec, 0)
        RawSocket.setTimeouts(fd: descriptors[0], timeout: .infinity)
        XCTAssertGreaterThan(try timeout(fd: descriptors[0], option: SO_RCVTIMEO).tv_sec, 0)
    }

    func testInvalidTCPPortsAreRejectedBeforeConversion() {
        XCTAssertThrowsError(try RawSocket.connectTCP(host: "127.0.0.1", port: -1, timeout: 0.1))
        XCTAssertThrowsError(try RawSocket.connectTCP(host: "127.0.0.1", port: 65_536, timeout: 0.1))
    }

    func testAggregateReadReportsTimeoutInsteadOfTreatingItAsEOF() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }
        RawSocket.setTimeouts(fd: descriptors[0], timeout: 0.02)

        XCTAssertThrowsError(try RawSocket.readAllUntilClosed(
            fd: descriptors[0], maxBytes: 1_024
        ))
    }

    func testPrematureContentLengthEOFIsRejected() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort".utf8)
        XCTAssertThrowsError(try HTTPWireFormat.parseResponse(raw)) { error in
            guard case PatchworkClientError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    func testInvalidAndOverlongContentLengthsAreRejected() {
        for raw in [
            "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: nope\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nextra"
        ] {
            XCTAssertThrowsError(try HTTPWireFormat.parseResponse(Data(raw.utf8)))
        }
    }

    func testEOFFramingWithoutContentLengthRemainsValid() throws {
        let response = try HTTPWireFormat.parseResponse(
            Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\ncomplete".utf8)
        )
        XCTAssertEqual(response.body, Data("complete".utf8))
    }

    func testProtectedClientMutationPreservesPreConnectUnreachable() async {
        let path = NSTemporaryDirectory() + "patchwork-kit-missing-\(UUID().uuidString).sock"
        let client = PatchworkClient(
            transport: .unixSocket(path: path), requestTimeout: 0.1
        )
        do {
            _ = try await client.sendMessage(
                threadId: "missing",
                SendMessageRequest(text: "hello", clientId: "stable-client-id")
            )
            XCTFail("expected daemonUnreachable")
        } catch PatchworkClientError.daemonUnreachable {
            // Connect failed before any request bytes could be sent.
        } catch {
            XCTFail("expected daemonUnreachable, got \(error)")
        }
    }

    private func timeout(fd: Int32, option: Int32) throws -> timeval {
        var value = timeval()
        var length = socklen_t(MemoryLayout<timeval>.size)
        let result = getsockopt(fd, SOL_SOCKET, option, &value, &length)
        XCTAssertEqual(result, 0)
        return value
    }
}
