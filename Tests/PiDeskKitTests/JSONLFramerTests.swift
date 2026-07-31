import Foundation
import XCTest
@testable import PiDeskKit

final class JSONLFramerTests: XCTestCase {
    func testFramesAcrossArbitraryChunksAndStripsOnlyCRBeforeLF() throws {
        var framer = JSONLFramer()
        let unicodeSeparator = "inside\u{2028}string"
        let payload = "{\"a\":1}\r\n{\"text\":\"\(unicodeSeparator)\"}\n{\"tail\":true}"
        let data = Data(payload.utf8)

        let first = framer.append(data.prefix(7))
        XCTAssertTrue(first.isEmpty)
        let second = framer.append(data.dropFirst(7).prefix(14))
        let third = framer.append(data.dropFirst(21))
        let records = first + second + third

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(String(decoding: records[0], as: UTF8.self), "{\"a\":1}")
        XCTAssertEqual(String(decoding: records[1], as: UTF8.self), "{\"text\":\"\(unicodeSeparator)\"}")
        XCTAssertEqual(String(decoding: try XCTUnwrap(framer.finish()), as: UTF8.self), "{\"tail\":true}")
        XCTAssertNil(framer.finish())
    }

    func testMultipleRecordsInOneChunk() {
        var framer = JSONLFramer()
        let records = framer.append(Data("{}\n{\"ok\":true}\n\n".utf8))
        XCTAssertEqual(records.map { String(decoding: $0, as: UTF8.self) }, ["{}", "{\"ok\":true}"])
    }
}
