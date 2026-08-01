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

    func testOversizedRecordIsDiscardedWithoutGrowingTheBufferAndNextLineRecovers() {
        var framer = JSONLFramer(maximumRecordBytes: 8)

        XCTAssertTrue(framer.append(Data(repeating: 0x61, count: 1_024)).isEmpty)
        XCTAssertLessThanOrEqual(framer.bufferedByteCount, 8)
        XCTAssertEqual(framer.takeOverflowedRecordCount(), 1)

        let recovered = framer.append(Data("ignored\n{\"x\":1}\n".utf8))
        XCTAssertEqual(recovered.map { String(decoding: $0, as: UTF8.self) }, ["{\"x\":1}"])
        XCTAssertEqual(framer.bufferedByteCount, 0)
    }

    func testSnapshotReadDoesNotConsumeBytesAppendedAfterTheSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiJSONLSnapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.jsonl")
        try Data("first\n".utf8).write(to: url)

        let reader = try FileHandle(forReadingFrom: url)
        let snapshotBytes = Int(try reader.seekToEnd())
        let writer = try FileHandle(forWritingTo: url)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(repeating: 0x62, count: 1 * 1_024 * 1_024))
        try writer.close()
        try reader.seek(toOffset: 0)

        let snapshot = try JSONLFileReader.readSnapshot(handle: reader, byteCount: snapshotBytes)
        try reader.close()
        XCTAssertEqual(snapshot, Data("first\n".utf8))
    }
}
