import XCTest
@testable import PiDesktop

/// The routing rule behind "sending while Pi is working must add to the outbox instead of going
/// straight to Pi": pure so every branch can be pinned without standing up a runtime.
final class ComposerSubmitPolicyTests: XCTestCase {
    func testIdleSendsAlwaysGoDirect() {
        XCTAssertEqual(
            ComposerSubmitRoute.decide(intent: .steer, isStreaming: false, isEditingLastMessage: false, canSend: true),
            .direct
        )
        XCTAssertEqual(
            ComposerSubmitRoute.decide(intent: .followUp, isStreaming: false, isEditingLastMessage: false, canSend: true),
            .direct
        )
    }

    func testMidTurnSendsQueueInsteadOfReachingPiDirectly() {
        XCTAssertEqual(
            ComposerSubmitRoute.decide(intent: .steer, isStreaming: true, isEditingLastMessage: false, canSend: true),
            .queue(.steer)
        )
        XCTAssertEqual(
            ComposerSubmitRoute.decide(intent: .followUp, isStreaming: true, isEditingLastMessage: false, canSend: true),
            .queue(.followUp)
        )
    }

    func testAnArmedEditAlwaysGoesDirectEvenMidTurn() {
        XCTAssertEqual(
            ComposerSubmitRoute.decide(intent: .steer, isStreaming: true, isEditingLastMessage: true, canSend: true),
            .direct,
            "Resubmitting replaces the turn in place; it must never be queued alongside it"
        )
    }

    func testAnEmptyComposerNeverQueuesAnEmptyEntry() {
        XCTAssertEqual(
            ComposerSubmitRoute.decide(intent: .steer, isStreaming: true, isEditingLastMessage: false, canSend: false),
            .direct,
            "Falls through to the direct path's own no-op rather than queuing nothing"
        )
    }
}
