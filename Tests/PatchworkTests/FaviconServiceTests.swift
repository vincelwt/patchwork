import Foundation
import XCTest
@testable import Patchwork

/// A fake fetcher so these tests never touch the network (the repo rule) while still exercising
/// the service's own caching, dedupe, and bounds logic against a controllable source.
private actor FakeFetcher: FaviconFetching {
    private(set) var requestedHosts: [String] = []
    private var responses: [String: Data]
    private var delayNanoseconds: UInt64
    private(set) var concurrentCallCount = 0
    private(set) var maxObservedConcurrency = 0

    init(responses: [String: Data] = [:], delayNanoseconds: UInt64 = 0) {
        self.responses = responses
        self.delayNanoseconds = delayNanoseconds
    }

    func setResponse(_ data: Data?, for host: String) {
        if let data { responses[host] = data } else { responses.removeValue(forKey: host) }
    }

    func fetchFavicon(host: String, maxBytes: Int) async -> Data? {
        recordStart(host: host)
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        recordEnd()
        let data = response(for: host)
        guard let data, data.count <= maxBytes else { return nil }
        return data
    }

    private func recordStart(host: String) {
        requestedHosts.append(host)
        concurrentCallCount += 1
        maxObservedConcurrency = max(maxObservedConcurrency, concurrentCallCount)
    }

    private func recordEnd() { concurrentCallCount -= 1 }
    private func response(for host: String) -> Data? { responses[host] }
}

@MainActor
final class FaviconServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiFavicons-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFetchesDecodesAndCachesAFavicon() async throws {
        let png = try XCTUnwrap(makePNGData())
        let fetcher = FakeFetcher(responses: ["example.com": png])
        let service = FaviconService(fetcher: fetcher, cacheDirectory: directory)

        let data = await service.imageData(for: try XCTUnwrap(URL(string: "https://example.com/path")))
        XCTAssertEqual(data, png)
        let hosts = await fetcher.requestedHosts
        XCTAssertEqual(hosts, ["example.com"])

        // A second request for the same host must be served from cache, not refetched.
        _ = await service.imageData(for: try XCTUnwrap(URL(string: "https://example.com/other-path")))
        let hostsAfter = await fetcher.requestedHosts
        XCTAssertEqual(hostsAfter, ["example.com"], "The second lookup must hit the in-memory cache")
    }

    func testDiskCachePersistsAcrossServiceInstances() async throws {
        let png = try XCTUnwrap(makePNGData())
        let fetcher = FakeFetcher(responses: ["pi.dev": png])
        let first = FaviconService(fetcher: fetcher, cacheDirectory: directory)
        _ = await first.imageData(for: try XCTUnwrap(URL(string: "https://pi.dev")))

        // A fresh service instance (simulating a relaunch) with a fetcher that now refuses every
        // request must still resolve the icon from disk.
        let refusingFetcher = FakeFetcher()
        let second = FaviconService(fetcher: refusingFetcher, cacheDirectory: directory)
        let data = await second.imageData(for: try XCTUnwrap(URL(string: "https://pi.dev")))
        XCTAssertEqual(data, png)
        let refusedHosts = await refusingFetcher.requestedHosts
        XCTAssertTrue(refusedHosts.isEmpty, "A warm disk cache must never be refetched")
    }

    func testOversizedResponseIsRejectedNotCached() async throws {
        let oversized = Data(repeating: 0x41, count: FaviconService.maxDiskBytes + 1)
        let fetcher = FakeFetcher(responses: ["huge.example": oversized])
        let service = FaviconService(fetcher: fetcher, cacheDirectory: directory)
        let data = await service.imageData(for: try XCTUnwrap(URL(string: "https://huge.example")))
        XCTAssertNil(data, "An oversized favicon must be rejected rather than cached")
    }

    func testMissingFaviconFallsBackToNilGracefully() async throws {
        let fetcher = FakeFetcher()
        let service = FaviconService(fetcher: fetcher, cacheDirectory: directory)
        let data = await service.imageData(for: try XCTUnwrap(URL(string: "https://nofavicon.example")))
        XCTAssertNil(data)
    }

    func testNonHTTPSchemeIsNeverFetched() async throws {
        let fetcher = FakeFetcher()
        let service = FaviconService(fetcher: fetcher, cacheDirectory: directory)
        let data = await service.imageData(for: try XCTUnwrap(URL(string: "file:///etc/hosts")))
        XCTAssertNil(data)
        let hosts = await fetcher.requestedHosts
        XCTAssertTrue(hosts.isEmpty)
    }

    func testConcurrentRequestsForTheSameHostAreDeduplicatedIntoOneFetch() async throws {
        let png = try XCTUnwrap(makePNGData())
        let fetcher = FakeFetcher(responses: ["dedupe.example": png], delayNanoseconds: 50_000_000)
        let service = FaviconService(fetcher: fetcher, cacheDirectory: directory)
        let url = try XCTUnwrap(URL(string: "https://dedupe.example"))

        async let first = service.imageData(for: url)
        async let second = service.imageData(for: url)
        async let third = service.imageData(for: url)
        let results = await [first, second, third]

        XCTAssertEqual(results, [png, png, png])
        let hosts = await fetcher.requestedHosts
        XCTAssertEqual(hosts.count, 1, "Three concurrent lookups for one host must produce exactly one network fetch")
    }

    func testConcurrentFetchesAcrossManyHostsNeverExceedTheCap() async throws {
        let hosts = (0..<12).map { "host\($0).example" }
        var responses: [String: Data] = [:]
        for host in hosts { responses[host] = try XCTUnwrap(makePNGData()) }
        let fetcher = FakeFetcher(responses: responses, delayNanoseconds: 20_000_000)
        let service = FaviconService(fetcher: fetcher, cacheDirectory: directory)

        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask { _ = await service.imageData(for: URL(string: "https://\(host)")!) }
            }
        }

        let maxConcurrency = await fetcher.maxObservedConcurrency
        XCTAssertLessThanOrEqual(maxConcurrency, FaviconService.maxConcurrentFetches, "The fetch cap must never be exceeded")
        let requested = await fetcher.requestedHosts
        XCTAssertEqual(Set(requested), Set(hosts), "Every distinct host is still eventually fetched")
    }

    func testSanitizedFileNameStaysWithinTheCacheDirectory() {
        XCTAssertEqual(FaviconService.sanitizedFileName("example.com"), "example.com")
        XCTAssertFalse(FaviconService.sanitizedFileName("../../etc/passwd").contains("/"))
        XCTAssertFalse(FaviconService.sanitizedFileName("host\0name").contains("\0"))
    }

    func testNormalizedHostLowercasesAndRejectsNonWebSchemes() throws {
        XCTAssertEqual(FaviconService.normalizedHost(try XCTUnwrap(URL(string: "https://Example.COM/x"))), "example.com")
        XCTAssertNil(FaviconService.normalizedHost(try XCTUnwrap(URL(string: "ftp://example.com"))))
        XCTAssertNil(FaviconService.normalizedHost(try XCTUnwrap(URL(string: "mailto:a@example.com"))))
    }

    // MARK: - WebActivityLink extraction

    func testExtractsURLFromWebSearchArguments() {
        let step = TranscriptActivityStep(
            id: "c1", name: "fetch_content", kind: .web,
            arguments: .object(["url": .string("https://example.com/docs?q=1")])
        )
        XCTAssertEqual(WebActivityLink.url(for: step)?.host, "example.com")
    }

    func testExtractsBareDomainArgumentAsAnHTTPSURL() {
        let step = TranscriptActivityStep(
            id: "c1", name: "web_search", kind: .web,
            arguments: .object(["domain": .string("example.com")])
        )
        XCTAssertEqual(WebActivityLink.url(for: step)?.absoluteString, "https://example.com")
    }

    func testFallsBackToAURLFoundInTheResultWhenArgumentsHaveNone() {
        let result = ChatMessage(
            id: "r1", role: .tool,
            blocks: [MessageBlock(id: "b", kind: .text("See https://found-in-result.example/page for details."))],
            timestamp: nil, toolCallID: "c1", raw: .null
        )
        let step = TranscriptActivityStep(id: "c1", name: "web_search", kind: .web, arguments: .object([:]), result: result)
        XCTAssertEqual(WebActivityLink.url(for: step)?.host, "found-in-result.example")
    }

    func testNonWebStepsNeverReportAFavicon() {
        let step = TranscriptActivityStep(
            id: "c1", name: "bash", kind: .commands,
            arguments: .object(["command": .string("curl https://example.com")])
        )
        XCTAssertNil(WebActivityLink.url(for: step), "A non-web tool step must never grow a favicon, even if its text looks like a URL")
    }

    // MARK: - Helpers

    private func makePNGData() -> Data? {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
