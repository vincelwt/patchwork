import Foundation

/// The remote web UI, served by the daemon from bundled resources. Kept as a separate module so
/// the daemon's HTTP layer stays free of asset handling and the site can be tested on its own.
///
/// ## The API the daemon calls
///
/// `PiDeskWeb.asset(for:)` is the only entry point a request handler needs. Pass the request's
/// path (everything before `?`, e.g. `"/"`, `"/app.js"`, `"/thread/abc"` — a leading `?query` or
/// `#fragment` is stripped defensively if present). It always returns something for a path
/// outside the control API: either the exact bundled file or the SPA shell (`index.html`) when
/// the path is unknown, so a static route can be one unconditional call with no not-found branch
/// of its own:
///
/// ```swift
/// if let asset = PiDeskWeb.asset(for: request.path) {
///     if request.header("If-None-Match") == asset.etag {
///         return .notModified
///     }
///     return .ok(body: asset.data, headers: ["Content-Type": asset.contentType, "ETag": asset.etag])
/// }
/// // path started with PiDeskWeb.apiPathPrefix ("/v1/") — route it to the control API instead.
/// ```
///
/// `asset(for:)` returns `nil` only for paths under `PiDeskWeb.apiPathPrefix`. The daemon's own
/// router should never forward those here in the first place; the guard is defense in depth
/// against a routing mistake, not the primary mechanism.
///
/// `Asset.etag` is a strong validator, already double-quoted per RFC 9110, stable for the
/// process lifetime (bundled assets never change while the daemon runs). Comparing it against
/// `If-None-Match` is the entire conditional-request contract; this module does no HTTP itself.
public enum PiDeskWeb {

    /// A file the daemon should return for a request path, already resolved and bounded.
    public struct Asset: Sendable, Equatable {
        public let data: Data
        public let contentType: String
        public let etag: String

        public init(data: Data, contentType: String, etag: String) {
            self.data = data
            self.contentType = contentType
            self.etag = etag
        }
    }

    /// Requests under this prefix belong to the control API (see `docs/daemon-api.md`), never to
    /// the static site. Shared publicly so the daemon's router and this module agree on the one
    /// literal instead of each hardcoding it separately.
    public static let apiPathPrefix = "/v1/"

    /// Resolves a request path to the asset the daemon should serve. See the type-level doc for
    /// the full contract.
    public static func asset(for requestPath: String) -> Asset? {
        let path = normalizedPath(from: requestPath)
        if path == "/v1" || path.hasPrefix(apiPathPrefix) {
            return nil
        }
        if let direct = resolvedAsset(forSitePath: path, siteRoot: siteRoot) {
            return direct
        }
        // SPA fallback. A path that fails resolution for any reason — an unknown client-side
        // route, a typo, or a hostile/malformed input — is indistinguishable here from "unknown
        // route", and index.html is always safe to hand back: nothing outside Site/ is ever
        // disclosed, whatever the reason resolution failed.
        return resolvedAsset(forSitePath: "/index.html", siteRoot: siteRoot)
    }

    // MARK: - Cache

    /// Keyed by the sanitized, joined path relative to the site root — never by the raw request
    /// path. Every successful lookup is one of the bundle's fixed, small set of real files, and
    /// nothing is ever cached for a path that did not resolve, so throwing arbitrary unknown
    /// routes at the server cannot grow this cache: every miss collapses onto the single
    /// `index.html` entry above.
    private static let cache = AssetCache()

    // MARK: - Site root

    private static let siteRoot: URL = {
        let bundleURL = Bundle.module.resourceURL ?? Bundle.module.bundleURL
        return bundleURL.appendingPathComponent("Site", isDirectory: true)
    }()

    // MARK: - Resolution

    /// Strips a query string or fragment a caller may have left attached, and maps an empty path
    /// to the root. Internal (not private) so tests can exercise it directly.
    static func normalizedPath(from requestPath: String) -> String {
        var path = requestPath
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[path.startIndex..<cut])
        }
        return path.isEmpty ? "/" : path
    }

    /// Resolves `sitePath` (already stripped of query/fragment) to a bounded, existing regular
    /// file strictly inside `siteRoot`, reading and memoizing it on first use. Returns `nil` for
    /// anything malformed, escaping, missing, a directory, or oversized; callers decide the
    /// fallback. Takes `siteRoot` as a parameter (rather than reading the static property) so
    /// tests can point it at a throwaway directory instead of the real bundle.
    static func resolvedAsset(forSitePath sitePath: String, siteRoot: URL) -> Asset? {
        guard let relative = safeRelativeComponents(of: sitePath) else { return nil }
        let cacheKey = relative.joined(separator: "/")
        if let cached = cache.get(cacheKey) {
            return cached
        }
        guard let fileURL = containedFileURL(components: relative, root: siteRoot) else {
            return nil
        }
        guard let data = boundedContents(of: fileURL, limit: maxAssetBytes) else { return nil }
        let asset = Asset(
            data: data,
            contentType: contentType(forExtension: fileURL.pathExtension),
            etag: etag(for: data)
        )
        cache.set(cacheKey, asset)
        return asset
    }

    /// Splits a request path into safe path components, or `nil` if the path cannot possibly
    /// name a file under the site root:
    ///
    /// - must start with `/`
    /// - decoded exactly once (never repeated — a double-encoded `..` therefore lands as the
    ///   literal, non-matching filename `%2e%2e` rather than resolving further on a second pass)
    /// - no `..` segment, ever — traversal is rejected outright, not "resolved upward" and
    ///   re-checked; encoded slashes (`%2f`) decode before splitting, so they cannot smuggle a
    ///   segment past this check
    /// - no embedded NUL byte, raw or encoded
    ///
    /// An empty result (root path, or a path that is only slashes/`.` segments) maps to
    /// `index.html`.
    static func safeRelativeComponents(of sitePath: String) -> [String]? {
        guard sitePath.hasPrefix("/") else { return nil }
        guard let decoded = sitePath.removingPercentEncoding else { return nil }
        if decoded.utf8.contains(0) { return nil }

        var components: [String] = []
        for part in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            components.append(String(part))
        }
        return components.isEmpty ? ["index.html"] : components
    }

    /// Joins sanitized components onto `root` and verifies — after resolving symlinks and
    /// standardizing both sides — that the result is still inside `root`. This is the layer that
    /// stops a symlink escape even if a bundled resource were ever replaced by one, independent
    /// of the segment-level `..` rejection above.
    static func containedFileURL(components: [String], root: URL) -> URL? {
        var candidate = root
        for component in components {
            candidate.appendPathComponent(component)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedCandidate.hasPrefix(rootPrefix) else { return nil }

        return candidate
    }

    /// The largest file this module will ever read from disk. The bundled site is a few hundred
    /// KB at most; anything past this is treated as absent rather than risking an unbounded read
    /// from a corrupted or tampered install.
    static let maxAssetBytes = 8 * 1_024 * 1_024

    /// Reads a file's contents, refusing anything over `limit` without ever allocating past it.
    /// `limit` is a parameter (not always `maxAssetBytes`) so tests can prove the bound with a
    /// tiny file instead of constructing multi-megabyte fixtures.
    static func boundedContents(of url: URL, limit: Int) -> Data? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size <= limit else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    // MARK: - Content types

    private static let contentTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "webmanifest": "application/manifest+json",
        "ico": "image/x-icon",
        "json": "application/json; charset=utf-8"
    ]

    /// Maps a file extension (without the dot, any case) to its `Content-Type`. Unknown
    /// extensions fall back to a generic binary type rather than guessing.
    static func contentType(forExtension pathExtension: String) -> String {
        contentTypes[pathExtension.lowercased()] ?? "application/octet-stream"
    }

    // MARK: - ETag

    /// A short, stable content fingerprint, quoted per RFC 9110. Not cryptographic — an ETag
    /// only needs to change when the bytes do, which FNV-1a guarantees well enough for a bundle
    /// of a few dozen small files, with no dependency beyond Foundation.
    static func etag(for data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return "\"\(String(hash, radix: 16, uppercase: false))-\(data.count)\""
    }
}

/// A small thread-safe memoizing cache. `PiDeskWeb.asset(for:)` may be called concurrently from
/// the daemon's HTTP connection handlers, so reads and writes are serialized with a lock; the
/// critical section is a dictionary lookup/insert, never I/O.
private final class AssetCache: @unchecked Sendable {
    private var storage: [String: PiDeskWeb.Asset] = [:]
    private let lock = NSLock()

    func get(_ key: String) -> PiDeskWeb.Asset? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func set(_ key: String, _ asset: PiDeskWeb.Asset) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = asset
    }
}
