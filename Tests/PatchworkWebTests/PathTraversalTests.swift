import XCTest
@testable import PatchworkWeb

/// Hard path-traversal protection, exercised two ways: the public `asset(for:)` entry point
/// against a battery of hostile request paths (proving the server-visible behavior never
/// discloses anything outside `Site/`), and the internal `containedFileURL` helper against a
/// throwaway directory containing a real symlink escape (proving the containment check itself,
/// independent of what happens to be bundled today).
final class PathTraversalTests: XCTestCase {

    /// A wide set of traversal attempts: plain `..`, single- and double-percent-encoded `..`,
    /// encoded path separators, mixed and upper-case hex, backslash separators, NUL-byte
    /// smuggling, invalid/overlong UTF-8 percent sequences, and naive-filter bypass attempts.
    /// Every one of these must resolve to the exact same SPA shell as any other unknown route —
    /// never to file content, never to a crash, never to a distinguishable "found it" signal.
    private static let hostilePaths = [
        "/../etc/passwd",
        "/../../etc/passwd",
        "/../../../../../../../../etc/passwd",
        "/./../etc/passwd",
        "/foo/../../bar/../../etc/passwd",
        "/js/../../../../../etc/passwd",
        "/%2e%2e/%2e%2e/etc/passwd",
        "/%2E%2E/%2E%2E/etc/passwd",
        "/..%2f..%2fetc%2fpasswd",
        "/..%2F..%2Fetc%2Fpasswd",
        "/%2e%2e%2f%2e%2e%2fetc%2fpasswd",
        "/%252e%252e/%252e%252e/etc/passwd",
        "//etc/passwd",
        "/....//....//etc/passwd",
        "/..\\..\\etc\\passwd",
        "/index.html%00.js",
        "/%00/etc/passwd",
        "/%c0%ae%c0%ae/etc/passwd",
        "/..",
        "/../",
        "/%2e%2e"
    ]

    func testHostilePathsAllFallBackToTheSameSafeShell() throws {
        let index = try XCTUnwrap(PatchworkWeb.asset(for: "/"))
        for path in Self.hostilePaths {
            let asset = try XCTUnwrap(PatchworkWeb.asset(for: path), "hostile path \(path) should still resolve to the SPA shell, not nil")
            XCTAssertEqual(asset, index, "hostile path \(path) must not resolve to anything other than index.html")
        }
    }

    func testSafeRelativeComponentsRejectsDotDotSegmentsOutright() {
        XCTAssertNil(PatchworkWeb.safeRelativeComponents(of: "/../etc/passwd"))
        XCTAssertNil(PatchworkWeb.safeRelativeComponents(of: "/a/../../b"))
        XCTAssertNil(PatchworkWeb.safeRelativeComponents(of: "/%2e%2e/x"))
        XCTAssertNil(PatchworkWeb.safeRelativeComponents(of: "/.."))
    }

    func testSafeRelativeComponentsRejectsEmbeddedNUL() {
        XCTAssertNil(PatchworkWeb.safeRelativeComponents(of: "/index.html%00.js"))
    }

    func testSafeRelativeComponentsRejectsPathsNotStartingWithSlash() {
        XCTAssertNil(PatchworkWeb.safeRelativeComponents(of: "index.html"))
        XCTAssertNil(PatchworkWeb.safeRelativeComponents(of: ""))
    }

    func testSafeRelativeComponentsAcceptsOrdinaryNestedPaths() {
        XCTAssertEqual(PatchworkWeb.safeRelativeComponents(of: "/js/app.js"), ["js", "app.js"])
        XCTAssertEqual(PatchworkWeb.safeRelativeComponents(of: "/"), ["index.html"])
        XCTAssertEqual(PatchworkWeb.safeRelativeComponents(of: "/./js/./app.js"), ["js", "app.js"])
    }

    func testDoubleEncodedTraversalDecodesOnceIntoALiteralNonMatchingName() {
        // A single decode pass turns "%252e%252e" into the literal characters "%2e%2e" — not
        // ".." — so it must NOT be rejected by the ".." segment check; it simply fails to match
        // any real file and falls through to the SPA fallback in the full pipeline (proven by
        // testHostilePathsAllFallBackToTheSameSafeShell above). This test pins that exact
        // single-pass decoding behavior so a future change cannot silently reintroduce a second
        // decode pass (the classic double-encoding bypass).
        let components = PatchworkWeb.safeRelativeComponents(of: "/%252e%252e/x")
        XCTAssertEqual(components, ["%2e%2e", "x"])
    }

    // MARK: - Symlink escape (containment check, independent of the shipped bundle)

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-web-traversal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testContainedFileURLRejectsASymlinkThatEscapesTheRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("secret.txt")
        try "top secret".write(to: secret, atomically: true, encoding: .utf8)

        let escapeLink = root.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: secret)

        XCTAssertNil(PatchworkWeb.containedFileURL(components: ["escape.txt"], root: root))
    }

    func testContainedFileURLRejectsASymlinkedDirectoryEscape() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("secret.txt")
        try "top secret".write(to: secret, atomically: true, encoding: .utf8)

        let linkedDir = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedDir, withDestinationURL: outside)

        XCTAssertNil(PatchworkWeb.containedFileURL(components: ["linked", "secret.txt"], root: root))
    }

    func testContainedFileURLAcceptsARegularFileInsideRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("real.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let resolved = PatchworkWeb.containedFileURL(components: ["real.txt"], root: root)
        XCTAssertEqual(resolved?.lastPathComponent, "real.txt")
    }

    func testContainedFileURLAcceptsASymlinkThatStaysInsideRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("real.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        XCTAssertNotNil(PatchworkWeb.containedFileURL(components: ["alias.txt"], root: root))
    }

    func testContainedFileURLRejectsADirectory() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("subdir"), withIntermediateDirectories: true)

        XCTAssertNil(PatchworkWeb.containedFileURL(components: ["subdir"], root: root))
    }

    func testContainedFileURLRejectsAMissingFile() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(PatchworkWeb.containedFileURL(components: ["nope.txt"], root: root))
    }

    /// A sibling directory that merely shares a string prefix with the root ("site" vs.
    /// "site-evil") must not pass a naive `hasPrefix` containment check.
    func testContainedFileURLRejectsPrefixCollisionSibling() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("site")
        let sibling = base.appendingPathComponent("site-evil")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let siblingSecret = sibling.appendingPathComponent("secret.txt")
        try "nope".write(to: siblingSecret, atomically: true, encoding: .utf8)

        let link = root.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: siblingSecret)

        XCTAssertNil(PatchworkWeb.containedFileURL(components: ["escape.txt"], root: root))
    }
}
