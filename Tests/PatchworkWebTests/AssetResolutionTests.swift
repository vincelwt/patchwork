import XCTest
@testable import PatchworkWeb

/// Covers the public contract against the real bundled `Site/`: known files resolve with the
/// right `Content-Type`, `/` and unknown routes serve the SPA shell, and the control-API prefix
/// is never swallowed into a static response.
final class AssetResolutionTests: XCTestCase {

    func testRootServesIndexAsHTML() throws {
        let asset = try XCTUnwrap(PatchworkWeb.asset(for: "/"))
        XCTAssertEqual(asset.contentType, "text/html; charset=utf-8")
        XCTAssertTrue(String(decoding: asset.data, as: UTF8.self).contains("<!doctype html>"))
    }

    func testEmptyPathAlsoServesIndex() throws {
        let asset = try XCTUnwrap(PatchworkWeb.asset(for: ""))
        XCTAssertEqual(asset, PatchworkWeb.asset(for: "/"))
    }

    func testKnownFilesResolveWithCorrectContentType() throws {
        let expectations: [(String, String)] = [
            ("/index.html", "text/html; charset=utf-8"),
            ("/css/app.css", "text/css; charset=utf-8"),
            ("/js/app.js", "text/javascript; charset=utf-8"),
            ("/js/markdown.mjs", "text/javascript; charset=utf-8"),
            ("/js/liveSync.mjs", "text/javascript; charset=utf-8"),
            ("/js/history.mjs", "text/javascript; charset=utf-8"),
            ("/js/creationIntent.mjs", "text/javascript; charset=utf-8"),
            ("/js/transcript.mjs", "text/javascript; charset=utf-8"),
            ("/manifest.webmanifest", "application/manifest+json"),
            ("/favicon.svg", "image/svg+xml"),
            ("/icons/icon-256.png", "image/png")
        ]
        for (path, contentType) in expectations {
            let asset = try XCTUnwrap(PatchworkWeb.asset(for: path), "expected an asset for \(path)")
            XCTAssertEqual(asset.contentType, contentType, "wrong content type for \(path)")
            XCTAssertFalse(asset.data.isEmpty, "\(path) should not be empty")
        }
    }

    func testThreadListOmitsSignOutControl() throws {
        let asset = try XCTUnwrap(PatchworkWeb.asset(for: "/js/views/threadList.js"))
        let source = String(decoding: asset.data, as: UTF8.self)
        XCTAssertFalse(source.contains(#""aria-label": "Sign out""#))
    }

    func testUnknownRouteFallsBackToIndexForSPARouting() throws {
        let index = try XCTUnwrap(PatchworkWeb.asset(for: "/"))
        for path in ["/thread/abc-123", "/schedules/new", "/settings", "/nope", "/a/b/c"] {
            let asset = try XCTUnwrap(PatchworkWeb.asset(for: path), "expected SPA fallback for \(path)")
            XCTAssertEqual(asset, index, "\(path) should fall back to the same index.html asset")
        }
    }

    func testApiPathsAreNeverServedAsStaticAssets() {
        for path in ["/v1", "/v1/", "/v1/threads", "/v1/threads/abc", "/v1/events"] {
            XCTAssertNil(PatchworkWeb.asset(for: path), "\(path) must be left for the control API router")
        }
    }

    func testPathThatOnlyLooksLikeTheApiPrefixIsNotReserved() throws {
        // "/v1threads" does not match the "/v1/" prefix boundary, so it is just an unknown route.
        let asset = try XCTUnwrap(PatchworkWeb.asset(for: "/v1threads"))
        XCTAssertEqual(asset.contentType, "text/html; charset=utf-8")
    }

    func testQueryStringAndFragmentAreIgnoredWhenResolving() throws {
        XCTAssertEqual(PatchworkWeb.normalizedPath(from: "/js/app.js?v=42"), "/js/app.js")
        XCTAssertEqual(PatchworkWeb.normalizedPath(from: "/thread/1#top"), "/thread/1")
        XCTAssertEqual(PatchworkWeb.normalizedPath(from: ""), "/")
        let withQuery = try XCTUnwrap(PatchworkWeb.asset(for: "/js/app.js?v=42"))
        let withoutQuery = try XCTUnwrap(PatchworkWeb.asset(for: "/js/app.js"))
        XCTAssertEqual(withQuery, withoutQuery)
    }

    // MARK: - MIME mapping (direct, exhaustive over the documented extension list)

    func testContentTypeMapping() {
        XCTAssertEqual(PatchworkWeb.contentType(forExtension: "html"), "text/html; charset=utf-8")
        XCTAssertEqual(PatchworkWeb.contentType(forExtension: "css"), "text/css; charset=utf-8")
        XCTAssertEqual(PatchworkWeb.contentType(forExtension: "js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(PatchworkWeb.contentType(forExtension: "svg"), "image/svg+xml")
        XCTAssertEqual(PatchworkWeb.contentType(forExtension: "png"), "image/png")
        XCTAssertEqual(PatchworkWeb.contentType(forExtension: "webmanifest"), "application/manifest+json")
        XCTAssertEqual(PatchworkWeb.contentType(forExtension: "ico"), "image/x-icon")
    }

    func testContentTypeMappingIsCaseInsensitiveOnExtension() {
        XCTAssertEqual(PatchworkWeb.contentType(forExtension: "HTML"), PatchworkWeb.contentType(forExtension: "html"))
        XCTAssertEqual(PatchworkWeb.contentType(forExtension: "PNG"), PatchworkWeb.contentType(forExtension: "png"))
    }

    func testUnknownExtensionFallsBackToOctetStream() {
        XCTAssertEqual(PatchworkWeb.contentType(forExtension: "xyz"), "application/octet-stream")
        XCTAssertEqual(PatchworkWeb.contentType(forExtension: ""), "application/octet-stream")
    }
}
