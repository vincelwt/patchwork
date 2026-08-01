import Foundation
import XCTest
@testable import PatchworkDaemon

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

    func testPairingURLForcesANewSafariLoadWithoutLeakingSecretsBeforeTheFragment() throws {
        let first = RelayService.pairingURL(
            installationID: "installation", offerID: "offer-one",
            ticket: "secret-ticket", hostPublicKey: "secret-host-key"
        )
        let second = RelayService.pairingURL(
            installationID: "installation", offerID: "offer-two",
            ticket: "secret-ticket", hostPublicKey: "secret-host-key"
        )
        let components = try XCTUnwrap(URLComponents(string: first))

        XCTAssertEqual(components.path, "/pair/installation")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "offer", value: "offer-one")])
        XCTAssertEqual(components.fragment, "ticket=secret-ticket&host=secret-host-key")
        XCTAssertFalse(first.split(separator: "#", maxSplits: 1)[0].contains("secret"))
        XCTAssertNotEqual(first.split(separator: "#", maxSplits: 1)[0], second.split(separator: "#", maxSplits: 1)[0])
    }

    func testMutationCounterRejectsReplaysAcrossCounterGaps() {
        var highest: UInt64 = 0
        XCTAssertTrue(RelayMutationCounter.accept(1, highest: &highest))
        XCTAssertTrue(RelayMutationCounter.accept(7, highest: &highest))
        XCTAssertFalse(RelayMutationCounter.accept(7, highest: &highest))
        XCTAssertFalse(RelayMutationCounter.accept(6, highest: &highest))
        XCTAssertEqual(highest, 7)
    }

    func testHeartbeatRequiresAPongBeforeItsDeadline() async {
        let pong = await RelayHeartbeat.succeeds(timeoutNanoseconds: 1_000_000_000) { $0(nil) }
        let failure = await RelayHeartbeat.succeeds(timeoutNanoseconds: 1_000_000_000) { $0(URLError(.networkConnectionLost)) }
        let timeout = await RelayHeartbeat.succeeds(timeoutNanoseconds: 1_000_000) { _ in }
        XCTAssertTrue(pong)
        XCTAssertFalse(failure)
        XCTAssertFalse(timeout)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
