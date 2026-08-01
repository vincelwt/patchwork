import XCTest
@testable import PatchworkKit

final class BoundedJSONFilesTests: XCTestCase {
    func testCatalogRefreshSkipsRediscoveryButStillSeesInPlaceAndSymlinkChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedJSONFiles-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("watched", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let direct = directory.appendingPathComponent("direct.json")
        try Data("{\"value\":1}".utf8).write(to: direct)
        let target = root.appendingPathComponent("linked.payload")
        let link = directory.appendingPathComponent("linked.json")
        try Data("{\"value\":2}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let initial = BoundedJSONFiles.scan(in: directory, limit: 10, maxBytes: 1_024)
        XCTAssertFalse(initial.reusedDirectoryListing)
        XCTAssertEqual(initial.catalog.files.count, 2)

        let unchanged = BoundedJSONFiles.scan(
            in: directory, limit: 10, maxBytes: 1_024, previous: initial.catalog
        )
        XCTAssertTrue(unchanged.reusedDirectoryListing)

        try Data("{\"value\":100}".utf8).write(to: direct)
        let replacement = root.appendingPathComponent("replacement.payload")
        try Data("{\"value\":3}".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: replacement, to: target)

        let changed = BoundedJSONFiles.scan(
            in: directory, limit: 10, maxBytes: 1_024, previous: unchanged.catalog
        )
        XCTAssertTrue(changed.reusedDirectoryListing)
        let fingerprints = Dictionary(uniqueKeysWithValues: changed.catalog.files.map {
            ($0.url.lastPathComponent, $0.fingerprint)
        })
        let previousFingerprints = Dictionary(uniqueKeysWithValues: unchanged.catalog.files.map {
            ($0.url.lastPathComponent, $0.fingerprint)
        })
        XCTAssertNotEqual(fingerprints["direct.json"], previousFingerprints["direct.json"])
        XCTAssertNotEqual(fingerprints["linked.json"], previousFingerprints["linked.json"])
    }

    func testFullBoundedCatalogIsRediscoveredSoAnOmittedFileCanBecomeNewest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedJSONFiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Date(timeIntervalSince1970: 1_000)
        for name in ["a.json", "b.json"] {
            let file = directory.appendingPathComponent(name)
            try Data("{}".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        }

        let initial = BoundedJSONFiles.scan(in: directory, limit: 1, maxBytes: 1_024)
        let omitted = directory.appendingPathComponent(
            initial.catalog.files[0].url.lastPathComponent == "a.json" ? "b.json" : "a.json"
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: omitted.path
        )

        let refreshed = BoundedJSONFiles.scan(
            in: directory, limit: 1, maxBytes: 1_024, previous: initial.catalog
        )
        XCTAssertFalse(refreshed.reusedDirectoryListing)
        XCTAssertEqual(refreshed.catalog.files.first?.path, omitted.path)
    }

    func testSkippedJSONCandidatePreventsDirectoryListingReuse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedJSONFiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("valid.json"))
        try Data(repeating: 0x20, count: 33).write(
            to: directory.appendingPathComponent("oversized.json")
        )

        let initial = BoundedJSONFiles.scan(in: directory, limit: 10, maxBytes: 32)
        XCTAssertEqual(initial.catalog.files.count, 1)
        let repeated = BoundedJSONFiles.scan(
            in: directory, limit: 10, maxBytes: 32, previous: initial.catalog
        )

        XCTAssertFalse(repeated.reusedDirectoryListing)
    }
}
