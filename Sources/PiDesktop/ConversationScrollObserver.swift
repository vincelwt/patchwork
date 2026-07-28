import AppKit
import SwiftUI

struct ConversationScrollMetrics: Equatable {
    enum Direction: Equatable { case up, down, stationary }

    let originY: CGFloat
    let viewportHeight: CGFloat
    let documentHeight: CGFloat
    let direction: Direction

    var isNearTop: Bool { originY <= PiTheme.transcriptScrollEdgeThreshold }
    var isNearBottom: Bool {
        documentHeight - (originY + viewportHeight) <= PiTheme.transcriptScrollEdgeThreshold
    }
    var isUnderfilled: Bool {
        documentHeight > 1 && viewportHeight > 1 && documentHeight <= viewportHeight + 1
    }
    var shouldRequestEarlierHistory: Bool {
        (direction == .up && originY <= PiTheme.transcriptHistoryPrefetchDistance)
            || (isNearTop && isUnderfilled)
    }
}

/// The SwiftUI side's handle into the AppKit coordinator that owns scroll corrections.
@MainActor
final class ConversationScrollBridge {
    fileprivate weak var coordinator: ConversationScrollObserver.Coordinator?

    /// Arm before a history page is requested: subsequent document growth is treated as content
    /// inserted above the viewport and compensated in the same layout pass.
    func armPrepend() { coordinator?.armPrepend() }
    func disarmPrepend() { coordinator?.disarmPrepend() }
    /// Pin to the newest content and keep following it as the document grows.
    func pinToBottom() { coordinator?.pinToBottom() }
}

/// Observes and *corrects* the real AppKit scroll view beneath SwiftUI's `ScrollView`.
///
/// Two behaviors live here, both applied synchronously inside the document's own layout pass
/// (notifications are delivered on the posting thread, not queued), so the user never sees an
/// intermediate frame at the wrong offset:
/// - While pinned to the bottom, any document height change re-pins the viewport to the bottom.
///   This is what keeps streaming turns, image decodes, and lazily settling rows glued to the
///   newest content without a trailing `scrollTo` task racing the layout.
/// - While a history prepend is armed, document growth shifts the origin by the added height, so
///   the rows the user was reading stay exactly where they were.
struct ConversationScrollObserver: NSViewRepresentable {
    let bridge: ConversationScrollBridge
    let onChange: (ConversationScrollMetrics) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.coordinator = context.coordinator
        bridge.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        context.coordinator.parent = self
        bridge.coordinator = context.coordinator
        context.coordinator.attach(from: view)
    }

    static func dismantleNSView(_ view: AttachmentView, coordinator: Coordinator) {
        coordinator.detach()
    }

    static func restoredOriginY(
        originalY: CGFloat,
        oldDocumentHeight: CGFloat,
        newDocumentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat? {
        let addedHeight = newDocumentHeight - oldDocumentHeight
        guard addedHeight > 0.5 else { return nil }
        return min(max(0, newDocumentHeight - viewportHeight), max(0, originalY + addedHeight))
    }

    final class AttachmentView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                coordinator?.attach(from: self)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ConversationScrollObserver
        private weak var scrollView: NSScrollView?
        private weak var documentView: NSView?
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var lastDocumentHeight: CGFloat = 0
        private var previousOriginY: CGFloat?
        /// A conversation opens pinned; only a real user scroll can unpin it.
        private(set) var pinned = true
        private var prependArmed = false
        private var isAdjusting = false
        private var pendingMetrics: ConversationScrollMetrics?
        private var metricsCallbackScheduled = false

        init(parent: ConversationScrollObserver) { self.parent = parent }

        func armPrepend() { prependArmed = true }
        func disarmPrepend() { prependArmed = false }

        func pinToBottom() {
            prependArmed = false
            pinned = true
            scrollToBottom()
            publish(direction: .stationary)
        }

        func attach(from view: NSView) {
            guard let candidate = view.enclosingScrollView else { return }
            if candidate === scrollView, candidate.documentView === documentView {
                publish(direction: .stationary)
                return
            }
            detach()
            scrollView = candidate
            documentView = candidate.documentView
            candidate.contentView.postsBoundsChangedNotifications = true
            // `queue: nil` on purpose: both notifications post on the main thread during layout,
            // and handling them in that same pass is what makes corrections invisible.
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: candidate.contentView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleBoundsChange() }
            }
            if let document = candidate.documentView {
                document.postsFrameChangedNotifications = true
                frameObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: document,
                    queue: nil
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handleDocumentFrameChange() }
                }
                lastDocumentHeight = document.bounds.height
            }
            if pinned { scrollToBottom() }
            publish(direction: .stationary)
        }

        func detach() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            boundsObserver = nil
            frameObserver = nil
            scrollView = nil
            documentView = nil
            previousOriginY = nil
            pendingMetrics = nil
        }

        /// Document height changed: content grew or shrank. Correct the origin before this pass
        /// draws, then report. User pin state never changes here — growth is not a scroll.
        private func handleDocumentFrameChange() {
            guard let scrollView, let document = scrollView.documentView else { return }
            let newHeight = document.bounds.height
            let oldHeight = lastDocumentHeight
            lastDocumentHeight = newHeight
            guard abs(newHeight - oldHeight) > 0.5 else { return }
            if pinned {
                scrollToBottom()
            } else if prependArmed, let target = ConversationScrollObserver.restoredOriginY(
                originalY: scrollView.contentView.bounds.origin.y,
                oldDocumentHeight: oldHeight,
                newDocumentHeight: newHeight,
                viewportHeight: scrollView.contentView.bounds.height
            ) {
                setOrigin(target)
            }
            publish(direction: .stationary)
        }

        /// Clip bounds changed at constant document height: the user scrolled. This is the only
        /// place pin state changes.
        private func handleBoundsChange() {
            guard !isAdjusting, let scrollView, let document = scrollView.documentView else { return }
            guard abs(document.bounds.height - lastDocumentHeight) <= 0.5 else { return }
            let visible = scrollView.contentView.bounds
            let originY = visible.origin.y
            let direction: ConversationScrollMetrics.Direction
            if previousOriginY == nil || abs(originY - previousOriginY!) < 0.5 {
                direction = .stationary
            } else {
                direction = originY < previousOriginY! ? .up : .down
            }
            previousOriginY = originY
            pinned = document.bounds.height - (originY + visible.height) <= PiTheme.transcriptScrollEdgeThreshold
            publish(direction: direction)
        }

        private func scrollToBottom() {
            guard let scrollView, let document = scrollView.documentView else { return }
            setOrigin(max(0, document.bounds.height - scrollView.contentView.bounds.height))
        }

        private func setOrigin(_ y: CGFloat) {
            guard let scrollView else { return }
            isAdjusting = true
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isAdjusting = false
            previousOriginY = y
        }

        /// Metrics reach SwiftUI coalesced and asynchronously — state must not mutate inside the
        /// layout pass the notifications arrive in. Corrections above stay synchronous.
        private func publish(direction: ConversationScrollMetrics.Direction) {
            guard let scrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.contentView.bounds
            pendingMetrics = ConversationScrollMetrics(
                originY: visible.origin.y,
                viewportHeight: visible.height,
                documentHeight: document.bounds.height,
                direction: direction
            )
            guard !metricsCallbackScheduled else { return }
            metricsCallbackScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                metricsCallbackScheduled = false
                guard let metrics = pendingMetrics else { return }
                pendingMetrics = nil
                parent.onChange(metrics)
            }
        }
    }
}
