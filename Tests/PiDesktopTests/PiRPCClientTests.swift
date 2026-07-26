import Foundation
import XCTest
@testable import PiDesktop

final class PiRPCClientTests: XCTestCase {
    func testStartsInstalledPiAndGetsStateWithoutProviderCall() throws {
        guard let piURL = PiLocator.resolve() else {
            throw XCTSkip("Pi CLI is not installed")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiDesktopRPC-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("project", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = PiRPCClient(
            executableOverride: piURL,
            environmentOverrides: [
                "PI_CODING_AGENT_SESSION_DIR": sessions.path,
                "PI_SKIP_VERSION_CHECK": "1",
                "PI_TELEMETRY": "0"
            ],
            additionalArguments: ["--no-extensions", "--no-skills", "--no-prompt-templates"]
        )
        try client.start(cwd: cwd, sessionPath: nil)
        defer { client.stop() }

        let responseReceived = expectation(description: "get_state response")
        var capturedResponse: JSONValue?
        var capturedError: Error?
        client.send(type: "get_state", payload: [:]) { result in
            switch result {
            case let .success(response): capturedResponse = response
            case let .failure(error): capturedError = error
            }
            responseReceived.fulfill()
        }
        wait(for: [responseReceived], timeout: 12)

        XCTAssertNil(capturedError)
        let response = try XCTUnwrap(capturedResponse)
        XCTAssertEqual(response["success"]?.boolValue, true)
        XCTAssertNotNil(response["data"]?["sessionId"]?.stringValue)
        XCTAssertTrue(response["data"]?["sessionFile"]?.stringValue?.hasPrefix(sessions.path) == true)
        XCTAssertNotNil(response["data"]?["model"])
    }
}
