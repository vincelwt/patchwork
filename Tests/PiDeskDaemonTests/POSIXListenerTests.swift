import XCTest
@testable import PiDeskDaemon

final class POSIXListenerTests: XCTestCase {
    func testInvalidTCPPortsAreRejectedBeforeConversion() {
        XCTAssertThrowsError(try POSIXListener.tcpLoopback(port: -1))
        XCTAssertThrowsError(try POSIXListener.tcpLoopback(port: 65_536))
    }

    func testConnectionAdmissionIsBoundedAndReleasesCapacity() {
        let admission = HTTPConnectionAdmission(maxConnections: 2, maxSSEConnections: 1)

        XCTAssertTrue(admission.acquireConnection())
        XCTAssertTrue(admission.acquireConnection())
        XCTAssertFalse(admission.acquireConnection())
        admission.releaseConnection()
        XCTAssertTrue(admission.acquireConnection())

        XCTAssertTrue(admission.acquireSSE())
        XCTAssertFalse(admission.acquireSSE())
        admission.releaseSSE()
        XCTAssertTrue(admission.acquireSSE())
    }
}
