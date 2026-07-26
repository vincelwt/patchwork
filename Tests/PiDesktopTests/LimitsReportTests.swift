import Foundation
import XCTest
@testable import PiDesktop

final class LimitsReportParserTests: XCTestCase {
    private let sample = """
    vince@example.com
      Email: vince@example.com
      Plan: pro
      5h: 78% remaining \u{B7} resets 12h
      7d: 57% remaining
      2 banked resets, first expires in 12h
    work@example.com
      Unable to load limits: network error
    """

    func testParsesMultipleAccountsWithWindowsAndNotes() {
        let report = LimitsReportParser.parse(sample)
        XCTAssertEqual(report.accounts.count, 2)

        let first = report.accounts[0]
        XCTAssertEqual(first.name, "vince@example.com")
        XCTAssertEqual(first.email, "vince@example.com")
        XCTAssertEqual(first.plan, "pro")
        XCTAssertEqual(first.windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(first.windows[0].remainingPercent, 78)
        XCTAssertEqual(first.windows[0].resets, "12h")
        XCTAssertEqual(first.windows[1].remainingPercent, 57)
        XCTAssertEqual(first.notes, ["2 banked resets, first expires in 12h"])

        let second = report.accounts[1]
        XCTAssertEqual(second.name, "work@example.com")
        XCTAssertEqual(second.error, "network error")
    }

    func testEmptyTextParsesToAnEmptyReport() {
        XCTAssertTrue(LimitsReportParser.parse("").isEmpty)
        XCTAssertTrue(LimitsReportParser.parse("   \n  ").isEmpty)
    }

    func testReportIsBoundedRegardlessOfInputSize() {
        var lines: [String] = []
        for accountIndex in 0..<20 {
            lines.append("account-\(accountIndex)@example.com")
            for windowIndex in 0..<20 {
                lines.append("  w\(windowIndex): 50% remaining")
            }
        }
        let report = LimitsReportParser.parse(lines.joined(separator: "\n"))
        XCTAssertLessThanOrEqual(report.accounts.count, 8)
        XCTAssertTrue(report.accounts.allSatisfy { $0.windows.count <= 8 })
    }
}

/// The staleness policy shared by the hover trigger and the periodic background tick.
final class LimitsRefreshPolicyTests: XCTestCase {
    private let now = Date()

    func testNeverRefreshesWithoutARefreshAction() {
        XCTAssertFalse(LimitsRefreshPolicy.shouldRefresh(
            now: now, appActive: true, hasRefreshAction: false,
            lastRequestedAt: nil, reportGeneratedAt: nil, staleAfter: 300
        ))
    }

    func testNeverRefreshesWhileTheAppIsInactive() {
        XCTAssertFalse(LimitsRefreshPolicy.shouldRefresh(
            now: now, appActive: false, hasRefreshAction: true,
            lastRequestedAt: nil, reportGeneratedAt: nil, staleAfter: 300
        ))
    }

    func testRefreshesImmediatelyWithNoPriorRequestOrReport() {
        XCTAssertTrue(LimitsRefreshPolicy.shouldRefresh(
            now: now, appActive: true, hasRefreshAction: true,
            lastRequestedAt: nil, reportGeneratedAt: nil, staleAfter: 300
        ))
    }

    func testWithholdsAnotherRequestUntilTheLastOneAges() {
        XCTAssertFalse(LimitsRefreshPolicy.shouldRefresh(
            now: now, appActive: true, hasRefreshAction: true,
            lastRequestedAt: now.addingTimeInterval(-60), reportGeneratedAt: nil, staleAfter: 300
        ))
        XCTAssertTrue(LimitsRefreshPolicy.shouldRefresh(
            now: now, appActive: true, hasRefreshAction: true,
            lastRequestedAt: now.addingTimeInterval(-301), reportGeneratedAt: nil, staleAfter: 300
        ))
    }

    func testWithholdsWhenTheReportItselfIsStillFresh() {
        XCTAssertFalse(LimitsRefreshPolicy.shouldRefresh(
            now: now, appActive: true, hasRefreshAction: true,
            lastRequestedAt: nil, reportGeneratedAt: now.addingTimeInterval(-100), staleAfter: 300
        ))
        XCTAssertTrue(LimitsRefreshPolicy.shouldRefresh(
            now: now, appActive: true, hasRefreshAction: true,
            lastRequestedAt: nil, reportGeneratedAt: now.addingTimeInterval(-400), staleAfter: 300
        ))
    }
}

@MainActor
final class LimitsReportStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiDesktopLimits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(active: Bool = true) -> LimitsReportStore {
        LimitsReportStore(diskCache: LimitsReportDiskCache(fileURL: directory.appendingPathComponent("cache.json")), isActiveOverride: active)
    }

    func testRefreshIfStaleRespectsTheStalenessWindowWithAnInjectedClock() {
        let store = makeStore()
        var callCount = 0
        store.refreshAction = { callCount += 1 }

        let t0 = Date()
        store.refreshIfStale(now: t0)
        XCTAssertEqual(callCount, 1, "Nothing requested yet and no report yet: refreshes immediately")

        store.refreshIfStale(now: t0.addingTimeInterval(30))
        XCTAssertEqual(callCount, 1, "Well inside the staleness window: no second request")

        store.refreshIfStale(now: t0.addingTimeInterval(301))
        XCTAssertEqual(callCount, 2, "Past the staleness window: refreshes again")
    }

    func testRefreshIfStaleNeverFiresWhileInactive() {
        let store = makeStore(active: false)
        var callCount = 0
        store.refreshAction = { callCount += 1 }
        store.refreshIfStale()
        XCTAssertEqual(callCount, 0)
    }

    func testApplyPersistsAndReloadingAFreshStoreSeesItImmediately() throws {
        let fileURL = directory.appendingPathComponent("cache.json")
        let storeA = LimitsReportStore(diskCache: LimitsReportDiskCache(fileURL: fileURL), isActiveOverride: true)
        XCTAssertNil(storeA.report, "Nothing persisted yet")

        storeA.apply(text: "vince@example.com\n  5h: 78% remaining")
        let persisted = try XCTUnwrap(storeA.report)
        XCTAssertEqual(persisted.accounts.first?.name, "vince@example.com")

        // A brand-new store pointed at the same file simulates a relaunch: it must render from
        // the cache instantly, before any runtime has answered a fresh `/limits` request.
        let storeB = LimitsReportStore(diskCache: LimitsReportDiskCache(fileURL: fileURL), isActiveOverride: true)
        XCTAssertEqual(storeB.report?.accounts.first?.name, "vince@example.com")
    }

    func testApplyWithNoAccountsSetsAnErrorButKeepsTheExistingReport() throws {
        let store = makeStore()
        store.apply(text: "vince@example.com\n  5h: 78% remaining")
        XCTAssertNotNil(store.report)

        store.apply(text: "")
        XCTAssertNotNil(store.report, "An empty/failed parse must not blank out a good cached report")
        XCTAssertEqual(store.lastError, "No accounts reported")
    }

    func testFailSetsAMessageWithoutTouchingTheCachedReport() {
        let store = makeStore()
        store.apply(text: "vince@example.com\n  5h: 78% remaining")
        store.fail("Open a conversation to load the full report")
        XCTAssertNotNil(store.report)
        XCTAssertEqual(store.lastError, "Open a conversation to load the full report")
        XCTAssertFalse(store.isLoading)
    }
}

/// Codable round-trip for the disk cache itself, independent of `LimitsReportStore`.
final class LimitsReportDiskCacheTests: XCTestCase {
    func testSaveThenLoadRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LimitsReportDiskCache(fileURL: directory.appendingPathComponent("nested/cache.json"))

        XCTAssertNil(cache.load(), "Nothing written yet")

        let report = LimitsReportParser.parse("vince@example.com\n  5h: 78% remaining \u{B7} resets 12h")
        cache.save(report)
        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.accounts, report.accounts)
    }

    func testLoadFromAMissingFileIsNilNotACrash() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)/cache.json")
        XCTAssertNil(LimitsReportDiskCache(fileURL: url).load())
    }
}
