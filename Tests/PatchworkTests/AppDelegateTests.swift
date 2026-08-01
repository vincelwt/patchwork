import AppKit
import XCTest
@testable import Patchwork

@MainActor
final class AppDelegateTests: XCTestCase {
    func testLaunchUsesRegularActivationPolicy() {
        let application = NSApplication.shared
        let originalPolicy = application.activationPolicy()
        defer { _ = application.setActivationPolicy(originalPolicy) }

        _ = application.setActivationPolicy(.prohibited)
        AppDelegate().applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification, object: application)
        )

        XCTAssertEqual(application.activationPolicy(), .regular)
    }
}
