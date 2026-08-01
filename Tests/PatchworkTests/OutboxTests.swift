import Foundation
import XCTest
@testable import Patchwork

final class OutboxPolicyTests: XCTestCase {
    private func entry(_ text: String, _ delivery: OutboxEntry.Delivery) -> OutboxEntry {
        OutboxEntry(text: text, delivery: delivery)
    }

    func testAFullQueueRejectsTheNewestMessageWithoutDroppingTheOldest() {
        var entries: [OutboxEntry] = []
        for index in 0..<OutboxPolicy.limit {
            entries = try! XCTUnwrap(OutboxPolicy.append(entry("m\(index)", .steer), to: entries))
        }
        let rejected = OutboxPolicy.append(entry("newest", .steer), to: entries)

        XCTAssertEqual(entries.count, OutboxPolicy.limit, "a runaway loop must not stack messages forever")
        XCTAssertEqual(entries.first?.text, "m0")
        XCTAssertEqual(entries.last?.text, "m\(OutboxPolicy.limit - 1)")
        XCTAssertNil(rejected)
    }

    func testRejectedEntryReturnsToItsOriginalFIFOPosition() {
        let older = OutboxEntry(text: "older", delivery: .followUp, queuedAt: Date(timeIntervalSince1970: 1))
        let newer = OutboxEntry(text: "newer", delivery: .followUp, queuedAt: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(OutboxPolicy.restoring(older, to: [newer]).map(\.text), ["older", "newer"])
    }

    func testEachBoundaryOnlyFlushesItsOwnMessages() {
        let entries = [
            entry("steer one", .steer),
            entry("later", .followUp),
            entry("steer two", .steer)
        ]
        XCTAssertEqual(OutboxPolicy.due(entries, at: .steer).map(\.text), ["steer one", "steer two"])
        XCTAssertEqual(OutboxPolicy.due(entries, at: .followUp).map(\.text), ["later"])
        XCTAssertEqual(OutboxPolicy.removing(.steer, from: entries).map(\.text), ["later"])
        XCTAssertEqual(OutboxPolicy.removing(.followUp, from: entries).map(\.text), ["steer one", "steer two"])
    }
}

/// The rules behind the strip shown above the composer: what shows, what is editable, in what
/// order, and the empty case.
final class OutboxPresentationTests: XCTestCase {
    private func entry(_ text: String, _ delivery: OutboxEntry.Delivery, attachments: [ImageAttachment] = []) -> OutboxEntry {
        OutboxEntry(text: text, delivery: delivery, attachments: attachments)
    }

    private func image(_ name: String) -> ImageAttachment {
        ImageAttachment(
            data: Data([0x01]), mimeType: "image/png", fileName: name,
            fileURL: URL(fileURLWithPath: "/tmp/\(name)")
        )
    }

    /// Every test below is about content rules, so the runtime-ownership gate defaults open;
    /// `testHiddenEntirelyWhenTheComposerIsNotLookingAtTheAttachedRuntime` covers the gate itself.
    private func rows(
        outbox: [OutboxEntry] = [],
        steeringQueue: [String] = [],
        followUpQueue: [String] = [],
        isSelectedRuntime: Bool = true
    ) -> [OutboxPresentation.Row] {
        OutboxPresentation.rows(outbox: outbox, steeringQueue: steeringQueue, followUpQueue: followUpQueue, isSelectedRuntime: isSelectedRuntime)
    }

    // MARK: - Empty case

    func testEmptyOnlyWhenNothingIsQueuedAnywhere() {
        XCTAssertTrue(OutboxPresentation.isEmpty(outbox: [], steeringQueue: [], followUpQueue: [], isSelectedRuntime: true))
        XCTAssertFalse(OutboxPresentation.isEmpty(outbox: [entry("a", .steer)], steeringQueue: [], followUpQueue: [], isSelectedRuntime: true))
        XCTAssertFalse(OutboxPresentation.isEmpty(outbox: [], steeringQueue: ["from another client"], followUpQueue: [], isSelectedRuntime: true))
        XCTAssertFalse(OutboxPresentation.isEmpty(outbox: [], steeringQueue: [], followUpQueue: ["from another client"], isSelectedRuntime: true))
    }

    func testRowsIsEmptyExactlyWhenIsEmptyReportsTrue() {
        XCTAssertTrue(rows().isEmpty)
        XCTAssertFalse(rows(outbox: [entry("a", .steer)]).isEmpty)
    }

    func testHiddenEntirelyWhenTheComposerIsNotLookingAtTheAttachedRuntime() {
        // `outbox` and `runtimeState`'s queues are process-wide on `AppStore`, not scoped per
        // conversation, so a full house of content must still disappear the moment the composer
        // on screen is not the one the attached runtime belongs to — otherwise switching away
        // from a busy conversation would leak its queue (and let you "remove" from it) here.
        XCTAssertTrue(OutboxPresentation.isEmpty(
            outbox: [entry("mine", .steer)],
            steeringQueue: ["pi's"],
            followUpQueue: ["pi's too"],
            isSelectedRuntime: false
        ))
        XCTAssertTrue(rows(
            outbox: [entry("mine", .steer)],
            steeringQueue: ["pi's"],
            followUpQueue: ["pi's too"],
            isSelectedRuntime: false
        ).isEmpty)
    }

    // MARK: - What shows / ordering

    func testRuntimeQueuesComeBeforeTheAppsOwnOutboxInOriginalOrder() {
        let result = rows(
            outbox: [entry("mine one", .steer), entry("mine two", .followUp)],
            steeringQueue: ["pi steering"],
            followUpQueue: ["pi follow-up"]
        )
        XCTAssertEqual(result.map(\.text), ["pi steering", "pi follow-up", "mine one", "mine two"])
    }

    func testAppOutboxOrderIsPreservedNotResorted() {
        // Queued oldest-first, exactly the order `flushOutbox` will dispatch them in.
        let outbox = [entry("first", .steer), entry("second", .steer), entry("third", .followUp)]
        XCTAssertEqual(rows(outbox: outbox).map(\.text), ["first", "second", "third"])
    }

    func testAttachmentCountIsCarriedFromTheEntry() {
        let withImages = entry("look", .steer, attachments: [image("a.png"), image("b.png")])
        XCTAssertEqual(rows(outbox: [withImages]).first?.attachmentCount, 2)
    }

    // MARK: - What is editable

    func testOnlyAppHeldRowsAreEditableAndCarryTheirEntry() throws {
        let mine = entry("mine", .steer)
        let result = rows(outbox: [mine], steeringQueue: ["not mine"])

        let runtimeRow = try XCTUnwrap(result.first { $0.text == "not mine" })
        XCTAssertFalse(runtimeRow.isEditable, "Pi's RPC has no command to withdraw something it already reported")
        XCTAssertNil(runtimeRow.entry)

        let appRow = try XCTUnwrap(result.first { $0.text == "mine" })
        XCTAssertTrue(appRow.isEditable)
        XCTAssertEqual(appRow.entry, mine)
    }

    func testRuntimeRowIdentityStaysUniqueAcrossBothQueuesEvenWithDuplicateText() {
        let result = rows(steeringQueue: ["same text", "same text"], followUpQueue: ["same text"])
        XCTAssertEqual(Set(result.map(\.id)).count, result.count, "every row must have a stable, unique identity for a List/ForEach")
    }
}
