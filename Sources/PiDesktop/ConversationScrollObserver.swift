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

    func armPrepend() { coordinator?.armPrepend() }
    func disarmPrepend() { coordinator?.disarmPrepend() }
    func armPageReplacement(_ edge: ConversationPageEdge) { coordinator?.armPageReplacement(edge) }
    func applyPageReplacement() { coordinator?.applyPageReplacement() }
    func disarmPageReplacement() { coordinator?.disarmPageReplacement() }
    /// Pin to the newest content and keep following it as the document grows.
    func pinToBottom() { coordinator?.pinToBottom() }
}

/// Observes and *corrects* the real AppKit scroll view beneath SwiftUI's `ScrollView`.
///
/// Corrections are applied synchronously inside the document's own layout pass: the live page
/// stays pinned through growth, the first history page preserves the current rows while it is
/// prepended, and deeper bounded history replacements land at their requested edge.
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

    /// SwiftUI bottom-aligns short content with a synthetic top inset, while the composer and
    /// toolbar contribute real insets. Both edges therefore need inset-aware origins.
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
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat? {
        let addedHeight = newDocumentHeight - oldDocumentHeight
        guard addedHeight > 0.5 else { return nil }
        return min(
            bottomOriginY(
                documentHeight: newDocumentHeight,
                viewportHeight: viewportHeight,
                topInset: topInset,
                bottomInset: bottomInset
            ),
            max(-topInset, originalY + addedHeight)
        )
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
        /// A conversation opens pinned; only a real user scroll or history replacement can unpin it.
        private(set) var pinned = true
        private var prependArmed = false
        private var replacementEdge: ConversationPageEdge?
        private var replacementReady = false
        private var isAdjusting = false
        /// True from attach until the first heal runs: every open gets exactly one heal after
        /// its content settles, whether or not any correction fired.
        private var openHealArmed = true
        private var healWork: DispatchWorkItem?
        /// A real user scroll is itself the strongest paint heal — and the moment one happens,
        /// the coordinator must never move the viewport on its own again.
        private var userScrolledSinceAttach = false
        private var pendingMetrics: ConversationScrollMetrics?
        private var metricsCallbackScheduled = false

        init(parent: ConversationScrollObserver) { self.parent = parent }

        func armPrepend() {
            prependArmed = true
            pinned = false
        }

        func disarmPrepend() { prependArmed = false }

        func armPageReplacement(_ edge: ConversationPageEdge) {
            prependArmed = false
            replacementEdge = edge
            replacementReady = false
            pinned = false
            userScrolledSinceAttach = false
        }

        func applyPageReplacement() {
            guard let replacementEdge, let scrollView else { return }
            switch replacementEdge {
            case .top:
                // The inset-aware top remains stable as rows below settle; do not fight a scroll.
                replacementReady = false
                setOrigin(-scrollView.contentView.contentInsets.top)
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
            prependArmed = false
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
            openHealArmed = true
            userScrolledSinceAttach = false
            scheduleHeal()
            publish()
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
            if replacementReady {
                applyPageReplacement()
            } else if prependArmed {
                let insets = scrollView.contentView.contentInsets
                if let target = ConversationScrollObserver.restoredOriginY(
                    originalY: scrollView.contentView.bounds.origin.y,
                    oldDocumentHeight: oldHeight,
                    newDocumentHeight: newHeight,
                    viewportHeight: scrollView.contentView.bounds.height,
                    topInset: insets.top,
                    bottomInset: insets.bottom
                ) {
                    setOrigin(target)
                }
            } else if pinned {
                // `defaultScrollAnchor(.bottom)` usually maintains the pin itself, fully
                // rendered; only correct when it did not, and then heal the paint (below).
                let insets = scrollView.contentView.contentInsets
                let target = ConversationScrollObserver.bottomOriginY(
                    documentHeight: newHeight,
                    viewportHeight: scrollView.contentView.bounds.height,
                    topInset: insets.top,
                    bottomInset: insets.bottom
                )
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
            let originY = visible.origin.y
            if let previous = previousOriginY, abs(originY - previous) > 0.5 {
                userScrolledSinceAttach = true
            }
            previousOriginY = originY
            pinned = document.bounds.height - (originY + visible.height) <= PiTheme.transcriptScrollEdgeThreshold
            publish()
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
            // Never move anything while the user's hands are on it: a drag (text selection,
            // scroller grab) defers the heal entirely, and any user scroll since attach already
            // forced the repaint, so only the always-safe parts run. The heal must be
            // unobservable: the user may scroll or select the instant a thread opens.
            if NSEvent.pressedMouseButtons != 0 {
                ScrollDebug.log("heal deferred: mouse down")
                scheduleHeal()
                return
            }
            openHealArmed = false
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
            if !userScrolledSinceAttach, bottomMost > -insets.top + 1 {
                ScrollDebug.log("heal fires (jiggle)")
                let nudged = origin.y > -insets.top + 1 ? origin.y - 1 : origin.y + 1
                isAdjusting = true
                clip.scroll(to: NSPoint(x: origin.x, y: nudged))
                scrollView.reflectScrolledClipView(clip)
                isAdjusting = false
                DispatchQueue.main.async { [weak self] in
                    guard let self, let scrollView = self.scrollView else { return }
                    let current = scrollView.contentView.bounds.origin
                    // The user moved in the meantime: their position wins, never teleport back.
                    guard abs(current.y - nudged) <= 0.5 else { return }
                    isAdjusting = true
                    scrollView.contentView.scroll(to: origin)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    isAdjusting = false
                    previousOriginY = origin.y
                }
            } else {
                ScrollDebug.log("heal fires (safe parts only)")
            }
            document.needsLayout = true
            parent.onHeal()
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
