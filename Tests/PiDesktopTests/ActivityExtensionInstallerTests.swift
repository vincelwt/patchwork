import Foundation
import XCTest
@testable import PiDesktop

final class ActivityExtensionInstallerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiActivityInstaller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func source(version: Int, marker: String? = nil) -> String {
        "\(marker ?? ActivityExtensionInstaller.versionMarkerPrefix) \(version)\nexport default function () {}\n"
    }

    // MARK: - Pure version/decision logic

    func testVersionExtractionFindsTheMarkerAndIgnoresUnrelatedLines() {
        let text = "// some header\n// pi-desktop-activity-version: 3\nexport default function () {}\n"
        XCTAssertEqual(ActivityExtensionInstaller.version(of: text), 3)
    }

    func testVersionExtractionReturnsNilWithoutAMarker() {
        XCTAssertNil(ActivityExtensionInstaller.version(of: "export default function () {}\n"))
    }

    func testDecideInstallsWhenNothingIsThereYet() {
        XCTAssertEqual(ActivityExtensionInstaller.decide(installed: nil, bundled: source(version: 1)), .installed)
    }

    func testDecideUpgradesAnOlderInstalledVersion() {
        XCTAssertEqual(
            ActivityExtensionInstaller.decide(installed: source(version: 1), bundled: source(version: 2)),
            .upgraded
        )
    }

    func testBundledVersionUpgradesThePreviousDevelopmentInstall() throws {
        let bundled = try XCTUnwrap(ActivityExtensionInstaller.bundledSource())
        XCTAssertEqual(
            ActivityExtensionInstaller.decide(installed: source(version: 17), bundled: bundled),
            .upgraded
        )
    }

    func testDecideLeavesAnUpToDateOrNewerInstalledVersionAlone() {
        XCTAssertEqual(ActivityExtensionInstaller.decide(installed: source(version: 2), bundled: source(version: 2)), .upToDate)
        XCTAssertEqual(ActivityExtensionInstaller.decide(installed: source(version: 3), bundled: source(version: 2)), .upToDate)
    }

    func testDecideNeverOverwritesAFileWithoutARecognizedMarker() {
        // A user's own file at this path, or a marker Pi Desktop cannot parse: never clobber it.
        XCTAssertEqual(
            ActivityExtensionInstaller.decide(installed: "// hand-written\nexport default function () {}\n", bundled: source(version: 1)),
            .skippedUserModified
        )
    }

    // MARK: - Disk I/O, fully sandboxed to a temp destination

    func testRunInstallsWhenMissingThenReportsUpToDateOnTheNextRun() {
        let destination = directory.appendingPathComponent("nested/pi-desktop-activity.ts")
        let first = ActivityExtensionInstaller.run(isDisabled: false, destination: destination)
        XCTAssertEqual(first, .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let written = try? String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(written, ActivityExtensionInstaller.bundledSource())

        let second = ActivityExtensionInstaller.run(isDisabled: false, destination: destination)
        XCTAssertEqual(second, .upToDate, "The same version must not be rewritten every launch")
    }

    func testRunNeverWritesWhenDisabled() {
        let destination = directory.appendingPathComponent("pi-desktop-activity.ts")
        XCTAssertEqual(ActivityExtensionInstaller.run(isDisabled: true, destination: destination), .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRunNeverOverwritesAHandEditedFileEvenIfStillPresentAfter() throws {
        let destination = directory.appendingPathComponent("pi-desktop-activity.ts")
        let handEdited = "// a user's own extension\nexport default function () {}\n"
        try handEdited.write(to: destination, atomically: true, encoding: .utf8)

        let outcome = ActivityExtensionInstaller.run(isDisabled: false, destination: destination)
        XCTAssertEqual(outcome, .skippedUserModified)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), handEdited)
    }

    func testBundledSourcePreservesExternalRunState() throws {
        // An idle RPC attachment or a background subagent must not make its parent look idle.
        let bundled = try XCTUnwrap(ActivityExtensionInstaller.bundledSource())
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(ActivityExtensionInstaller.version(of: bundled)), 3)
        XCTAssertTrue(bundled.contains("${sessionId}-${process.pid}.json"))
        XCTAssertTrue(bundled.contains("subagents:created"))
        XCTAssertTrue(bundled.contains("subagents:completed"))
    }

    func testBundledExtensionLetsPiNameANewConversation() throws {
        let bundled = try XCTUnwrap(ActivityExtensionInstaller.bundledSource())
        XCTAssertEqual(ActivityExtensionInstaller.version(of: bundled), 18)
        XCTAssertTrue(bundled.contains("name: \"set_conversation_name\""))
        XCTAssertTrue(bundled.contains("After understanding the first user message"))
        XCTAssertTrue(bundled.contains("const current = pi.getSessionName()"))
        XCTAssertTrue(bundled.contains("pi.setSessionName(name)"))
    }

    func testBundledExtensionRoutesThreadSchedulesToDesktopAutomations() throws {
        let bundled = try XCTUnwrap(ActivityExtensionInstaller.bundledSource())
        XCTAssertEqual(ActivityExtensionInstaller.version(of: bundled), 18)
        XCTAssertTrue(bundled.contains("name: \"schedule_automation\""))
        XCTAssertTrue(bundled.contains("rely on durable thread history"))
        XCTAssertTrue(bundled.contains("appended to this conversation"))
        XCTAssertTrue(bundled.contains("/v1/schedules"))
        XCTAssertTrue(bundled.contains("event.toolName.toLowerCase() !== \"agent\""))
        XCTAssertTrue(bundled.contains("completionId"))
        XCTAssertTrue(bundled.contains("latestCompletedEntryID(ctx.sessionManager.getBranch())"))
    }

    func testBundledExtensionWatchesCodexReviewsWithoutPollingTheProvider() throws {
        let bundled = try XCTUnwrap(ActivityExtensionInstaller.bundledSource())
        XCTAssertEqual(ActivityExtensionInstaller.version(of: bundled), 18)
        XCTAssertTrue(bundled.contains("pi.on(\"tool_result\""))
        XCTAssertTrue(bundled.contains("gh\\s+pr\\s+create"))
        XCTAssertTrue(bundled.contains("invokesPullRequestCreation"))
        XCTAssertTrue(bundled.contains("kind: \"heartbeat\""))
        XCTAssertTrue(bundled.contains("pi.registerCommand(PULL_REQUEST_REVIEW_COMMAND"))
        XCTAssertTrue(bundled.contains("chatgpt-codex-connector"))
        XCTAssertTrue(bundled.contains("--paginate"))
        XCTAssertTrue(bundled.contains("PULL_REQUEST_REVIEW_CUSTOM_TYPE"))
        XCTAssertTrue(bundled.contains("pi-desktop-pr-review-complete"))
        XCTAssertTrue(bundled.contains("never merge a pull request."))
        XCTAssertTrue(bundled.contains("PULL_REQUEST_REVIEW_MAX_AGE_MS"))
    }

    func testBundledExtensionBranchesEditedMessagesInsideTheCurrentSession() throws {
        let bundled = try XCTUnwrap(ActivityExtensionInstaller.bundledSource())
        XCTAssertEqual(ActivityExtensionInstaller.version(of: bundled), 18)
        XCTAssertTrue(bundled.contains("pi.registerCommand(\"pi-desktop-edit-message\""))
        XCTAssertTrue(bundled.contains("ctx.navigateTree(entryId, { summarize: false })"))
        XCTAssertTrue(bundled.contains("pi.appendEntry(\"pi-desktop-edit-ready\""))
        XCTAssertTrue(bundled.contains("pi.on(\"session_tree\""))
    }

    func testBundledExtensionCanRetryWithoutAVisibleUserMessage() throws {
        let bundled = try XCTUnwrap(ActivityExtensionInstaller.bundledSource())
        XCTAssertEqual(ActivityExtensionInstaller.version(of: bundled), 18)
        XCTAssertTrue(bundled.contains("pi.registerCommand(\"pi-desktop-resume\""))
        XCTAssertTrue(bundled.contains("customType: \"pi-desktop-retry\""))
        XCTAssertTrue(bundled.contains("Continue from where it stopped without repeating completed work"))
        XCTAssertTrue(bundled.contains("display: false"))
        XCTAssertTrue(bundled.contains("triggerTurn: true"))
    }

    func testBundledExtensionCouplesPreviewToTheCompletedAnswer() throws {
        let bundled = try XCTUnwrap(ActivityExtensionInstaller.bundledSource())
        XCTAssertEqual(ActivityExtensionInstaller.version(of: bundled), 18)
        XCTAssertTrue(bundled.contains("preview = extractPreview(message.content);"))
        XCTAssertTrue(bundled.contains("previewCompletionId: preview ? completionId : undefined"))
        XCTAssertTrue(bundled.contains("completionId = latestCompletedEntryID(ctx.sessionManager.getBranch());"))
        XCTAssertFalse(bundled.contains("preview = extractPreview(message.content) ?? preview"))
        XCTAssertFalse(bundled.contains("text.replace(/\\s+/g"))
    }

    // MARK: - Disable setting

    func testActivityExtensionSettingsPersistsTheDisabledFlag() {
        let defaults = UserDefaults(suiteName: "PiActivityInstallerTests-\(UUID().uuidString)")!
        XCTAssertFalse(ActivityExtensionSettings.isDisabled(defaults: defaults))
        ActivityExtensionSettings.setDisabled(true, defaults: defaults)
        XCTAssertTrue(ActivityExtensionSettings.isDisabled(defaults: defaults))
        ActivityExtensionSettings.setDisabled(false, defaults: defaults)
        XCTAssertFalse(ActivityExtensionSettings.isDisabled(defaults: defaults))
    }
}
