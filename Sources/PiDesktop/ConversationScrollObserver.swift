import AppKit
import SwiftUI

struct ConversationScrollMetrics: Equatable {
    let originY: CGFloat
    let viewportHeight: CGFloat
    let documentHeight: CGFloat

    var isNearBottom: Bool {
        documentHeight - (originY + viewportHeight) <= PiTheme.transcriptScrollEdgeThreshold
    }
}

enum ConversationPageEdge { case top, bottom }

/// The SwiftUI side's handle into the AppKit coordinator that owns scroll corrections.
@MainActor
final class ConversationScrollBridge {
    /// Internal (not fileprivate) so the coordinator test harness can wire a bridge directly.
    weak var coordinator: ConversationScrollObserver.Coordinator?

    func armPageReplacement(_ edge: ConversationPageEdge) { coordinator?.armPageReplacement(edge) }
    func applyPageReplacement() { coordinator?.applyPageReplacement() }
    func disarmPageReplacement() { coordinator?.disarmPageReplacement() }
    /// Pin to the newest content and keep following it as the document grows.
    func pinToBottom() { coordinator?.pinToBottom() }
}

/// Observes and *corrects* the real AppKit scroll view beneath SwiftUI's `ScrollView`.
///
/// Corrections are applied synchronously inside the document's own layout pass: the live page
/// stays pinned through growth, while disjoint history-page replacements land at their requested
/// edge without ever retaining all intervening rows.
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
        /// A conversation opens pinned; only a real user scroll or history replacement can unpin it.
        private(set) var pinned = true
        private var replacementEdge: ConversationPageEdge?
        private var replacementReady = false
        private var isAdjusting = false
        private var paintHealScheduled = false
        private var pendingMetrics: ConversationScrollMetrics?
        private var metricsCallbackScheduled = false

        init(parent: ConversationScrollObserver) { self.parent = parent }

        func armPageReplacement(_ edge: ConversationPageEdge) {
            replacementEdge = edge
            replacementReady = false
            pinned = false
        }

        func applyPageReplacement() {
            guard let replacementEdge else { return }
            switch replacementEdge {
            case .top:
                // Origin zero remains stable as rows below settle; do not fight a user scroll.
                replacementReady = false
                setOrigin(0)
            case .bottom:
                replacementReady = true
                scrollToBottom()
            }
            publish()
        }

        func disarmPageReplacement() {
            replacementEdge = nil
            replacementReady = false
        }

        func pinToBottom() {
            replacementEdge = nil
            replacementReady = false
            pinned = true
            scrollToBottom()
            publish()
        }

        func attach(from view: NSView) {
            guard let candidate = view.enclosingScrollView else { return }
            if candidate === scrollView, candidate.documentView === documentView {
                publish()
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
            // No programmatic scroll here on purpose: attach runs inside SwiftUI's update, and
            // `defaultScrollAnchor(.bottom)` already positions the first frame through SwiftUI's
            // own pipeline. Scrolling the clip view mid-update leaves SwiftUI's display list
            // culled for the stale viewport — the "ghost band + blank transcript" artifact.
            publish()
        }

        func detach() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            boundsObserver = nil
            frameObserver = nil
            scrollView = nil
            documentView = nil
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
            if replacementReady {
                applyPageReplacement()
            } else if pinned {
                // `defaultScrollAnchor(.bottom)` usually maintains the pin itself, fully
                // rendered; only correct when it did not, and then heal the paint (below).
                let target = max(0, newHeight - scrollView.contentView.bounds.height)
                if abs(scrollView.contentView.bounds.origin.y - target) > 0.5 { setOrigin(target) }
            }
            publish()
        }

        /// Clip bounds changed at constant document height: the user scrolled. This is the only
        /// place pin state changes.
        private func handleBoundsChange() {
            guard !isAdjusting, let scrollView, let document = scrollView.documentView else { return }
            guard abs(document.bounds.height - lastDocumentHeight) <= 0.5 else { return }
            let visible = scrollView.contentView.bounds
            pinned = document.bounds.height - (visible.origin.y + visible.height) <= PiTheme.transcriptScrollEdgeThreshold
            publish()
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
            schedulePaintHeal()
        }

        /// A clip-origin move made inside SwiftUI's update or layout pass positions correctly
        /// but leaves SwiftUI's display list rendered for the old viewport: newly exposed rows
        /// stay blank and stale pixels linger until the next real scroll. One coalesced pass
        /// after the current turn re-asserts the origin through the normal notification path
        /// (with a sub-pixel nudge so the bounds change is real), which makes SwiftUI re-render
        /// the viewport it is actually showing.
        private func schedulePaintHeal() {
            guard !paintHealScheduled else { return }
            paintHealScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                paintHealScheduled = false
                guard let scrollView else { return }
                let clip = scrollView.contentView
                let origin = clip.bounds.origin
                isAdjusting = true
                clip.setBoundsOrigin(NSPoint(x: origin.x, y: origin.y + 0.5))
                isAdjusting = false
                clip.scroll(to: origin)
                scrollView.reflectScrolledClipView(clip)
            }
        }

        /// Metrics reach SwiftUI coalesced and asynchronously — state must not mutate inside the
        /// layout pass the notifications arrive in. Corrections above stay synchronous.
        private func publish() {
            guard let scrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.contentView.bounds
            pendingMetrics = ConversationScrollMetrics(
                originY: visible.origin.y,
                viewportHeight: visible.height,
                documentHeight: document.bounds.height
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
