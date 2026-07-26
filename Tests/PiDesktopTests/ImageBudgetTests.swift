import Foundation
import XCTest
@testable import PiDesktop

final class ImageBudgetTests: XCTestCase {
    func testCountLimitOmitsExcessImagesBeforeDecoding() {
        var budget = ImageBudget(countLimit: 3, byteLimit: 64 * 1_024 * 1_024)
        XCTAssertTrue(budget.admitEncoded(length: 400))
        XCTAssertTrue(budget.admitEncoded(length: 400))
        XCTAssertTrue(budget.admitEncoded(length: 400))
        XCTAssertFalse(budget.admitEncoded(length: 400))
        XCTAssertEqual(budget.admittedCount, 3)
        XCTAssertEqual(budget.omittedCount, 1)
    }

    func testByteLimitStopsAdmittingBeforeBase64Decode() {
        // 4 MB decoded ceiling: two ~1.5 MB images fit, the third does not.
        var budget = ImageBudget(countLimit: 64, byteLimit: 4 * 1_024 * 1_024)
        let encodedLength = 2 * 1_024 * 1_024 // ~1.5 MB decoded
        XCTAssertTrue(budget.admitEncoded(length: encodedLength))
        XCTAssertTrue(budget.admitEncoded(length: encodedLength))
        XCTAssertFalse(budget.admitEncoded(length: encodedLength))
        XCTAssertLessThanOrEqual(budget.admittedBytes, 4 * 1_024 * 1_024)
    }

    func testSingleOversizedImageIsRejectedRegardlessOfRemainingBudget() {
        var budget = ImageBudget()
        XCTAssertFalse(budget.admitEncoded(length: PiTheme.imageByteLimit * 2 + 1))
        XCTAssertEqual(budget.admittedCount, 0)
    }

    func testReconcileKeepsRunningTotalHonest() {
        var budget = ImageBudget()
        let encodedLength = 4_000
        XCTAssertTrue(budget.admitEncoded(length: encodedLength))
        budget.reconcile(estimatedFrom: encodedLength, actual: 1_000)
        XCTAssertEqual(budget.admittedBytes, 1_000)

        XCTAssertTrue(budget.admitEncoded(length: encodedLength))
        budget.reconcile(estimatedFrom: encodedLength, actual: nil)
        XCTAssertEqual(budget.admittedBytes, 1_000)
        XCTAssertEqual(budget.admittedCount, 1)
        XCTAssertEqual(budget.omittedCount, 1)
    }

    func testDefaultLimitsMatchDocumentedBudget() {
        XCTAssertEqual(ImageBudget.defaultCountLimit, 64)
        XCTAssertEqual(ImageBudget.defaultByteLimit, 64 * 1_024 * 1_024)
        XCTAssertEqual(PiTheme.decodedImageCountLimit, 64)
        XCTAssertEqual(PiTheme.decodedImageByteLimit, 64 * 1_024 * 1_024)
    }
}

final class ConversationLayoutTests: XCTestCase {
    func testInspectorColumnIsOnlyReservedWhenConversationKeepsUsableWidth() {
        let column = ConversationLayout.inspectorColumnWidth
        XCTAssertEqual(column, PiTheme.inspectorWidth + PiTheme.inspectorGutter)

        // Exactly enough room for the conversation column.
        XCTAssertTrue(ConversationLayout.showsInspector(
            requested: true,
            totalWidth: column + PiTheme.conversationMinimumWidth
        ))
        // One point short: the inspector is dropped rather than squeezing the transcript.
        XCTAssertFalse(ConversationLayout.showsInspector(
            requested: true,
            totalWidth: column + PiTheme.conversationMinimumWidth - 1
        ))
        XCTAssertFalse(ConversationLayout.showsInspector(requested: false, totalWidth: 4_000))
    }

    func testDefaultWindowDetailWidthReservesTheInspector() {
        // Default window is 1360 wide with a ~300pt sidebar; the detail column must still fit
        // both the inspector and a usable conversation column.
        let detailWidth: CGFloat = 1_360 - PiTheme.sidebarIdealWidth
        XCTAssertTrue(ConversationLayout.showsInspector(requested: true, totalWidth: detailWidth))
    }
}

final class TokenMetricsTests: XCTestCase {
    func testLatestCacheHitDenominatorIncludesInputReadAndWrite() {
        // 200 read out of 100 input + 200 read + 100 write = 50%.
        XCTAssertEqual(TokenMetrics.cacheHitPercent(input: 100, cacheRead: 200, cacheWrite: 100), 50)
        XCTAssertEqual(TokenMetrics.cacheHitPercent(input: 0, cacheRead: 0, cacheWrite: 100), 0)
        XCTAssertNil(TokenMetrics.cacheHitPercent(input: 0, cacheRead: 0, cacheWrite: 0))

        var metrics = TokenMetrics()
        metrics.addUsage(.object([
            "input": .number(100),
            "output": .number(10),
            "cacheRead": .number(200),
            "cacheWrite": .number(100),
            "cost": .object(["total": .number(0.5)])
        ]))
        XCTAssertEqual(metrics.latestCacheHitPercent, 50)
        XCTAssertEqual(metrics.total, 410)
        XCTAssertEqual(metrics.cost, 0.5, accuracy: 0.0001)
    }

    func testZeroUsageLeavesPreviousCacheHitUntouched() {
        var metrics = TokenMetrics()
        metrics.addUsage(.object(["input": .number(50), "cacheRead": .number(50), "cacheWrite": .number(0)]))
        XCTAssertEqual(metrics.latestCacheHitPercent, 50)
        metrics.addUsage(.object(["output": .number(5)]))
        XCTAssertEqual(metrics.latestCacheHitPercent, 50)
    }
}
