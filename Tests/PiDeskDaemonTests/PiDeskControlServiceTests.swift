import XCTest
import PiDeskKit
@testable import PiDeskDaemon

final class PiDeskControlServiceTests: XCTestCase {
    func testServiceOwnsSocketForItsLifetimeAndCanBeRecreated() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("daemon.sock")

        func makeService() -> PiDeskControlService {
            let core = TestSupport.makeCore(in: directory, schedulerPollInterval: 0.05)
            return PiDeskControlService(
                settings: core.settings,
                logger: core.logger,
                connectivity: nil,
                core: core,
                unixSocketPath: socket
            )
        }

        let first = makeService()
        try await first.start()
        let client = PiDeskClient.unixSocket(at: socket, requestTimeout: 1)
        let firstHealth = try await client.health()
        XCTAssertTrue(firstHealth.ok)
        await first.stop(graceSeconds: 0)

        do {
            _ = try await client.health()
            XCTFail("A stopped in-process service must release its socket")
        } catch { /* expected */ }

        let second = makeService()
        try await second.start()
        let secondHealth = try await client.health()
        XCTAssertTrue(secondHealth.ok)
        await second.stop(graceSeconds: 0)
    }
}
