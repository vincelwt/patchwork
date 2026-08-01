import XCTest
@testable import PatchworkCLI

final class JSONValueTests: XCTestCase {
    func testDecodesEveryScalarKind() throws {
        let value = try JSONValue.decode(Data(#"{"a":1,"b":"s","c":true,"d":null,"e":[1,2],"f":{"g":1}}"#.utf8))
        XCTAssertEqual(value["a"]?.stringValue, "1.0")
        XCTAssertEqual(value["b"]?.stringValue, "s")
        XCTAssertEqual(value["c"], .bool(true))
        XCTAssertEqual(value["d"], .null)
        XCTAssertEqual(value["e"], .array([.number(1), .number(2)]))
        XCTAssertEqual(value["f"]?["g"], .number(1))
    }

    func testSubscriptOnNonObjectReturnsNil() {
        XCTAssertNil(JSONValue.array([])["x"])
        XCTAssertNil(JSONValue.string("s")["x"])
    }

    func testDecodedAsRoundTripsIntoConcreteType() throws {
        let value = JSONValue.object(["id": .string("run_1"), "status": .string("ok")])
        let run = try value.decoded(as: WireRun.self)
        XCTAssertEqual(run.id, "run_1")
        XCTAssertEqual(run.status, "ok")
    }

    func testRenderedHumanBoundsDepth() {
        var value = JSONValue.string("leaf")
        for _ in 0..<20 { value = .object(["nested": value]) }
        let rendered = value.renderedHuman(maxDepth: 3, maxLines: 1000)
        XCTAssertLessThanOrEqual(rendered.components(separatedBy: "\n").count, 10)
        XCTAssertTrue(rendered.contains("…"))
    }

    func testRenderedHumanBoundsLineCount() {
        var fields: [String: JSONValue] = [:]
        for index in 0..<2000 { fields["k\(index)"] = .string("v") }
        let rendered = JSONValue.object(fields).renderedHuman(maxDepth: 6, maxLines: 50)
        XCTAssertLessThanOrEqual(rendered.components(separatedBy: "\n").count, 51)
    }

    func testRenderedHumanOnEmptyObjectDoesNotCrash() {
        XCTAssertEqual(JSONValue.object([:]).renderedHuman(), "")
    }
}
