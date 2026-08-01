import Foundation
import XCTest
@testable import Patchwork

final class DraftRecoveryTests: XCTestCase {
    func testFailedSubmissionRestoresAheadOfNewTypingWithoutDuplicatingImages() {
        let sent = ImageAttachment(
            id: UUID(), data: Data("a".utf8), mimeType: "image/png", fileName: "a.png",
            fileURL: URL(fileURLWithPath: "/tmp/a.png")
        )
        let current = ImageAttachment(
            id: UUID(), data: Data("b".utf8), mimeType: "image/png", fileName: "b.png",
            fileURL: URL(fileURLWithPath: "/tmp/b.png")
        )

        XCTAssertEqual(DraftRecovery.restoredText(sent: "original", current: "typed while waiting"),
                       "original\ntyped while waiting")
        XCTAssertEqual(DraftRecovery.restoredText(sent: "original", current: ""), "original")
        XCTAssertEqual(DraftRecovery.restoredText(sent: "", current: "new"), "new")

        let restored = DraftRecovery.restoredAttachments(sent: [sent], current: [sent, current])
        XCTAssertEqual(restored.map(\.id), [sent.id, current.id])
    }
}
