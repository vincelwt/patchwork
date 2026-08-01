import AppKit
import PatchworkKit
import SwiftUI

/// Fetches a small favicon for a host referenced by a web/browser tool step and caches it so a
/// domain that appears repeatedly in one transcript is only ever fetched once.
///
/// Endpoint choice: Google's public `s2/favicons` endpoint, not the site's own `/favicon.ico`.
/// A site's own favicon path is unreliable in practice — many hosts have none, redirect, or serve
/// `.ico`/`.svg` bytes `NSImage` does not always decode — while the `s2` endpoint always answers
/// with a small, decodable, uniformly sized PNG (a generic globe when the site has none). That
/// means this service never needs bespoke format sniffing or a distinct "site has no icon" path;
/// a failed/oversized response is the only failure case it has to handle.
///
/// Bounds: an in-memory `NSCache` (count-limited), a byte-capped disk cache under
/// `~/Library/Caches/Patchwork/favicons/`, per-host in-flight de-duplication, and a small
/// concurrent-fetch ceiling so a transcript with many distinct domains cannot start a fetch storm.
/// Network access is behind an injectable `FaviconFetching` so tests never touch the network.
actor FaviconService {
    static let shared = FaviconService(fetcher: URLSessionFaviconFetcher())

    static let memoryCountLimit = 128
    static let maxDiskBytes = 64 * 1_024
    static let maxConcurrentFetches = 4

    private let fetcher: FaviconFetching
    private let cacheDirectory: URL
    private let memoryCache = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var activeFetches = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(fetcher: FaviconFetching, cacheDirectory: URL? = nil) {
        self.fetcher = fetcher
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
        memoryCache.countLimit = Self.memoryCountLimit
    }

    static func defaultCacheDirectory() -> URL {
        PatchworkPaths.cacheDirectory.appendingPathComponent("favicons", isDirectory: true)
    }

    /// Cached or freshly fetched favicon bytes for `url`'s host, or `nil` when unavailable. `Data`
    /// (not `NSImage`) crosses the actor boundary since `NSImage` is not `Sendable`; decoding the
    /// tiny result is cheap enough to happen on the caller's side.
    func imageData(for url: URL) async -> Data? {
        guard let host = Self.normalizedHost(url) else { return nil }
        if let cached = memoryCache.object(forKey: host as NSString) { return cached as Data }
        if let disk = readFromDisk(host: host) {
            memoryCache.setObject(disk as NSData, forKey: host as NSString)
            return disk
        }
        if let existing = inFlight[host] { return await existing.value }

        let task = Task<Data?, Never> { [fetcher] in
            await self.acquireFetchSlot()
            guard !Task.isCancelled else {
                await self.releaseFetchSlot()
                return nil
            }
            let result = await fetcher.fetchFavicon(host: host, maxBytes: Self.maxDiskBytes)
            await self.releaseFetchSlot()
            return result
        }
        inFlight[host] = task
        let data = await task.value
        inFlight[host] = nil
        guard let data, !data.isEmpty, data.count <= Self.maxDiskBytes else { return nil }
        memoryCache.setObject(data as NSData, forKey: host as NSString)
        writeToDisk(data, host: host)
        return data
    }

    // MARK: - Concurrency cap

    /// A counting gate implemented so a hand-off never re-increments: when a slot is released
    /// straight into a waiter, the count is untouched (the waiter now owns it), avoiding the
    /// classic "more than the cap active at once" race a decrement-then-resume version would have.
    private func acquireFetchSlot() async {
        if activeFetches < Self.maxConcurrentFetches {
            activeFetches += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func releaseFetchSlot() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            activeFetches -= 1
        }
    }

    // MARK: - Disk cache

    private func readFromDisk(host: String) -> Data? {
        let url = fileURL(for: host)
        guard let data = try? Data(contentsOf: url), data.count <= Self.maxDiskBytes else { return nil }
        return data
    }

    private func writeToDisk(_ data: Data, host: String) {
        guard data.count <= Self.maxDiskBytes else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: host), options: .atomic)
    }

    private func fileURL(for host: String) -> URL {
        cacheDirectory.appendingPathComponent(Self.sanitizedFileName(host)).appendingPathExtension("png")
    }

    /// Hosts are almost always filename-safe already; this only exists to keep a pathological
    /// host string (or a future non-DNS host form) from ever escaping the cache directory.
    static func sanitizedFileName(_ host: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        let lowered = host.lowercased()
        let cleaned = String(lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "host" : String(cleaned.prefix(200))
    }

    static func normalizedHost(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }
}

/// Network access, isolated behind a protocol so tests can never hit the network (the repo rule)
/// while still exercising the service's caching/dedupe/bounds logic with a fake.
protocol FaviconFetching: Sendable {
    func fetchFavicon(host: String, maxBytes: Int) async -> Data?
}

/// The real fetcher: Google's `s2/favicons` endpoint, capped request timeout, and a hard byte
/// ceiling enforced again here (defense in depth alongside the actor's own check).
struct URLSessionFaviconFetcher: FaviconFetching {
    func fetchFavicon(host: String, maxBytes: Int) async -> Data? {
        var components = URLComponents(string: "https://www.google.com/s2/favicons")
        components?.queryItems = [
            URLQueryItem(name: "sz", value: "64"),
            URLQueryItem(name: "domain", value: host)
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty, data.count <= maxBytes else { return nil }
        return data
    }
}

// MARK: - SwiftUI presentation

/// The favicon glyph shown next to a web/browser transcript row: the fetched site icon once
/// available, a neutral globe otherwise. Fetching is scoped to `.task(id:)`, so it only ever runs
/// while this exact row is actually on screen and cancels automatically when it is not.
struct FaviconView: View {
    let url: URL
    var size: CGFloat = 14
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .task(id: url) {
            image = nil
            guard let data = await FaviconService.shared.imageData(for: url), let decoded = NSImage(data: data) else { return }
            guard !Task.isCancelled else { return }
            image = decoded
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Transcript link extraction

/// Best-effort URL extraction for a `.web`/`.browser` tool step, so its row can show the target
/// site's favicon. Deliberately narrow — a handful of common argument keys, then a regex fallback
/// over any string value found in the arguments or (failing that) the result — rather than a
/// general-purpose JSON walker.
enum WebActivityLink {
    private static let urlPattern = #"https?://[^\s"'<>]+"#

    static func url(for step: TranscriptActivityStep) -> URL? {
        guard step.kind == .web || step.kind == .browser else { return nil }
        if let found = url(in: step.arguments) { return found }
        guard let result = step.result else { return nil }
        for block in result.blocks {
            guard case let .text(text) = block.kind, let found = firstURL(in: text) else { continue }
            return found
        }
        return nil
    }

    private static func url(in value: JSONValue, depth: Int = 0) -> URL? {
        guard depth < 4 else { return nil }
        switch value {
        case let .string(text):
            return firstURL(in: text)
        case let .object(object):
            for key in ["url", "domain", "uri", "link"] {
                if let match = object.first(where: { $0.key.lowercased() == key })?.value.stringValue,
                   let found = firstURL(in: match) ?? bareHostURL(match) {
                    return found
                }
            }
            for key in object.keys.sorted() {
                if let nested = url(in: object[key] ?? .null, depth: depth + 1) { return nested }
            }
        case let .array(values):
            for nested in values.prefix(20) {
                if let found = url(in: nested, depth: depth + 1) { return found }
            }
        default:
            break
        }
        return nil
    }

    private static func firstURL(in text: String) -> URL? {
        guard let range = text.range(of: urlPattern, options: .regularExpression) else { return nil }
        let trimmed = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "),.;\"'"))
        return URL(string: trimmed)
    }

    /// A `domain` argument is often a bare host (`example.com`), not a full URL.
    private static func bareHostURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), trimmed.contains(".") else { return nil }
        return URL(string: "https://\(trimmed)")
    }
}
