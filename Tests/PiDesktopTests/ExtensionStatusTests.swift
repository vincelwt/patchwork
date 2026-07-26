import Foundation
import XCTest
@testable import PiDesktop

final class ANSIStripTests: XCTestCase {
    func testStripsTrueColourSGRSequencesFromARealStatusString() {
        // Verbatim `fast-priority` payload observed over RPC on this machine.
        let raw = "\u{1B}[38;2;138;190;183mfast (inactive)\u{1B}[39m"
        XCTAssertEqual(ANSI.strip(raw), "fast (inactive)")
    }

    func testStripsPonytailStatusKeepingEmojiAndText() {
        let raw = "\u{1B}[38;2;102;102;102m○\u{1B}[39m 🐴 \u{1B}[38;2;128;128;128mponytail: \u{1B}[39m\u{1B}[38;2;212;212;212m⚡ FULL\u{1B}[39m"
        XCTAssertEqual(ANSI.strip(raw), "○ 🐴 ponytail: ⚡ FULL")
    }

    func testStripsOSCSequencesAndControlCharacters() {
        XCTAssertEqual(ANSI.strip("\u{1B}]0;window title\u{07}visible"), "visible")
        XCTAssertEqual(ANSI.strip("\u{1B}]8;;https://pi.dev\u{1B}\\link"), "link")
        XCTAssertEqual(ANSI.strip("a\u{0}b\u{7}c"), "abc")
    }

    func testPlainTextIsUntouched() {
        XCTAssertEqual(ANSI.strip("Chrome ready"), "Chrome ready")
        XCTAssertEqual(ANSI.strip(""), "")
    }
}

final class CodexAccountStatusTests: XCTestCase {
    func testParsesTheDocumentedStatusString() {
        let status = ExtensionStatusParser.codexAccount("vince@example.com 5h:78% 7d:57% reset×2:12h")
        let value = try! XCTUnwrap(status)

        XCTAssertEqual(value.account, "vince@example.com")
        XCTAssertEqual(value.windows, [
            CodexUsageWindow(label: "5h", remainingPercent: 78),
            CodexUsageWindow(label: "7d", remainingPercent: 57)
        ])
        XCTAssertEqual(value.bankedResetCount, 2)
        XCTAssertEqual(value.bankedResetExpiry, "12h")
        XCTAssertEqual(value.tightestWindow?.label, "7d")
        XCTAssertEqual(value.compactRemaining, "7d 57%")
        XCTAssertEqual(value.compactReset, "reset×2:12h")
        XCTAssertEqual(value.compactUsage, "5h:78% 7d:57% reset×2:12h")
        XCTAssertFalse(value.isWarning)
    }

    func testParsesWithoutBankedResets() {
        let value = try! XCTUnwrap(ExtensionStatusParser.codexAccount("a@b.co 5h:100% 7d:99%"))
        XCTAssertNil(value.bankedResetCount)
        XCTAssertNil(value.bankedResetExpiry)
        XCTAssertEqual(value.windows.count, 2)
    }

    func testResetWithoutExpiryTime() {
        let value = try! XCTUnwrap(ExtensionStatusParser.codexAccount("a@b.co 5h:10% reset×1"))
        XCTAssertEqual(value.bankedResetCount, 1)
        XCTAssertNil(value.bankedResetExpiry)
    }

    func testPlainAsciiCrossIsAcceptedToo() {
        let value = try! XCTUnwrap(ExtensionStatusParser.codexAccount("a@b.co 5h:10% resetx3:4h"))
        XCTAssertEqual(value.bankedResetCount, 3)
        XCTAssertEqual(value.bankedResetExpiry, "4h")
    }

    func testLowRemainingReadsAsAWarning() {
        let low = try! XCTUnwrap(ExtensionStatusParser.codexAccount("a@b.co 5h:8% 7d:60%"))
        XCTAssertTrue(low.isLow)
        XCTAssertTrue(low.isWarning)

        let mid = try! XCTUnwrap(ExtensionStatusParser.codexAccount("a@b.co 5h:25% 7d:60%"))
        XCTAssertFalse(mid.isLow)
        XCTAssertTrue(mid.isWarning)
    }

    func testMultiWordAccountNameIsKept() {
        let value = try! XCTUnwrap(ExtensionStatusParser.codexAccount("Vince Loewe 5h:78%"))
        XCTAssertEqual(value.account, "Vince Loewe")
        XCTAssertEqual(value.windows.count, 1)
    }

    func testWindowLabelsWithUnderscoresSurvive() {
        let value = try! XCTUnwrap(ExtensionStatusParser.codexAccount("a@b.co primary:40% secondary:90%"))
        XCTAssertEqual(value.windows.map(\.label), ["primary", "secondary"])
    }

    func testLoadingPlaceholderIsRecognized() {
        let value = try! XCTUnwrap(ExtensionStatusParser.codexAccount("Codex account: loading"))
        XCTAssertTrue(value.windows.isEmpty)
        XCTAssertFalse(value.isWarning)
    }

    func testANSIColouredAccountStatusIsStrippedBeforeParsing() {
        let raw = "\u{1B}[32ma@b.co 5h:78% 7d:57%\u{1B}[39m"
        let value = try! XCTUnwrap(ExtensionStatusParser.codexAccount(raw))
        XCTAssertEqual(value.account, "a@b.co")
        XCTAssertEqual(value.windows.count, 2)
    }

    func testEmptyStatusIsNotAnAccount() {
        XCTAssertNil(ExtensionStatusParser.codexAccount(""))
        XCTAssertNil(ExtensionStatusParser.codexAccount("\u{1B}[39m"))
    }

    func testPercentagesAreClampedIntoZeroToOneHundred() {
        let value = try! XCTUnwrap(ExtensionStatusParser.codexAccount("a@b.co 5h:140% 7d:-20%"))
        XCTAssertEqual(value.windows.map(\.remainingPercent), [100, 0])
        XCTAssertTrue(value.isLow, "A zero-remaining window must read as a warning")
    }

    func testTokensWithoutANumericTailAreTreatedAsAccountText() {
        let value = try! XCTUnwrap(ExtensionStatusParser.codexAccount("a@b.co plan:pro% 5h:80%"))
        XCTAssertEqual(value.windows.map(\.label), ["plan", "5h"].filter { $0 == "5h" })
        XCTAssertEqual(value.account, "a@b.co plan:pro%")
    }
}

final class ModeAndFastStatusTests: XCTestCase {
    func testEveryModeParses() {
        XCTAssertEqual(ExtensionStatusParser.mode("mode:xfast"), .xfast)
        XCTAssertEqual(ExtensionStatusParser.mode("mode:fast"), .fast)
        XCTAssertEqual(ExtensionStatusParser.mode("mode:smart"), .smart)
        XCTAssertEqual(ExtensionStatusParser.mode("mode:ultra"), .ultra)
    }

    func testModeToleratesColourAndBareValue() {
        XCTAssertEqual(ExtensionStatusParser.mode("\u{1B}[36mmode:ultra\u{1B}[39m"), .ultra)
        XCTAssertEqual(ExtensionStatusParser.mode("ULTRA"), .ultra)
    }

    func testUnknownModeIsRejected() {
        XCTAssertNil(ExtensionStatusParser.mode("mode:turbo"))
        XCTAssertNil(ExtensionStatusParser.mode(""))
    }

    func testFastPriorityActiveAndInactive() {
        XCTAssertEqual(ExtensionStatusParser.fastPriority("fast")?.isActive, true)
        XCTAssertEqual(ExtensionStatusParser.fastPriority("fast (inactive)")?.isActive, false)
        XCTAssertEqual(
            ExtensionStatusParser.fastPriority("\u{1B}[38;2;138;190;183mfast (inactive)\u{1B}[39m")?.isActive,
            false
        )
        XCTAssertNil(ExtensionStatusParser.fastPriority(""))
        XCTAssertNil(ExtensionStatusParser.fastPriority("slow"))
    }
}

final class ExtensionStatusModelTests: XCTestCase {
    func testSpecialKeysAreExcludedFromGenericChipsButUnknownKeysAreKept() {
        let model = ExtensionStatusModel(values: [
            "codex-account": "a@b.co 5h:78%",
            "mode": "mode:ultra",
            "fast-priority": "fast",
            "chrome": "Chrome ready",
            "brand-new-extension": "Something happened"
        ], isLive: true)

        XCTAssertEqual(model.mode, .ultra)
        XCTAssertEqual(model.fastPriority?.isActive, true)
        XCTAssertEqual(model.codexAccount?.account, "a@b.co")
        XCTAssertEqual(model.genericChips.map(\.key), ["brand-new-extension", "chrome"])
        XCTAssertEqual(model.genericChips.map(\.value), ["Something happened", "Chrome ready"])
    }

    func testEmptyGenericValuesAreDropped() {
        let model = ExtensionStatusModel(values: ["a": "", "b": "value"], isLive: false)
        XCTAssertEqual(model.genericChips.map(\.key), ["b"])
        XCTAssertFalse(model.isEmpty)
        XCTAssertTrue(ExtensionStatusModel().isEmpty)
    }
}

final class MessageSanitizationTests: XCTestCase {
    func testAttachmentPlaceholdersAreStrippedFromTheSentMessage() {
        XCTAssertEqual(AppStore.sanitizedMessage("look at this \u{FFFC}"), "look at this")
        XCTAssertEqual(AppStore.sanitizedMessage("\u{FFFC}\u{FFFC}"), "")
        XCTAssertEqual(AppStore.sanitizedMessage("  text  "), "text")
        XCTAssertEqual(AppStore.sanitizedMessage("a\u{FFFC}b"), "ab")
    }
}
