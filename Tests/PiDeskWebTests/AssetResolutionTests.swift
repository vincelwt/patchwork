import XCTest
@testable import PiDeskWeb

/// Covers the public contract against the real bundled `Site/`: known files resolve with the
/// right `Content-Type`, `/` and unknown routes serve the SPA shell, and the control-API prefix
/// is never swallowed into a static response.
final class AssetResolutionTests: XCTestCase {

    func testRootServesIndexAsHTML() throws {
        let asset = try XCTUnwrap(PiDeskWeb.asset(for: "/"))
        XCTAssertEqual(asset.contentType, "text/html; charset=utf-8")
        XCTAssertTrue(String(decoding: asset.data, as: UTF8.self).contains("<!doctype html>"))
    }

    func testEmptyPathAlsoServesIndex() throws {
        let asset = try XCTUnwrap(PiDeskWeb.asset(for: ""))
        XCTAssertEqual(asset, PiDeskWeb.asset(for: "/"))
    }

    func testKnownFilesResolveWithCorrectContentType() throws {
        let expectations: [(String, String)] = [
            ("/index.html", "text/html; charset=utf-8"),
            ("/css/app.css", "text/css; charset=utf-8"),
            ("/js/app.js", "text/javascript; charset=utf-8"),
            ("/js/markdown.mjs", "text/javascript; charset=utf-8"),
            ("/manifest.webmanifest", "application/manifest+json"),
            ("/favicon.svg", "image/svg+xml"),
            ("/icons/icon-256.png", "image/png")
        ]
        for (path, contentType) in expectations {
            let asset = try XCTUnwrap(PiDeskWeb.asset(for: path), "expected an asset for \(path)")
            XCTAssertEqual(asset.contentType, contentType, "wrong content type for \(path)")
            XCTAssertFalse(asset.data.isEmpty, "\(path) should not be empty")
        }
    }

    func testUnknownRouteFallsBackToIndexForSPARouting() throws {
        let index = try XCTUnwrap(PiDeskWeb.asset(for: "/"))
        for path in ["/thread/abc-123", "/schedules/new", "/settings", "/nope", "/a/b/c"] {
            let asset = try XCTUnwrap(PiDeskWeb.asset(for: path), "expected SPA fallback for \(path)")
            XCTAssertEqual(asset, index, "\(path) should fall back to the same index.html asset")
        }
    }

    func testApiPathsAreNeverServedAsStaticAssets() {
        for path in ["/v1", "/v1/", "/v1/threads", "/v1/threads/abc", "/v1/events"] {
            XCTAssertNil(PiDeskWeb.asset(for: path), "\(path) must be left for the control API router")
        }
    }

    func testPathThatOnlyLooksLikeTheApiPrefixIsNotReserved() throws {
        // "/v1threads" does not match the "/v1/" prefix boundary, so it is just an unknown route.
        let asset = try XCTUnwrap(PiDeskWeb.asset(for: "/v1threads"))
        XCTAssertEqual(asset.contentType, "text/html; charset=utf-8")
    }

    func testQueryStringAndFragmentAreIgnoredWhenResolving() throws {
        XCTAssertEqual(PiDeskWeb.normalizedPath(from: "/js/app.js?v=42"), "/js/app.js")
        XCTAssertEqual(PiDeskWeb.normalizedPath(from: "/thread/1#top"), "/thread/1")
        XCTAssertEqual(PiDeskWeb.normalizedPath(from: ""), "/")
        let withQuery = try XCTUnwrap(PiDeskWeb.asset(for: "/js/app.js?v=42"))
        let withoutQuery = try XCTUnwrap(PiDeskWeb.asset(for: "/js/app.js"))
        XCTAssertEqual(withQuery, withoutQuery)
    }

    // MARK: - MIME mapping (direct, exhaustive over the documented extension list)

    func testContentTypeMapping() {
        XCTAssertEqual(PiDeskWeb.contentType(forExtension: "html"), "text/html; charset=utf-8")
        XCTAssertEqual(PiDeskWeb.contentType(forExtension: "css"), "text/css; charset=utf-8")
        XCTAssertEqual(PiDeskWeb.contentType(forExtension: "js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(PiDeskWeb.contentType(forExtension: "svg"), "image/svg+xml")
        XCTAssertEqual(PiDeskWeb.contentType(forExtension: "png"), "image/png")
        XCTAssertEqual(PiDeskWeb.contentType(forExtension: "webmanifest"), "application/manifest+json")
        XCTAssertEqual(PiDeskWeb.contentType(forExtension: "ico"), "image/x-icon")
    }

    func testContentTypeMappingIsCaseInsensitiveOnExtension() {
        XCTAssertEqual(PiDeskWeb.contentType(forExtension: "HTML"), PiDeskWeb.contentType(forExtension: "html"))
        XCTAssertEqual(PiDeskWeb.contentType(forExtension: "PNG"), PiDeskWeb.contentType(forExtension: "png"))
    }

    func testUnknownExtensionFallsBackToOctetStream() {
        XCTAssertEqual(PiDeskWeb.contentType(forExtension: "xyz"), "application/octet-stream")
        XCTAssertEqual(PiDeskWeb.contentType(forExtension: ""), "application/octet-stream")
    }
}
