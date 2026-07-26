import XCTest
@testable import PiDeskWeb

/// Caching/ETag behavior and bounded reads, tested against throwaway directories so the
/// fixtures can be created, mutated, and sized exactly as each test needs.
final class CachingAndBoundsTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-web-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Caching

    /// Proves memoization empirically rather than by inspection: write v1, resolve it (which
    /// caches it), overwrite the file on disk with v2, resolve the same site path again, and
    /// confirm the stale, cached v1 bytes come back — the module never re-reads a path it has
    /// already served, exactly as documented ("cached in memory after first load").
    func testResolvedAssetIsMemoizedAfterFirstLoad() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Unique filename so this test cannot collide with another test's cache entry — the
        // module-level cache is a shared singleton across the whole test process.
        let name = "memo-\(UUID().uuidString).txt"
        let file = root.appendingPathComponent(name)
        try "version-one".write(to: file, atomically: true, encoding: .utf8)

        let first = try XCTUnwrap(PiDeskWeb.resolvedAsset(forSitePath: "/\(name)", siteRoot: root))
        XCTAssertEqual(String(decoding: first.data, as: UTF8.self), "version-one")

        try "version-two-is-much-longer-than-version-one".write(to: file, atomically: true, encoding: .utf8)

        let second = try XCTUnwrap(PiDeskWeb.resolvedAsset(forSitePath: "/\(name)", siteRoot: root))
        XCTAssertEqual(String(decoding: second.data, as: UTF8.self), "version-one", "expected the memoized v1 bytes, not a re-read")
        XCTAssertEqual(first, second)
    }

    func testUnresolvedPathsAreNeverCached() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "sometimes-\(UUID().uuidString).txt"
        let file = root.appendingPathComponent(name)

        XCTAssertNil(PiDeskWeb.resolvedAsset(forSitePath: "/\(name)", siteRoot: root), "must be nil before the file exists")

        try "now it exists".write(to: file, atomically: true, encoding: .utf8)
        let asset = try XCTUnwrap(PiDeskWeb.resolvedAsset(forSitePath: "/\(name)", siteRoot: root))
        XCTAssertEqual(String(decoding: asset.data, as: UTF8.self), "now it exists", "a prior miss must not have poisoned the cache")
    }

    // MARK: - ETag

    func testETagIsQuotedPerRFC9110() {
        let tag = PiDeskWeb.etag(for: Data("hello".utf8))
        XCTAssertTrue(tag.hasPrefix("\""))
        XCTAssertTrue(tag.hasSuffix("\""))
    }

    func testETagIsContentAddressedNotPathAddressed() {
        let a = PiDeskWeb.etag(for: Data("same bytes".utf8))
        let b = PiDeskWeb.etag(for: Data("same bytes".utf8))
        XCTAssertEqual(a, b, "identical content must produce identical ETags")
    }

    func testETagChangesWhenContentChanges() {
        let a = PiDeskWeb.etag(for: Data("version one".utf8))
        let b = PiDeskWeb.etag(for: Data("version two".utf8))
        XCTAssertNotEqual(a, b)
    }

    func testDifferentAssetsInTheBundleHaveDifferentETags() throws {
        let css = try XCTUnwrap(PiDeskWeb.asset(for: "/css/app.css"))
        let js = try XCTUnwrap(PiDeskWeb.asset(for: "/js/app.js"))
        XCTAssertNotEqual(css.etag, js.etag)
    }

    func testRepeatedResolutionOfTheSameRealAssetReturnsTheSameETag() throws {
        let first = try XCTUnwrap(PiDeskWeb.asset(for: "/index.html"))
        let second = try XCTUnwrap(PiDeskWeb.asset(for: "/index.html"))
        XCTAssertEqual(first.etag, second.etag)
    }

    // MARK: - Bounded reads

    func testBoundedContentsAcceptsAFileAtOrUnderTheLimit() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("small.txt")
        try Data(repeating: 0x41, count: 16).write(to: file)

        XCTAssertNotNil(PiDeskWeb.boundedContents(of: file, limit: 16))
        XCTAssertNotNil(PiDeskWeb.boundedContents(of: file, limit: 1024))
    }

    func testBoundedContentsRejectsAFileOverTheLimit() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("big.txt")
        try Data(repeating: 0x41, count: 17).write(to: file)

        XCTAssertNil(PiDeskWeb.boundedContents(of: file, limit: 16), "17 bytes must be rejected by a 16-byte limit")
    }

    func testBoundedContentsRejectsAMissingFile() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertNil(PiDeskWeb.boundedContents(of: missing, limit: 1024))
    }

    /// The real bundled site must comfortably fit under the module's own generous ceiling —
    /// otherwise `maxAssetBytes` would be silently starving real assets.
    func testShippedAssetsAreWellUnderTheDefaultLimit() throws {
        let asset = try XCTUnwrap(PiDeskWeb.asset(for: "/index.html"))
        XCTAssertLessThan(asset.data.count, PiDeskWeb.maxAssetBytes)
    }
}
