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

    /// The extension's loading placeholder is not an account: it must not be shown as though
    /// it were one, so the caller can fall back to the last known good value instead.
    func testLoadingPlaceholderIsNotTreatedAsAnAccount() {
        XCTAssertNil(ExtensionStatusParser.codexAccount("Codex account: loading"))
        XCTAssertNil(ExtensionStatusParser.codexAccount("CODEX ACCOUNT: LOADING\u{2026}"))
    }

    /// Any other diagnostic text the extension might emit — not just the one documented
    /// "loading" string — must degrade the same way: free text with no window data and no
    /// email-shaped identifier is not distinguishable from an account name, so it is rejected
    /// rather than risk showing status text as though it were an identity.
    func testUndocumentedDegradedShapesAreRejectedTheSameWay() {
        XCTAssertNil(ExtensionStatusParser.codexAccount("initializing"))
        XCTAssertNil(ExtensionStatusParser.codexAccount("Signed out"))
        XCTAssertNil(ExtensionStatusParser.codexAccount("Codex account unavailable"))
    }

    /// Real usage numbers are trustworthy even without a name attached — that is genuine data,
    /// not a placeholder, so it still resolves (with a neutral label standing in for the name).
    func testWindowsWithoutAnAccountNameStillParse() {
        let value = try! XCTUnwrap(ExtensionStatusParser.codexAccount("5h:40% 7d:80%"))
        XCTAssertEqual(value.account, "Codex account")
        XCTAssertEqual(value.windows.count, 2)
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

    /// `ponytail` is a real, named extension — not just an arbitrary unknown key — but it has
    /// never been in `specialKeys`, so it has always been generic-chip-only. Named explicitly
    /// here because the footer bar stopped rendering any generic chip: this is what proves
    /// ponytail (and anything else generic) is still reachable for the inspector and nowhere
    /// else.
    func testPonytailIsAGenericChipNeverASpecialOne() {
        let model = ExtensionStatusModel(values: [
            "codex-account": "a@b.co 5h:78%",
            "ponytail": "\u{26A1} FULL"
        ], isLive: true)
        XCTAssertEqual(model.genericChips.map(\.key), ["ponytail"])
        XCTAssertFalse(ExtensionStatusParser.specialKeys.contains("ponytail"))
    }

    func testEmptyGenericValuesAreDropped() {
        let model = ExtensionStatusModel(values: ["a": "", "b": "value"], isLive: false)
        XCTAssertEqual(model.genericChips.map(\.key), ["b"])
        XCTAssertFalse(model.isEmpty)
        XCTAssertTrue(ExtensionStatusModel().isEmpty)
    }
}

final class CodexAccountResolutionTests: XCTestCase {
    private let good = CodexAccountStatus(account: "a@b.co", windows: [CodexUsageWindow(label: "5h", remainingPercent: 78)], bankedResetCount: nil, bankedResetExpiry: nil)

    func testFreshDataIsNeverStale() {
        let resolved = CodexAccountResolution.resolve(raw: "a@b.co 5h:78%", previousGood: nil)
        XCTAssertEqual(resolved?.status.account, "a@b.co")
        XCTAssertEqual(resolved?.isStale, false)
    }

    func testDegradedRawFallsBackToPreviousGoodMarkedStale() {
        let resolved = CodexAccountResolution.resolve(raw: "Codex account: loading", previousGood: good)
        XCTAssertEqual(resolved?.status, good)
        XCTAssertEqual(resolved?.isStale, true)
    }

    func testMissingRawAlsoFallsBackToPreviousGood() {
        let resolved = CodexAccountResolution.resolve(raw: nil, previousGood: good)
        XCTAssertEqual(resolved?.status, good)
        XCTAssertEqual(resolved?.isStale, true)
    }

    func testNothingEverKnownResolvesToNilRatherThanAPlaceholder() {
        XCTAssertNil(CodexAccountResolution.resolve(raw: "Codex account: loading", previousGood: nil))
        XCTAssertNil(CodexAccountResolution.resolve(raw: nil, previousGood: nil))
    }

    /// A fresh parse always wins over memory, even if it differs from the last known value —
    /// the account genuinely changed (e.g. signed into a different one).
    func testFreshDataOverridesPreviousGood() {
        let resolved = CodexAccountResolution.resolve(raw: "new@b.co 7d:10%", previousGood: good)
        XCTAssertEqual(resolved?.status.account, "new@b.co")
        XCTAssertEqual(resolved?.isStale, false)
    }

    /// End-to-end through `ExtensionStatusModel`, using an isolated `CodexAccountMemory`
    /// instance so this test never depends on (or pollutes) the shared singleton other call
    /// sites use.
    func testModelRemembersTheLastGoodAccountAcrossAPlaceholderBlip() {
        let memory = CodexAccountMemory()

        let live = ExtensionStatusModel(values: ["codex-account": "a@b.co 5h:78%"], isLive: true)
        let liveResolved = live.resolvedCodexAccount(memory: memory)
        XCTAssertEqual(liveResolved?.status.account, "a@b.co")
        XCTAssertEqual(liveResolved?.isStale, false)
        XCTAssertEqual(memory.lastGood?.account, "a@b.co", "A fresh parse is remembered immediately")

        let loading = ExtensionStatusModel(values: ["codex-account": "Codex account: loading"], isLive: true)
        let loadingResolved = loading.resolvedCodexAccount(memory: memory)
        XCTAssertEqual(loadingResolved?.status.account, "a@b.co", "Stays on the last real account instead of a placeholder")
        XCTAssertEqual(loadingResolved?.isStale, true)

        let neverKnown = ExtensionStatusModel(values: ["codex-account": "Codex account: loading"], isLive: true)
        XCTAssertNil(neverKnown.resolvedCodexAccount(memory: CodexAccountMemory()), "A fresh instance with nothing remembered shows nothing, not a placeholder")
    }

    func testMemoryRememberOverwritesThePreviousValue() {
        let memory = CodexAccountMemory(lastGood: good)
        let newer = CodexAccountStatus(account: "c@d.co", windows: [], bankedResetCount: nil, bankedResetExpiry: nil)
        memory.remember(newer)
        XCTAssertEqual(memory.lastGood, newer)
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
