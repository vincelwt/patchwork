import Foundation
import XCTest
@testable import PiDeskDaemon

final class RelayPairingProofTests: XCTestCase {
    func testPairingProofMatchesBrowserWireFormatAndRejectsChanges() throws {
        let ticket = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let proof = try RelayPairingProof.authenticationCode(
            ticket: ticket,
            installationID: "installation",
            deviceID: "device",
            name: "Phone",
            ecdhPublicKey: "ecdh",
            authX: "x-coordinate",
            authY: "y-coordinate"
        )

        XCTAssertEqual(base64URL(proof), "kiUeuKQbYQQ-D04eZgade_kPIZyv00fWe2PfxRU0Ufk")
        XCTAssertEqual(try RelayPairingProof.verificationCode(for: proof), "906232")
        XCTAssertTrue(RelayPairingProof.isValid(
            proof,
            ticket: ticket,
            installationID: "installation",
            deviceID: "device",
            name: "Phone",
            ecdhPublicKey: "ecdh",
            authX: "x-coordinate",
            authY: "y-coordinate"
        ))
        XCTAssertFalse(RelayPairingProof.isValid(
            proof,
            ticket: ticket,
            installationID: "installation",
            deviceID: "other-device",
            name: "Phone",
            ecdhPublicKey: "ecdh",
            authX: "x-coordinate",
            authY: "y-coordinate"
        ))
    }

    func testMutationCounterRejectsReplaysAcrossCounterGaps() {
        var highest: UInt64 = 0
        XCTAssertTrue(RelayMutationCounter.accept(1, highest: &highest))
        XCTAssertTrue(RelayMutationCounter.accept(7, highest: &highest))
        XCTAssertFalse(RelayMutationCounter.accept(7, highest: &highest))
        XCTAssertFalse(RelayMutationCounter.accept(6, highest: &highest))
        XCTAssertEqual(highest, 7)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
