import AppKit
import SwiftUI

private struct TranscriptRowLayoutInvalidationKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var transcriptRowLayoutInvalidation: () -> Void {
        get { self[TranscriptRowLayoutInvalidationKey.self] }
        set { self[TranscriptRowLayoutInvalidationKey.self] = newValue }
    }
}

private enum NativeTranscriptDebug {
    static let enabled = ProcessInfo.processInfo.environment["PI_SCROLL_DEBUG"] == "1"
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[native-scroll] \(message())\n".utf8))
    }
}

struct ConversationScrollMetrics: Equatable {
    enum Direction: Equatable { case up, down, stationary }

    /// Coordinates are normalized so the first row begins at zero even when the scroll view has
    /// a top content inset (including the synthetic inset used to bottom-align short threads).
    let originY: CGFloat
    let viewportHeight: CGFloat
    let documentHeight: CGFloat
    let direction: Direction
    /// True only for a data publication that may intentionally fill a short first page.
    let allowsUnderfillPaging: Bool

    init(
        originY: CGFloat,
        viewportHeight: CGFloat,
        documentHeight: CGFloat,
        direction: Direction,
        allowsUnderfillPaging: Bool = false
    ) {
        self.originY = originY
        self.viewportHeight = viewportHeight
        self.documentHeight = documentHeight
        self.direction = direction
        self.allowsUnderfillPaging = allowsUnderfillPaging
    }

    var isNearTop: Bool { originY <= PiTheme.transcriptScrollEdgeThreshold }
    var isNearBottom: Bool {
        documentHeight - (originY + viewportHeight) <= PiTheme.transcriptScrollEdgeThreshold
    }
    var isUnderfilled: Bool {
        documentHeight > 1 && viewportHeight > 1 && documentHeight <= viewportHeight + 1
    }
    var shouldRequestEarlierHistory: Bool {
        (direction == .up && originY <= PiTheme.transcriptHistoryPrefetchDistance)
            || (allowsUnderfillPaging && isNearTop && isUnderfilled)
    }
}

enum NativeTranscriptHistory: Hashable {
    case loading
    case loadEarlier
    case limitReached
}

struct NativeTranscriptRow: Identifiable, Hashable {
    enum Content: Hashable {
        case history(NativeTranscriptHistory)
        case transcript(TranscriptItem, canEdit: Bool, questionnaireKey: String?)
    }

    let content: Content
    let spacingAfter: CGFloat

    var id: String {
        switch content {
        case .history: "transcript:history"
        case let .transcript(item, _, _): item.id
        }
    }

    static func rows(
        items: [TranscriptItem],
        history: NativeTranscriptHistory?,
        lastUserMessageID: String?,
        questionnaireToolCallID: String?,
        questionnaireKey: String?
    ) -> [NativeTranscriptRow] {
        var allContent: [Content] = []
        if let history { allContent.append(.history(history)) }
        allContent += items.map { item in
            let canEdit: Bool
            if case let .message(message, _) = item {
                canEdit = message.role == .user && message.id == lastUserMessageID
            } else {
                canEdit = false
            }
            let rowQuestionnaireKey: String?
            if case let .work(block) = item,
               let questionnaireToolCallID,
               block.prominentSteps.contains(where: { $0.id == questionnaireToolCallID }) {
                rowQuestionnaireKey = questionnaireKey
            } else {
                rowQuestionnaireKey = nil
            }
            return .transcript(item, canEdit: canEdit, questionnaireKey: rowQuestionnaireKey)
        }
        return allContent.enumerated().map { index, content in
            NativeTranscriptRow(
                content: content,
                spacingAfter: index + 1 == allContent.count ? 0 : PiTheme.transcriptEntrySpacing
            )
        }
    }
}

enum NativeTranscriptStructuralChange: Equatable {
    case unchanged
    case prepend(Range<Int>)
    case append(Range<Int>)
    case removeSuffix(Range<Int>)
    case replace

    static func classify(old: [String], new: [String]) -> Self {
        if old == new { return .unchanged }
        if new.count > old.count {
            let commonPrefix = zip(old, new).prefix(while: ==).count
            let insertedCount = new.count - old.count
            if Array(new.dropFirst(commonPrefix + insertedCount)) == Array(old.dropFirst(commonPrefix)) {
                let range = commonPrefix..<(commonPrefix + insertedCount)
                return commonPrefix == old.count ? .append(range) : .prepend(range)
            }
        }
        if old.count > new.count, Array(old.prefix(new.count)) == new {
            return .removeSuffix(new.count..<old.count)
        }
        return .replace
    }
}

enum NativeTranscriptGeometry {
    static func topInset(
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        topPadding: CGFloat = PiTheme.space24,
        bottomPadding: CGFloat = PiTheme.space8
    ) -> CGFloat {
        topPadding + max(0, viewportHeight - documentHeight - topPadding - bottomPadding)
    }

    static func bottomOriginY(
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        max(-topInset, documentHeight - viewportHeight + bottomInset)
    }

    /// Following the tail is an exact state, not the jump button's generous visual threshold:
    /// moving upward by more than one backing pixel must immediately release the pin.
    static func isPinned(originY: CGFloat, bottomOriginY: CGFloat, backingScale: CGFloat) -> Bool {
        bottomOriginY - originY <= 1 / max(1, backingScale)
    }

    static func snappedUp(_ value: CGFloat, backingScale: CGFloat) -> CGFloat {
        ceil(value * max(1, backingScale)) / max(1, backingScale)
    }

    static func anchorIndex(startingAt index: Int, rows: [NativeTranscriptRow]) -> Int? {
        guard rows.indices.contains(index) else { return nil }
        if case .transcript = rows[index].content { return index }
        return rows.indices.dropFirst(index + 1).first { candidate in
            if case .transcript = rows[candidate].content { true } else { false }
        }
    }
}

@MainActor
private final class NativeTranscriptActions {
    var loadEarlier: () -> Void = {}
    var editLastMessage: () -> Void = {}
    var firstPaint: () -> Void = {}
    var invalidateLayout: (String) -> Void = { _ in }
    private var markedFirstPaint = false

    func resetFirstPaint() { markedFirstPaint = false }

    func markFirstPaint() {
        guard !markedFirstPaint else { return }
        markedFirstPaint = true
        firstPaint()
    }
}

private struct NativeTranscriptRowView: View {
    let row: NativeTranscriptRow
    let store: AppStore
    let actions: NativeTranscriptActions
    /// Measurement hosts must not report a paint that never reached the screen.
    let marksFirstPaint: Bool

    var body: some View {
        content
            .frame(maxWidth: PiTheme.transcriptMaxWidth, alignment: .leading)
            .padding(.horizontal, PiTheme.space20)
            .frame(maxWidth: .infinity, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, row.spacingAfter)
            .environmentObject(store)
            .environment(\.transcriptRowLayoutInvalidation, { actions.invalidateLayout(row.id) })
            .id(row.id)
    }

    @ViewBuilder
    private var content: some View {
        switch row.content {
        case let .history(state):
            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Loading earlier messages")
            case .loadEarlier:
                Button("Load earlier messages", action: actions.loadEarlier)
                    .buttonStyle(.plain)
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            case .limitReached:
                Text("Earlier history is outside this bounded window.")
                    .font(PiFont.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        case let .transcript(item, canEdit, questionnaireKey):
            Group {
                switch item {
                case let .message(message, isStreaming):
                    MessageView(
                        message: message,
                        isStreaming: isStreaming,
                        onImage: store.showImage,
                        showsActions: true,
                        onEdit: canEdit ? actions.editLastMessage : nil
                    )
                    .equatable()
                    .padding(.top, message.role == .user ? PiTheme.transcriptTurnSpacing : 0)
                case let .work(block):
                    TranscriptWorkView(
                        block: block,
                        onImage: store.showImage,
                        questionnaireKey: questionnaireKey
                    )
                    .equatable()
                    .padding(.top, PiTheme.space6)
                }
            }
            .onAppear {
                if marksFirstPaint { actions.markFirstPaint() }
            }
        }
    }
}

@MainActor
private final class NativeTranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class NativeTranscriptCell: NSTableCellView {
    let host: NSHostingView<NativeTranscriptRowView>
    private(set) var row: NativeTranscriptRow

    init(row: NativeTranscriptRow, root: NativeTranscriptRowView) {
        self.row = row
        host = NSHostingView(rootView: root)
        super.init(frame: .zero)
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(row: NativeTranscriptRow, root: NativeTranscriptRowView) {
        guard self.row != row else { return }
        self.row = row
        host.rootView = root
    }
}

/// AppKit owns the transcript's viewport, row geometry, scroller, and first paint. SwiftUI still
/// owns each row's content, but never owns transcript scrolling or lazy height estimation.
struct NativeTranscriptView: NSViewRepresentable {
    @EnvironmentObject private var store: AppStore

    let route: AppRoute
    let rows: [NativeTranscriptRow]
    let isLoadingEarlier: Bool
    let pinRequest: Int
    let performancePath: String
    let onLoadEarlier: () -> Void
    let onEditLastMessage: (() -> Void)?
    let onMetrics: (ConversationScrollMetrics) -> Void
    let onFirstPaint: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private static let retainedCellLimit = 160

        private struct HeightEntry {
            let row: NativeTranscriptRow
            let width: CGFloat
            let height: CGFloat
        }

        private struct Snapshot {
            let route: AppRoute
            let rows: [NativeTranscriptRow]
            let isLoadingEarlier: Bool
            let pinRequest: Int
            let performancePath: String
        }

        private weak var scrollView: NSScrollView?
        private let documentView = NativeTranscriptDocumentView()
        private let tableView = NSTableView()
        private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        private let actions = NativeTranscriptActions()
        private var store: AppStore?
        private var rows: [NativeTranscriptRow] = []
        private var currentRoute: AppRoute?
        private var latestSnapshot: Snapshot?
        private var heights: [String: HeightEntry] = [:]
        /// Keep a realized row's host by durable ID so its disclosure/text-selection state survives
        /// AppKit taking it off screen. The transcript itself is bounded to 1,000 messages.
        // ponytail: a small LRU preserves nearby disclosure/selection state without retaining a
        // full 1,000-message transcript's hosting graphs.
        private var cells: [String: NativeTranscriptCell] = [:]
        private var cellUseOrder: [String] = []
        private var measurer: NSHostingController<NativeTranscriptRowView>?
        private var boundsObserver: NSObjectProtocol?
        private var clipFrameObserver: NSObjectProtocol?
        private var tableFrameObserver: NSObjectProtocol?
        private var measurementWidth: CGFloat = 0
        private var lastPinRequest = 0
        private var followsBottom = true
        private var hasUserScrolledCurrentRoute = false
        private var lastObservedDocumentHeight: CGFloat = 0
        private var previousNormalizedOrigin: CGFloat?
        private var isApplying = false
        private var pendingMetrics: ConversationScrollMetrics?
        private var metricsScheduled = false
        private var invalidationScheduled = false
        private var invalidatedRowIDs: Set<String> = []
        private var onMetrics: (ConversationScrollMetrics) -> Void = { _ in }

        func makeScrollView() -> NSScrollView {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.horizontalScrollElasticity = .none
            scroll.verticalScrollElasticity = .automatic
            scroll.automaticallyAdjustsContentInsets = false

            tableView.headerView = nil
            tableView.cornerView = nil
            tableView.backgroundColor = .clear
            tableView.gridStyleMask = []
            tableView.intercellSpacing = .zero
            tableView.rowHeight = 44
            tableView.usesAutomaticRowHeights = false
            tableView.selectionHighlightStyle = .none
            tableView.allowsEmptySelection = true
            tableView.allowsMultipleSelection = false
            tableView.allowsTypeSelect = false
            tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            tableView.autoresizingMask = [.width]
            tableView.dataSource = self
            tableView.delegate = self
            actions.invalidateLayout = { [weak self] rowID in self?.scheduleLayoutInvalidation(rowID) }
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)
            documentView.autoresizingMask = [.width]
            tableView.autoresizingMask = [.width, .height]
            documentView.addSubview(tableView)
            scroll.documentView = documentView
            self.scrollView = scroll

            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            documentView.postsFrameChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundsChanged() }
            }
            clipFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scroll.contentView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.viewportChanged() }
            }
            tableFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: documentView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.documentChanged() }
            }
            return scroll
        }

        func update(from parent: NativeTranscriptView) {
            store = parent.store
            actions.loadEarlier = parent.onLoadEarlier
            actions.editLastMessage = parent.onEditLastMessage ?? {}
            actions.firstPaint = parent.onFirstPaint
            onMetrics = parent.onMetrics

            let snapshot = Snapshot(
                route: parent.route,
                rows: parent.rows,
                isLoadingEarlier: parent.isLoadingEarlier,
                pinRequest: parent.pinRequest,
                performancePath: parent.performancePath
            )
            latestSnapshot = snapshot
            guard viewportWidth > 1 else { return }
            applyOrHold(snapshot)
        }

        func detach() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let clipFrameObserver { NotificationCenter.default.removeObserver(clipFrameObserver) }
            if let tableFrameObserver { NotificationCenter.default.removeObserver(tableFrameObserver) }
            boundsObserver = nil
            clipFrameObserver = nil
            tableFrameObserver = nil
            cells.removeAll()
            cellUseOrder.removeAll()
            measurer = nil
            scrollView = nil
        }

        // MARK: Table data source/delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow rowIndex: Int) -> CGFloat {
            guard rows.indices.contains(rowIndex) else { return tableView.rowHeight }
            return height(for: rows[rowIndex])
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row rowIndex: Int) -> NSView? {
            guard rows.indices.contains(rowIndex), let store else { return nil }
            let row = rows[rowIndex]
            let root = NativeTranscriptRowView(row: row, store: store, actions: actions, marksFirstPaint: true)
            if let cell = cells[row.id] {
                cell.update(row: row, root: root)
                touchCell(row.id)
                return cell
            }
            let cell = NativeTranscriptCell(row: row, root: root)
            cell.identifier = NSUserInterfaceItemIdentifier(row.id)
            cells[row.id] = cell
            touchCell(row.id)
            return cell
        }

        // MARK: Atomic updates

        private func applyOrHold(_ snapshot: Snapshot) {
            let routeChanged = currentRoute != snapshot.route
            if !routeChanged, snapshot.isLoadingEarlier,
               isStrictPrepend(old: transcriptIDs(rows), new: transcriptIDs(snapshot.rows)) {
                return
            }
            apply(snapshot, routeChanged: routeChanged)
        }

        private func apply(_ snapshot: Snapshot, routeChanged: Bool) {
            guard let scrollView, store != nil else { return }
            let started = NativeTranscriptDebug.enabled ? CFAbsoluteTimeGetCurrent() : 0
            let widthChanged = updateMeasurementWidth()
            let rowsChanged = rows != snapshot.rows
            let pinRequested = snapshot.pinRequest != lastPinRequest
            guard routeChanged || widthChanged || rowsChanged || pinRequested else {
                publish(direction: .stationary)
                return
            }

            let wasPinned = routeChanged || pinRequested || followsBottom
            let anchor = wasPinned ? nil : captureAnchor()
            let oldRows = rows
            let change = routeChanged ? NativeTranscriptStructuralChange.replace : .classify(
                old: oldRows.map(\.id), new: snapshot.rows.map(\.id)
            )

            isApplying = true
            defer { isApplying = false }
            if routeChanged {
                currentRoute = snapshot.route
                followsBottom = true
                hasUserScrolledCurrentRoute = false
                actions.resetFirstPaint()
                heights.removeAll(keepingCapacity: true)
                cells.removeAll(keepingCapacity: true)
                cellUseOrder.removeAll(keepingCapacity: true)
                measurer = nil
            }
            lastPinRequest = snapshot.pinRequest
            if pinRequested { hasUserScrolledCurrentRoute = false }
            if widthChanged {
                heights.removeAll(keepingCapacity: true)
                let width = max(1, scrollView.contentView.bounds.width)
                documentView.setFrameSize(NSSize(width: width, height: max(1, documentView.frame.height)))
                tableView.setFrameSize(documentView.frame.size)
                tableView.layoutSubtreeIfNeeded()
            }

            // Every height is exact before NSTableView sees the mutation; its document/scroller
            // geometry therefore has no estimate to revise after the first frame.
            for row in snapshot.rows { _ = height(for: row) }
            let oldByID = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.id, $0) })
            rows = snapshot.rows

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                switch change {
                case .unchanged:
                    break
                case let .prepend(range), let .append(range):
                    tableView.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
                case let .removeSuffix(range):
                    tableView.removeRows(at: IndexSet(integersIn: range), withAnimation: [])
                case .replace:
                    tableView.reloadData()
                }
            }

            let insertedIDs = Set(snapshot.rows.map(\.id)).subtracting(oldRows.map(\.id))
            var changed = IndexSet(snapshot.rows.indices.filter { index in
                let row = snapshot.rows[index]
                return !insertedIDs.contains(row.id) && oldByID[row.id] != row
            })
            if widthChanged {
                changed.formUnion(IndexSet(snapshot.rows.indices.filter { cells[snapshot.rows[$0].id] != nil }))
            }
            for index in changed {
                let row = snapshot.rows[index]
                if let cell = cells[row.id], let store {
                    cell.update(
                        row: row,
                        root: NativeTranscriptRowView(row: row, store: store, actions: actions, marksFirstPaint: true)
                    )
                    if widthChanged {
                        cell.setFrameSize(NSSize(width: max(1, viewportWidth), height: max(1, cell.frame.height)))
                        cell.layoutSubtreeIfNeeded()
                    }
                    if let measured = displayedHeight(of: cell) {
                        heights[row.id] = HeightEntry(row: row, width: measurementWidth, height: measured)
                    }
                }
            }
            if !changed.isEmpty { tableView.noteHeightOfRows(withIndexesChanged: changed) }

            let currentIDs = Set(snapshot.rows.map(\.id))
            cells = cells.filter { currentIDs.contains($0.key) }
            cellUseOrder.removeAll { !currentIDs.contains($0) }
            heights = heights.filter { currentIDs.contains($0.key) }

            tableView.layoutSubtreeIfNeeded()
            syncDocumentFrame()
            scrollView.layoutSubtreeIfNeeded()
            syncDocumentFrame()
            updateInsets()
            if wasPinned { scrollToBottom() }
            else if let anchor { restore(anchor) }
            tableView.layoutSubtreeIfNeeded()
            syncDocumentFrame()
            realizeVisibleRows()
            previousNormalizedOrigin = normalizedOrigin
            lastObservedDocumentHeight = documentHeight
            NativeTranscriptDebug.log(
                "apply path=\(snapshot.performancePath) rows=\(rows.count) doc=\(Int(documentHeight)) rowRects=\(Int(rowContentHeight)) origin=\(Int(scrollView.contentView.bounds.origin.y)) bottom=\(Int(bottomOrigin)) pinned=\(followsBottom) ms=\(Int((CFAbsoluteTimeGetCurrent() - started) * 1_000))"
            )
            publish(direction: .stationary, allowsUnderfillPaging: routeChanged || rowsChanged)
        }

        // MARK: Measurement

        private var viewportWidth: CGFloat { scrollView?.contentView.bounds.width ?? 0 }

        private func updateMeasurementWidth() -> Bool {
            guard let scrollView else { return false }
            let scale = backingScale
            let proposed = min(viewportWidth, PiTheme.transcriptMaxWidth + 2 * PiTheme.space20)
            let snapped = floor(max(1, proposed) * scale) / scale
            let changed = abs(snapped - measurementWidth) > 1 / scale
            measurementWidth = snapped
            column.width = max(1, scrollView.contentView.bounds.width)
            return changed
        }

        private func height(for row: NativeTranscriptRow) -> CGFloat {
            if let cached = heights[row.id], cached.row == row,
               abs(cached.width - measurementWidth) < 0.5 {
                return cached.height
            }
            guard let store else { return tableView.rowHeight }
            let root = NativeTranscriptRowView(row: row, store: store, actions: actions, marksFirstPaint: false)
            let controller: NSHostingController<NativeTranscriptRowView>
            if let measurer {
                controller = measurer
                controller.rootView = root
            } else {
                controller = NSHostingController(rootView: root)
                measurer = controller
            }
            let measured = controller.sizeThatFits(in: NSSize(
                width: max(1, measurementWidth), height: CGFloat.greatestFiniteMagnitude
            )).height
            let height = max(1, NativeTranscriptGeometry.snappedUp(measured, backingScale: backingScale))
            heights[row.id] = HeightEntry(row: row, width: measurementWidth, height: height)
            return height
        }

        private var backingScale: CGFloat {
            scrollView?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        }

        private func displayedHeight(of cell: NativeTranscriptCell) -> CGFloat? {
            cell.host.layoutSubtreeIfNeeded()
            let value = cell.host.intrinsicContentSize.height
            guard value.isFinite, value > 0 else { return nil }
            return NativeTranscriptGeometry.snappedUp(value, backingScale: backingScale)
        }

        // MARK: Explicit row-state layout

        private func scheduleLayoutInvalidation(_ rowID: String) {
            invalidatedRowIDs.insert(rowID)
            guard !invalidationScheduled else { return }
            invalidationScheduled = true
            DispatchQueue.main.async { [weak self] in self?.applyLayoutInvalidations() }
        }

        private func applyLayoutInvalidations() {
            invalidationScheduled = false
            let ids = invalidatedRowIDs
            invalidatedRowIDs.removeAll(keepingCapacity: true)
            guard !isApplying, !ids.isEmpty, let scrollView else { return }
            let indexes = IndexSet(ids.compactMap { id in rows.firstIndex(where: { $0.id == id }) })
            guard !indexes.isEmpty else { return }
            let wasPinned = followsBottom
            let anchor = wasPinned ? nil : captureAnchor()
            var changed = IndexSet()
            for index in indexes {
                let row = rows[index]
                guard let cell = cells[row.id] else { continue }
                guard let measured = displayedHeight(of: cell),
                      let old = heights[row.id], abs(old.height - measured) > 0.5 else { continue }
                heights[row.id] = HeightEntry(row: row, width: measurementWidth, height: measured)
                changed.insert(index)
            }
            guard !changed.isEmpty else { return }
            isApplying = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: changed)
                tableView.layoutSubtreeIfNeeded()
                syncDocumentFrame()
                scrollView.layoutSubtreeIfNeeded()
                syncDocumentFrame()
            }
            updateInsets()
            if wasPinned { scrollToBottom() }
            else if let anchor { restore(anchor) }
            lastObservedDocumentHeight = documentHeight
            previousNormalizedOrigin = normalizedOrigin
            isApplying = false
            NativeTranscriptDebug.log("explicit layout rows=\(changed) doc=\(Int(documentHeight))")
            publish(direction: .stationary)
        }

        // MARK: Scroll ownership

        private struct Anchor {
            let rowID: String
            let offset: CGFloat
            let fallbackOrigin: CGFloat
        }

        private var rowContentHeight: CGFloat {
            guard !rows.isEmpty else { return 0 }
            return tableView.rect(ofRow: rows.count - 1).maxY
        }

        /// NSClipView constrains against its document view's real bounds, so every target and
        /// metric must use that same geometry. Row rects can lead the table frame briefly while
        /// an update is being committed; targeting that estimate causes an elastic settle that
        /// looks like (and used to be mistaken for) a user scroll.
        private var documentHeight: CGFloat { documentView.bounds.height }

        private func syncDocumentFrame() {
            guard let scrollView else { return }
            let target = NSSize(width: max(1, scrollView.contentView.bounds.width), height: max(1, rowContentHeight))
            if abs(documentView.frame.width - target.width) > 0.5 || abs(documentView.frame.height - target.height) > 0.5 {
                documentView.setFrameSize(target)
            }
            if tableView.frame.size != target { tableView.setFrameSize(target) }
        }

        private var normalizedOrigin: CGFloat {
            guard let scrollView else { return 0 }
            return scrollView.contentView.bounds.origin.y + scrollView.contentInsets.top
        }

        private var bottomOrigin: CGFloat {
            guard let scrollView else { return 0 }
            return NativeTranscriptGeometry.bottomOriginY(
                documentHeight: documentHeight,
                viewportHeight: scrollView.contentView.bounds.height,
                topInset: scrollView.contentInsets.top,
                bottomInset: scrollView.contentInsets.bottom
            )
        }

        private func updateInsets() {
            guard let scrollView else { return }
            let top = NativeTranscriptGeometry.topInset(
                documentHeight: documentHeight,
                viewportHeight: scrollView.contentView.bounds.height
            )
            let target = NSEdgeInsets(top: top, left: 0, bottom: PiTheme.space8, right: 0)
            let current = scrollView.contentInsets
            if current.top != target.top || current.bottom != target.bottom
                || current.left != target.left || current.right != target.right {
                scrollView.contentInsets = target
            }
        }

        private func scrollToBottom() {
            guard scrollView != nil else { return }
            setOrigin(bottomOrigin)
            followsBottom = true
        }

        private func setOrigin(_ y: CGFloat) {
            guard let scrollView else { return }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func captureAnchor() -> Anchor? {
            guard let scrollView, !rows.isEmpty else { return nil }
            let origin = scrollView.contentView.bounds.origin.y
            let y = max(0, origin)
            var index = tableView.row(at: NSPoint(x: 0, y: y))
            if index < 0 { index = min(rows.count - 1, max(0, tableView.rows(in: scrollView.contentView.bounds).location)) }
            guard let index = NativeTranscriptGeometry.anchorIndex(startingAt: index, rows: rows) else { return nil }
            return Anchor(
                rowID: rows[index].id,
                offset: origin - tableView.rect(ofRow: index).minY,
                fallbackOrigin: origin
            )
        }

        private func restore(_ anchor: Anchor) {
            guard let scrollView else { return }
            let target: CGFloat
            if let index = rows.firstIndex(where: { $0.id == anchor.rowID }) {
                target = tableView.rect(ofRow: index).minY + anchor.offset
            } else {
                target = anchor.fallbackOrigin
            }
            setOrigin(min(bottomOrigin, max(-scrollView.contentInsets.top, target)))
        }

        private func realizeVisibleRows() {
            guard let scrollView, !rows.isEmpty else { return }
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            guard visible.location != NSNotFound else { return }
            let lower = max(0, visible.location - max(1, visible.length))
            let upper = min(rows.count, visible.location + 2 * max(1, visible.length))
            for index in lower..<upper { _ = tableView.rowView(atRow: index, makeIfNecessary: true) }
            trimRetainedCells()
        }

        private func touchCell(_ id: String) {
            cellUseOrder.removeAll { $0 == id }
            cellUseOrder.append(id)
        }

        private func trimRetainedCells() {
            guard cells.count > Self.retainedCellLimit else { return }
            let firstResponder = scrollView?.window?.firstResponder as? NSView
            var retained: [String] = []
            for id in cellUseOrder {
                guard let cell = cells[id] else { continue }
                guard cells.count > Self.retainedCellLimit else {
                    retained.append(id)
                    continue
                }
                let ownsFirstResponder = firstResponder.map {
                    $0 === cell || $0.isDescendant(of: cell)
                } ?? false
                if cell.superview != nil || ownsFirstResponder { retained.append(id) }
                else { cells.removeValue(forKey: id) }
            }
            cellUseOrder = retained
        }

        private func boundsChanged() {
            guard !isApplying, let scrollView else { return }
            let current = normalizedOrigin
            guard isUserScrollEvent else {
                if followsBottom,
                   !NativeTranscriptGeometry.isPinned(
                       originY: scrollView.contentView.bounds.origin.y,
                       bottomOriginY: bottomOrigin,
                       backingScale: backingScale
                   ) {
                    isApplying = true
                    setOrigin(bottomOrigin)
                    isApplying = false
                }
                previousNormalizedOrigin = normalizedOrigin
                NativeTranscriptDebug.log(
                    "bounds settle origin=\(Int(scrollView.contentView.bounds.origin.y)) bottom=\(Int(bottomOrigin)) pinned=\(followsBottom)"
                )
                publish(direction: .stationary)
                return
            }
            hasUserScrolledCurrentRoute = true
            let direction: ConversationScrollMetrics.Direction
            if let previous = previousNormalizedOrigin, abs(current - previous) > 0.5 {
                direction = current < previous ? .up : .down
            } else {
                direction = .stationary
            }
            previousNormalizedOrigin = current
            followsBottom = NativeTranscriptGeometry.isPinned(
                originY: scrollView.contentView.bounds.origin.y,
                bottomOriginY: bottomOrigin,
                backingScale: backingScale
            )
            NativeTranscriptDebug.log(
                "bounds user origin=\(Int(scrollView.contentView.bounds.origin.y)) normalized=\(Int(current)) bottom=\(Int(bottomOrigin)) direction=\(direction) pinned=\(followsBottom)"
            )
            publish(direction: direction)
        }

        private var isUserScrollEvent: Bool {
            guard let event = NSApp.currentEvent else { return false }
            return switch event.type {
            case .scrollWheel:
                event.momentumPhase.isEmpty || hasUserScrolledCurrentRoute
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown:
                true
            default:
                false
            }
        }

        private func viewportChanged() {
            guard !isApplying, let snapshot = latestSnapshot, viewportWidth > 1 else { return }
            apply(snapshot, routeChanged: currentRoute != snapshot.route)
            guard !isApplying else { return }
            isApplying = true
            syncDocumentFrame()
            lastObservedDocumentHeight = documentHeight
            updateInsets()
            if followsBottom { scrollToBottom() }
            isApplying = false
            publish(direction: .stationary)
        }

        private func documentChanged() {
            guard !isApplying else { return }
            let newHeight = documentHeight
            if abs(newHeight - lastObservedDocumentHeight) > 0.5 {
                NativeTranscriptDebug.log(
                    "document without data \(Int(lastObservedDocumentHeight))->\(Int(newHeight)) rows=\(rows.count)"
                )
                lastObservedDocumentHeight = newHeight
            }
            isApplying = true
            syncDocumentFrame()
            lastObservedDocumentHeight = documentHeight
            updateInsets()
            if followsBottom { scrollToBottom() }
            isApplying = false
            publish(direction: .stationary)
        }

        private func publish(
            direction: ConversationScrollMetrics.Direction,
            allowsUnderfillPaging: Bool = false
        ) {
            guard let scrollView else { return }
            let retainedUnderfillIntent = pendingMetrics?.allowsUnderfillPaging == true
            let effectiveDirection = direction == .stationary
                ? (pendingMetrics?.direction ?? .stationary)
                : direction
            pendingMetrics = ConversationScrollMetrics(
                originY: normalizedOrigin,
                viewportHeight: scrollView.contentView.bounds.height,
                documentHeight: documentHeight + scrollView.contentInsets.top + scrollView.contentInsets.bottom,
                direction: effectiveDirection,
                allowsUnderfillPaging: allowsUnderfillPaging || retainedUnderfillIntent
            )
            guard !metricsScheduled else { return }
            metricsScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                metricsScheduled = false
                guard let metrics = pendingMetrics else { return }
                pendingMetrics = nil
                onMetrics(metrics)
            }
        }

        private func transcriptIDs(_ rows: [NativeTranscriptRow]) -> [String] {
            rows.compactMap { row in
                if case .transcript = row.content { row.id } else { nil }
            }
        }

        private func isStrictPrepend(old: [String], new: [String]) -> Bool {
            new.count > old.count && Array(new.suffix(old.count)) == old
        }
    }
}
