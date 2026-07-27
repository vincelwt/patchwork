import XCTest
@testable import PiDeskDaemon

final class PiRPCSessionTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testReceiveMatchingSkipsAndPreservesEarlierEvents() async throws {
        let executable = directory.appendingPathComponent("fake-pi")
        try """
        #!/bin/sh
        IFS= read -r request
        id=$(printf '%s' "$request" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
        printf '%s\\n' '{"type":"extension_ui_request","method":"setStatus"}'
        /bin/sleep 0.1
        printf '{"type":"response","id":"%s","success":true}\\n' "$id"
        /bin/sleep 10
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let session = try PiRPCSession.start(
            cwd: directory,
            sessionPath: nil,
            piExecutable: executable,
            environment: ProcessInfo.processInfo.environment
        )
        defer { session.stop() }

        let requestID = try session.send(type: "get_state")
        let response = try await session.receiveMatching(id: requestID, timeout: 1)
        XCTAssertEqual(response["id"]?.stringValue, requestID)

        let event = try await session.receiveNext(timeout: 1)
        XCTAssertEqual(event?["type"]?.stringValue, "extension_ui_request")
    }
}
