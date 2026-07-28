import AppKit
import Foundation
import UserNotifications

/// What happened, independent of how it gets presented. Text stays short and specific: the
/// conversation title is prefixed on by the caller, this only supplies what happened.
enum NotificationTrigger: Equatable {
    case turnFinished
    case turnFailed
    case questionWaiting
    case approvalNeeded

    var summary: String {
        switch self {
        case .turnFinished: "finished responding"
        case .turnFailed: "hit an error"
        case .questionWaiting: "is waiting for your answer"
        case .approvalNeeded: "needs your approval to continue"
        }
    }

    var toastStyle: ToastMessage.Style {
        switch self {
        case .turnFinished: .info
        case .turnFailed: .error
        case .questionWaiting, .approvalNeeded: .warning
        }
    }
}

/// Formats a notification body from raw message/preview text: bounded, sanitized to a single
/// line, never a generic phrase when real content is available.
enum NotificationPreviewFormatter {
    static let limit = 140

    static func format(_ text: String?) -> String? {
        guard let text else { return nil }
        let plain = AnswerAttributedTextBuilder.plainText(blocks: MarkdownBlockParser.blocks(from: text))
        let collapsed = plain.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit)) + "…"
    }
}

/// The one case that must never notify: the app is frontmost and the user is already looking at
/// the exact conversation the event is about. Everything else (a different conversation, or the
/// app not frontmost at all) is real signal.
enum NotificationGate {
    static func isSuppressed(sessionKey: String, focusedSessionKey: String?) -> Bool {
        sessionKey == focusedSessionKey
    }
}

/// Rate-limits notifications so a burst of activity cannot spam the user: at most one per
/// session within `perSessionWindow`, and at most `burstLimit` across every session within
/// `burstWindow` so many terminals finishing at once still cannot flood Notification Center.
struct NotificationCoalescer {
    var perSessionWindow: TimeInterval = 5
    var burstWindow: TimeInterval = 10
    var burstLimit: Int = 5

    private var lastEmitted: [String: Date] = [:]
    private var recent: [Date] = []

    mutating func shouldEmit(sessionKey: String, now: Date = Date()) -> Bool {
        let retention = max(perSessionWindow, burstWindow)
        lastEmitted = lastEmitted.filter { now.timeIntervalSince($0.value) < retention }
        if let last = lastEmitted[sessionKey], now.timeIntervalSince(last) < perSessionWindow { return false }
        recent.removeAll { now.timeIntervalSince($0) >= burstWindow }
        guard recent.count < burstLimit else { return false }
        lastEmitted[sessionKey] = now
        recent.append(now)
        return true
    }
}

/// OS/in-app presentation seam so `AppStore` can be tested without ever touching
/// `UNUserNotificationCenter`.
@MainActor
protocol NotificationPresenting: AnyObject {
    /// Set by `AppStore` so a clicked notification can focus and select its conversation.
    /// `sessionKey` is always a standardized session-file path.
    var onSelectSession: ((String) -> Void)? { get set }
    func presentDesktopNotification(sessionKey: String, title: String, body: String)
}

/// `UNUserNotificationCenter` is unusable outside a real, launched `.app` bundle: under
/// `swift test`/`swift run`, or any other bare-executable host, `Bundle.main` still often reports
/// a non-nil `bundleIdentifier` (the `xctest` host tool has its own), yet the notification
/// daemon has no bundle proxy for the process and `UNUserNotificationCenter.current()` raises an
/// uncatchable Objective-C exception. Every entry point is guarded by `isBundledApplication`,
/// detected from the actual `.app` bundle structure plus an explicit XCTest check, and simply
/// no-ops when it is false — degrading, never crashing, never nagging for permission repeatedly.
@MainActor
final class NotificationService: NSObject, NotificationPresenting, UNUserNotificationCenterDelegate {
    var onSelectSession: ((String) -> Void)?

    private let isBundledApplication: Bool
    private var authorizationRequested = false

    /// True only for a process actually launched from inside a `.app` bundle. `swift run`'s
    /// bare executable and every test host fail this, regardless of what `bundleIdentifier`
    /// happens to report.
    nonisolated static func detectBundledApplication() -> Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
        return Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    init(isBundledApplication: Bool = NotificationService.detectBundledApplication()) {
        self.isBundledApplication = isBundledApplication
        super.init()
        if isBundledApplication { UNUserNotificationCenter.current().delegate = self }
    }

    func presentDesktopNotification(sessionKey: String, title: String, body: String) {
        guard isBundledApplication else { return }
        Task { [weak self] in await self?.deliverIfAuthorized(sessionKey: sessionKey, title: title, body: body) }
    }

    private func deliverIfAuthorized(sessionKey: String, title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            deliver(center: center, sessionKey: sessionKey, title: title, body: body)
        case .notDetermined where !authorizationRequested:
            // Requested lazily, once: the first real notification, not app launch.
            authorizationRequested = true
            if let granted = try? await center.requestAuthorization(options: [.alert, .sound]), granted {
                deliver(center: center, sessionKey: sessionKey, title: title, body: body)
            }
        default:
            break // Denied, restricted, or already asked once this launch: never nag.
        }
    }

    private func deliver(center: UNUserNotificationCenter, sessionKey: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["sessionKey": sessionKey]
        // The session is the identifier, so a second notification for the same conversation
        // replaces the first in Notification Center instead of piling up.
        let request = UNNotificationRequest(identifier: "session:\(sessionKey)", content: content, trigger: nil)
        center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionKey = response.notification.request.content.userInfo["sessionKey"] as? String
        Task { @MainActor in
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let sessionKey { self.onSelectSession?(sessionKey) }
            completionHandler()
        }
    }
}
