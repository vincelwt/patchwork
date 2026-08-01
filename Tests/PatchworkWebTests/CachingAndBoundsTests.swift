import XCTest
@testable import PatchworkWeb

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

        let first = try XCTUnwrap(PatchworkWeb.resolvedAsset(forSitePath: "/\(name)", siteRoot: root))
        XCTAssertEqual(String(decoding: first.data, as: UTF8.self), "version-one")

        try "version-two-is-much-longer-than-version-one".write(to: file, atomically: true, encoding: .utf8)

        let second = try XCTUnwrap(PatchworkWeb.resolvedAsset(forSitePath: "/\(name)", siteRoot: root))
        XCTAssertEqual(String(decoding: second.data, as: UTF8.self), "version-one", "expected the memoized v1 bytes, not a re-read")
        XCTAssertEqual(first, second)
    }

    func testUnresolvedPathsAreNeverCached() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "sometimes-\(UUID().uuidString).txt"
        let file = root.appendingPathComponent(name)

        XCTAssertNil(PatchworkWeb.resolvedAsset(forSitePath: "/\(name)", siteRoot: root), "must be nil before the file exists")

        try "now it exists".write(to: file, atomically: true, encoding: .utf8)
        let asset = try XCTUnwrap(PatchworkWeb.resolvedAsset(forSitePath: "/\(name)", siteRoot: root))
        XCTAssertEqual(String(decoding: asset.data, as: UTF8.self), "now it exists", "a prior miss must not have poisoned the cache")
    }

    // MARK: - ETag

    func testETagIsQuotedPerRFC9110() {
        let tag = PatchworkWeb.etag(for: Data("hello".utf8))
        XCTAssertTrue(tag.hasPrefix("\""))
        XCTAssertTrue(tag.hasSuffix("\""))
    }

    func testETagIsContentAddressedNotPathAddressed() {
        let a = PatchworkWeb.etag(for: Data("same bytes".utf8))
        let b = PatchworkWeb.etag(for: Data("same bytes".utf8))
        XCTAssertEqual(a, b, "identical content must produce identical ETags")
    }

    func testETagChangesWhenContentChanges() {
        let a = PatchworkWeb.etag(for: Data("version one".utf8))
        let b = PatchworkWeb.etag(for: Data("version two".utf8))
        XCTAssertNotEqual(a, b)
    }

    func testDifferentAssetsInTheBundleHaveDifferentETags() throws {
        let css = try XCTUnwrap(PatchworkWeb.asset(for: "/css/app.css"))
        let js = try XCTUnwrap(PatchworkWeb.asset(for: "/js/app.js"))
        XCTAssertNotEqual(css.etag, js.etag)
    }

    func testRepeatedResolutionOfTheSameRealAssetReturnsTheSameETag() throws {
        let first = try XCTUnwrap(PatchworkWeb.asset(for: "/index.html"))
        let second = try XCTUnwrap(PatchworkWeb.asset(for: "/index.html"))
        XCTAssertEqual(first.etag, second.etag)
    }

    // MARK: - Bounded reads

    func testBoundedContentsAcceptsAFileAtOrUnderTheLimit() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("small.txt")
        try Data(repeating: 0x41, count: 16).write(to: file)

        XCTAssertNotNil(PatchworkWeb.boundedContents(of: file, limit: 16))
        XCTAssertNotNil(PatchworkWeb.boundedContents(of: file, limit: 1024))
    }

    func testBoundedContentsRejectsAFileOverTheLimit() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("big.txt")
        try Data(repeating: 0x41, count: 17).write(to: file)

        XCTAssertNil(PatchworkWeb.boundedContents(of: file, limit: 16), "17 bytes must be rejected by a 16-byte limit")
    }

    func testBoundedContentsRejectsAMissingFile() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertNil(PatchworkWeb.boundedContents(of: missing, limit: 1024))
    }

    /// The real bundled site must comfortably fit under the module's own generous ceiling —
    /// otherwise `maxAssetBytes` would be silently starving real assets.
    func testShippedAssetsAreWellUnderTheDefaultLimit() throws {
        let asset = try XCTUnwrap(PatchworkWeb.asset(for: "/index.html"))
        XCTAssertLessThan(asset.data.count, PatchworkWeb.maxAssetBytes)
    }
}
