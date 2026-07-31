import XCTest
@testable import PiDeskKit

final class PiJSONValueNumberTests: XCTestCase {
    /// `NSNumber as? Bool` succeeds for 0 and 1. Decoding a JSON number as a boolean made
    /// `intValue` return nil for exactly the values most likely to appear in a count.
    func testJSONNumbersZeroAndOneStayNumbers() throws {
        let value = try PiJSONValue.decode(Data(#"{"exitCode":0,"one":1,"many":42,"real":1.5}"#.utf8))
        XCTAssertEqual(value["exitCode"]?.intValue, 0)
        XCTAssertEqual(value["one"]?.intValue, 1)
        XCTAssertEqual(value["many"]?.intValue, 42)
        XCTAssertEqual(value["real"]?.doubleValue, 1.5)
        XCTAssertNil(value["exitCode"]?.boolValue, "0 is a number, not false")
        XCTAssertNil(value["one"]?.boolValue, "1 is a number, not true")
    }

    func testRealJSONBooleansStayBooleans() throws {
        let value = try PiJSONValue.decode(Data(#"{"t":true,"f":false}"#.utf8))
        XCTAssertEqual(value["t"]?.boolValue, true)
        XCTAssertEqual(value["f"]?.boolValue, false)
        XCTAssertNil(value["t"]?.intValue, "a boolean is not a number")
    }

    /// A usage block of zeros is the common case for a turn that produced no output; it has to
    /// read back as zeros rather than as nil.
    func testAZeroUsageBlockRoundTrips() throws {
        let value = try PiJSONValue.decode(Data(#"{"usage":{"input":0,"output":1,"cost":{"total":0}}}"#.utf8))
        XCTAssertEqual(value["usage"]?["input"]?.intValue, 0)
        XCTAssertEqual(value["usage"]?["output"]?.intValue, 1)
        XCTAssertEqual(value["usage"]?["cost"]?["total"]?.doubleValue, 0)
    }

    func testAnyValueRoundTripsThroughSerialization() throws {
        let source = #"{"a":[1,true,"x",null,0],"b":{"c":1.5}}"#
        let value = try PiJSONValue.decode(Data(source.utf8))
        let data = try JSONSerialization.data(withJSONObject: value.anyValue, options: [.sortedKeys])
        XCTAssertEqual(PiJSONValue(any: try JSONSerialization.jsonObject(with: data)), value)
    }
}
