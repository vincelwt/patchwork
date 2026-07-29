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
    /// Internal (not fileprivate) so the coordinator test harness can wire a bridge directly.
    weak var coordinator: ConversationScrollObserver.Coordinator?

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
/// Temporary stderr diagnostics, active only when PI_SCROLL_DEBUG=1.
enum ScrollDebug {
    static let enabled = ProcessInfo.processInfo.environment["PI_SCROLL_DEBUG"] == "1"
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[scroll] \(message())\n".utf8))
    }
}

struct ConversationScrollObserver: NSViewRepresentable {
    let bridge: ConversationScrollBridge
    let onChange: (ConversationScrollMetrics) -> Void
    /// Invoked (coalesced) after an open settles or a forced origin move, so the SwiftUI side
    /// can bump a state tick that guarantees one render pass against the actual viewport.
    var onHeal: () -> Void = {}

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

    /// Scroll geometry is inset-aware everywhere: SwiftUI bottom-aligns short content by
    /// growing a synthetic *top* content inset, and the composer/toolbar contribute real
    /// insets, so "scrolled to top" is `-top` and "scrolled to bottom" is
    /// `docHeight - viewport + bottom` — both routinely negative. Clamping to zero here is what
    /// used to shove freshly opened conversations up behind the toolbar glass.
    static func bottomOriginY(
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        max(-topInset, documentHeight - viewportHeight + bottomInset)
    }

    static func restoredOriginY(
        originalY: CGFloat,
        oldDocumentHeight: CGFloat,
        newDocumentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0
    ) -> CGFloat? {
        let addedHeight = newDocumentHeight - oldDocumentHeight
        guard addedHeight > 0.5 else { return nil }
        let bottomMost = bottomOriginY(
            documentHeight: newDocumentHeight,
            viewportHeight: viewportHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
        return min(bottomMost, max(-topInset, originalY + addedHeight))
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
        /// True from attach until the first heal runs: every open gets exactly one heal after
        /// its content settles, whether or not any correction fired.
        private var openHealArmed = true
        private var healWork: DispatchWorkItem?
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
            // No programmatic scroll here on purpose: attach runs inside SwiftUI's update, and
            // `defaultScrollAnchor(.bottom)` already positions the first frame through SwiftUI's
            // own pipeline. Scrolling the clip view mid-update leaves SwiftUI's display list
            // culled for the stale viewport — the "ghost band + blank transcript" artifact.
            openHealArmed = true
            scheduleHeal()
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
            ScrollDebug.log("frame \(Int(oldHeight))->\(Int(newHeight)) origin=\(Int(scrollView.contentView.bounds.origin.y)) clipH=\(Int(scrollView.contentView.bounds.height)) pinned=\(pinned) svInsets=\(scrollView.contentInsets) clipInsets=\(scrollView.contentView.contentInsets) safeArea=\(scrollView.safeAreaInsets)")
            if openHealArmed { scheduleHeal() }
            let insets = scrollView.contentView.contentInsets
            if pinned {
                // `defaultScrollAnchor(.bottom)` usually maintains the pin itself, fully
                // rendered; only correct when it did not, and then heal the paint (below).
                let target = ConversationScrollObserver.bottomOriginY(
                    documentHeight: newHeight,
                    viewportHeight: scrollView.contentView.bounds.height,
                    topInset: insets.top,
                    bottomInset: insets.bottom
                )
                if abs(scrollView.contentView.bounds.origin.y - target) > 0.5 { setOrigin(target) }
            } else if prependArmed, let target = ConversationScrollObserver.restoredOriginY(
                originalY: scrollView.contentView.bounds.origin.y,
                oldDocumentHeight: oldHeight,
                newDocumentHeight: newHeight,
                viewportHeight: scrollView.contentView.bounds.height,
                topInset: insets.top,
                bottomInset: insets.bottom
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
            let insets = scrollView.contentView.contentInsets
            setOrigin(ConversationScrollObserver.bottomOriginY(
                documentHeight: document.bounds.height,
                viewportHeight: scrollView.contentView.bounds.height,
                topInset: insets.top,
                bottomInset: insets.bottom
            ))
        }

        private func setOrigin(_ y: CGFloat) {
            guard let scrollView else { return }
            ScrollDebug.log("setOrigin \(Int(scrollView.contentView.bounds.origin.y)) -> \(Int(y))")
            isAdjusting = true
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isAdjusting = false
            previousOriginY = y
            scheduleHeal()
        }

        /// SwiftUI can render a conversation's first display list for the pre-anchor viewport
        /// (or, after a forced origin move made inside layout, for the pre-move viewport) and
        /// never repaint: the thread opens white or ghosted until the user scrolls. This heal is
        /// that manual scroll, made automatic and invisible. Debounced past the open's settle
        /// churn; every open runs it at least once, and every forced move re-runs it.
        private func scheduleHeal() {
            healWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.performHeal() }
            healWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        private func performHeal() {
            guard let scrollView, let document = scrollView.documentView else { return }
            openHealArmed = false
            ScrollDebug.log("heal fires")
            let clip = scrollView.contentView
            let origin = clip.bounds.origin
            let insets = clip.contentInsets
            let bottomMost = ConversationScrollObserver.bottomOriginY(
                documentHeight: document.bounds.height,
                viewportHeight: clip.bounds.height,
                topInset: insets.top,
                bottomInset: insets.bottom
            )
            // A real one-point move the clip view will accept, then back — two genuine bounds
            // changes across two turns, exactly what a manual scroll does. Underfilled content
            // has no scrollable range, so short conversations rely on the SwiftUI tick below.
            if bottomMost > -insets.top + 1 {
                let nudged = origin.y > -insets.top + 1 ? origin.y - 1 : origin.y + 1
                isAdjusting = true
                clip.scroll(to: NSPoint(x: origin.x, y: nudged))
                scrollView.reflectScrolledClipView(clip)
                isAdjusting = false
                DispatchQueue.main.async { [weak self] in
                    guard let self, let scrollView = self.scrollView else { return }
                    scrollView.contentView.scroll(to: origin)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    previousOriginY = origin.y
                }
            }
            document.needsLayout = true
            parent.onHeal()
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
