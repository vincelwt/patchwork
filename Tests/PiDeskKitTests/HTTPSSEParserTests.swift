import XCTest
@testable import PiDeskKit

final class HTTPSSEParserTests: XCTestCase {
    func testUnicodeFrameSurvivesEveryByteSplit() {
        let source = Data("event: thread\ndata: {\"id\":\"会話🙂\",\"name\":\"速い\"}\n\n".utf8)

        for split in 0...source.count {
            var parser = SSEParser()
            var frames: [SSEFrame] = []
            frames += parser.append(source.prefix(split))
            frames += parser.append(source.dropFirst(split))

            XCTAssertEqual(frames.count, 1, "split at byte \(split)")
            XCTAssertEqual(frames.first?.event, "thread", "split at byte \(split)")
            guard let frame = frames.first else { continue }
            guard case let .thread(thread) = frame.decodedEvent() else {
                return XCTFail("thread frame did not decode at byte \(split)")
            }
            XCTAssertEqual(thread.id, "会話🙂", "split at byte \(split)")
            XCTAssertEqual(thread.name, "速い", "split at byte \(split)")
        }
    }

    func testOversizedUnterminatedLineFailsBoundedly() {
        var parser = SSEParser(maxBufferedBytes: 8)
        XCTAssertTrue(parser.append(Data(repeating: 0x61, count: 9)).isEmpty)
        XCTAssertTrue(parser.failed)
    }

    func testInvalidUTF8CompleteLineFails() {
        var parser = SSEParser(maxBufferedBytes: 32)
        XCTAssertTrue(parser.append(Data([0xFF, 0x0A])).isEmpty)
        XCTAssertTrue(parser.failed)
    }

    func testManyEmptyDataLinesCannotGrowPendingArrayWithoutBound() {
        var parser = SSEParser(maxBufferedBytes: 24)
        let chunk = Data(String(repeating: "data:\n", count: 5).utf8)
        XCTAssertTrue(parser.append(chunk).isEmpty)
        XCTAssertTrue(parser.failed)
    }

    func testInteractionFrameDecodesAsATypedEvent() throws {
        let interaction = PendingInteraction(
            id: "dialog-1", runId: "run-1", threadId: "thread-1", method: .select,
            title: "Pick one", options: ["A"], expiresAt: Date().addingTimeInterval(600)
        )
        let payload = try XCTUnwrap(String(
            data: PiDeskJSON.encoder.encode(interaction), encoding: .utf8
        ))
        var parser = SSEParser()
        let frame = try XCTUnwrap(parser.append(Data("event: interaction\ndata: \(payload)\n\n".utf8)).first)

        guard case let .interaction(decoded) = frame.decodedEvent() else {
            return XCTFail("interaction frame did not decode as an interaction")
        }
        XCTAssertEqual(decoded.id, interaction.id)
        XCTAssertEqual(decoded.options, ["A"])
    }
}
