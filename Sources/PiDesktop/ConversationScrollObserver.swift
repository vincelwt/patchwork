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
}

@MainActor
final class ConversationScrollBridge {
    fileprivate var capturePrependImpl: (() -> Void)?
    fileprivate var restorePrependImpl: (() -> Void)?

    func captureBeforePrepend() { capturePrependImpl?() }
    func restoreAfterPrepend() { restorePrependImpl?() }
}

/// Observes the real AppKit clip view beneath SwiftUI's `ScrollView`. Lazy-row realization is
/// not a reliable proxy for whether the viewport is pinned, but the clip/document geometry is.
struct ConversationScrollObserver: NSViewRepresentable {
    let bridge: ConversationScrollBridge
    let onChange: (ConversationScrollMetrics) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.coordinator = context.coordinator
        context.coordinator.installBridge(bridge)
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.installBridge(bridge)
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
        private var boundsObserver: NSObjectProtocol?
        private var previousOriginY: CGFloat?
        private var prependSnapshot: (origin: NSPoint, documentHeight: CGFloat)?
        private var pendingMetrics: ConversationScrollMetrics?
        private var metricsCallbackScheduled = false
        private var isRestoring = false

        init(parent: ConversationScrollObserver) { self.parent = parent }

        func installBridge(_ bridge: ConversationScrollBridge) {
            bridge.capturePrependImpl = { [weak self] in self?.captureBeforePrepend() }
            bridge.restorePrependImpl = { [weak self] in self?.scheduleRestoreAfterPrepend() }
        }

        func attach(from view: NSView) {
            guard let candidate = view.enclosingScrollView else { return }
            guard candidate !== scrollView else { return }
            detach()
            scrollView = candidate
            candidate.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: candidate.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            }
            publish()
        }

        func detach() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            boundsObserver = nil
            scrollView = nil
            previousOriginY = nil
            prependSnapshot = nil
            pendingMetrics = nil
        }

        private func publish() {
            guard let scrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.contentView.bounds
            let originY = visible.origin.y
            let direction: ConversationScrollMetrics.Direction
            if isRestoring || previousOriginY == nil || abs(originY - previousOriginY!) < 0.5 {
                direction = .stationary
            } else {
                direction = originY < previousOriginY! ? .up : .down
            }
            previousOriginY = originY
            pendingMetrics = ConversationScrollMetrics(
                originY: originY,
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

        private func captureBeforePrepend() {
            guard let scrollView, let document = scrollView.documentView else { return }
            prependSnapshot = (scrollView.contentView.bounds.origin, document.bounds.height)
        }

        private func scheduleRestoreAfterPrepend() {
            DispatchQueue.main.async { [weak self] in self?.restoreAfterPrepend(attempt: 0) }
        }

        private func restoreAfterPrepend(attempt: Int) {
            guard let scrollView, let document = scrollView.documentView, let snapshot = prependSnapshot else { return }
            document.layoutSubtreeIfNeeded()
            scrollView.layoutSubtreeIfNeeded()
            let documentHeight = document.bounds.height
            guard let targetY = ConversationScrollObserver.restoredOriginY(
                originalY: snapshot.origin.y,
                oldDocumentHeight: snapshot.documentHeight,
                newDocumentHeight: documentHeight,
                viewportHeight: scrollView.contentView.bounds.height
            ) else {
                if attempt < 3 {
                    DispatchQueue.main.async { [weak self] in self?.restoreAfterPrepend(attempt: attempt + 1) }
                } else {
                    prependSnapshot = nil
                }
                return
            }

            let target = NSPoint(x: snapshot.origin.x, y: targetY)
            isRestoring = true
            scrollView.contentView.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            previousOriginY = target.y
            isRestoring = false
            prependSnapshot = nil
            publish()
        }
    }
}
