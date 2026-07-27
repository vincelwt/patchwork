import AppKit
import Combine
import Foundation
import SwiftUI

/// Where a submission came from. A late failure may only touch the draft when the user is
/// still on the same route, so conversation A's error can never inject text or images into
/// conversation B's composer.
struct DraftOrigin: Equatable {
    let route: AppRoute
    let sessionPath: String?

    static func shouldRestoreDraft(origin: DraftOrigin, currentRoute: AppRoute, currentSessionPath: String?) -> Bool {
        origin.route == currentRoute && origin.sessionPath == currentSessionPath
    }

    var conversationDescription: String {
        switch route {
        case .newChat: return "the new chat"
        case .session: return "another conversation"
        }
    }
}

struct DraftRecovery {
    static func restoredText(sent: String, current: String) -> String {
        guard !sent.isEmpty else { return current }
        guard !current.isEmpty else { return sent }
        return sent + "\n" + current
    }

    static func restoredAttachments(sent: [ImageAttachment], current: [ImageAttachment]) -> [ImageAttachment] {
        let existing = Set(current.map(\.id))
        return Array((sent.filter { !existing.contains($0.id) } + current).prefix(PiTheme.imageCountLimit))
    }
}

/// The one user-authored message currently in flight, from the moment "prompt" is sent until
/// its outcome is fully known (accepted-and-settled, or a receive failure that already restored
/// it). `handleRuntimeExit` is the only place that ever acts on this when it is still set — by
/// construction the same crash always rejects the pending RPC completion first — so a crash
/// mid-turn can be recovered exactly once, never duplicated into the draft by two code paths
/// reacting to the same event.
private struct PendingUserTurn {
    let origin: DraftOrigin
    let text: String
    let attachments: [ImageAttachment]
}

private struct LiveMessageKey: Equatable {
    let path: String
    let id: String
}

/// One independent Pi process plus the route-visible state that must follow it when the user
/// switches conversations mid-turn. Idle processes are still reused; only live work is parked.
private final class RuntimeSlot {
    let id = UUID()
    let runtime: PiRuntimeProtocol
    var sessionPath: String?
    var cwd: String?
    var startedForNewChat = false
    var state = RuntimeState()
    var metrics = TokenMetrics()
    var models: [AvailableModel] = []
    var thinkingLevels = ["off"]
    var optionsLoading = false
    var optionsPrepared = false
    var capability: ToolCapability?
    var questionnaire: QuestionnaireSession?
    var statuses: [String: String] = [:]
    var widgets: [String: ExtensionWidget] = [:]
    var windowTitle = "Pi Desktop"
    var dialogs: [ExtensionDialogRequest] = []
    var outbox: [OutboxEntry] = []
    var streamingMessage: ChatMessage?
    var pendingTurn: PendingUserTurn?
    var outboxDispatches: Set<UUID> = []
    var deferredEvents: [JSONValue] = []
    var isReady = false
    var isStarting = false
    var startupBeganAt: Date?
    var promptBeganAt: Date?
    var readyWaiters: [(Result<RuntimeSlot, Error>) -> Void] = []
    var isSuperseded = false

    init(runtime: PiRuntimeProtocol) { self.runtime = runtime }
}

private enum RuntimeRouteKey: Hashable {
    case session(String)
    case newChat(String)
}

typealias RuntimeRetirementScheduler = (
    _ delay: TimeInterval,
    _ action: @escaping @MainActor () -> Void
) -> () -> Void

/// Bounds and LRU-evicts persisted conversation drafts so `state.json` cannot grow without
/// bound across months of use. Recency is tracked purely in memory (never persisted itself);
/// a dictionary loaded over the cap — e.g. from hand-edited state — is trimmed back into bounds
/// immediately.
struct DraftStore {
    static let maxDraftLength = 20_000
    static let maxRetainedDrafts = 200

    private(set) var texts: [String: String]
    private var touchOrder: [String]

    init(texts: [String: String] = [:]) {
        let order = Array(texts.keys).suffix(Self.maxRetainedDrafts)
        touchOrder = Array(order)
        self.texts = Dictionary(uniqueKeysWithValues: order.map { ($0, texts[$0] ?? "") })
    }

    func text(for key: String) -> String { texts[key] ?? "" }

    /// Empty text removes the entry outright rather than retaining a blank placeholder. Returns
    /// any keys evicted by this write so the caller can drop their parked attachments too.
    @discardableResult
    mutating func set(_ text: String, for key: String) -> [String] {
        let bounded = text.count <= Self.maxDraftLength ? text : String(text.prefix(Self.maxDraftLength))
        guard !bounded.isEmpty else {
            remove(key)
            return []
        }
        texts[key] = bounded
        touchOrder.removeAll { $0 == key }
        touchOrder.append(key)
        var evicted: [String] = []
        while touchOrder.count > Self.maxRetainedDrafts {
            let stale = touchOrder.removeFirst()
            texts.removeValue(forKey: stale)
            evicted.append(stale)
        }
        return evicted
    }

    mutating func remove(_ key: String) {
        texts.removeValue(forKey: key)
        touchOrder.removeAll { $0 == key }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var route: AppRoute = .newChat
    @Published var searchText = ""
    @Published var isScanning = false
    @Published var scanError: String?

    @Published var messages: [ChatMessage] = [] { didSet { transcriptRevision &+= 1 } }
    @Published var streamingMessage: ChatMessage? { didSet { transcriptRevision &+= 1 } }
    /// Plain revision counter for memoizing transcript projection. It deliberately is not
    /// published: `messages`/`streamingMessage` already invalidate the view exactly once.
    private(set) var transcriptRevision = 0
    @Published var isConversationLoading = false
    @Published private(set) var isLoadingEarlierMessages = false
    @Published private(set) var hasEarlierMessages = false
    @Published private(set) var conversationHistoryLimitReached = false
    @Published private(set) var initialScrollTargetMessageID: String?
    @Published var conversationError: String?

    @Published var draft = ""
    @Published var attachments: [ImageAttachment] = []
    @Published var selectedFolder: URL?
    @Published var runtimeState = RuntimeState()
    @Published var liveMetrics = TokenMetrics()
    @Published private(set) var availableModels: [AvailableModel] = []
    @Published private(set) var availableThinkingLevels: [String] = ["off"]
    @Published private(set) var composerOptionsLoading = false
    @Published private(set) var activeCapability: ToolCapability?
    @Published private(set) var pendingQuestionnaire: QuestionnaireSession?

    @Published var folderGit: [String: GitSnapshot] = [:]
    @Published var selectedGit = GitSnapshot.none
    /// Present only for a cwd that resolves to a linked git worktree; refreshed on the exact
    /// same cadence and cache keys as `folderGit`/`selectedGit` (Task 2), just kept in a sibling
    /// dictionary instead of a field on `GitSnapshot`. Absent entirely for a plain checkout.
    @Published var folderWorktrees: [String: GitWorktreeInfo] = [:]
    @Published var selectedWorktree: GitWorktreeInfo?
    @Published var activities: [ActivityItem] = []
    @Published var extensionStatuses: [String: String] = [:]
    @Published var extensionWidgets: [String: ExtensionWidget] = [:]
    @Published var activeDialog: ExtensionDialogRequest?
    /// FIFO of extension dialogs so a second request never replaces an unanswered one.
    private var dialogQueue: [ExtensionDialogRequest] = []
    private static let dialogQueueLimit = 16
    @Published var toast: ToastMessage?
    @Published var viewedImage: ViewedImage?
    @Published var windowTitle = "Pi Desktop"
    @Published var inspectorVisible = true
    @Published var quickSwitchPresented = false
    /// Shared request surface: sidebar and application menu present the same creation alert.
    @Published var newVirtualFolderRequested = false
    @Published var schedulesPresented = false
    /// Messages the user queued while Pi was working, still editable until they are flushed to
    /// Pi at the boundary Pi would have delivered them anyway. See `Outbox.swift`.
    @Published var outbox: [OutboxEntry] = []
    /// Lazily created so the panel keeps one service for the app's lifetime.
    var cachedScheduleService: (any ScheduleServing)?
    /// Set by the Conversation menu so the rename sheet can live with the transcript.
    @Published var renameRequested = false
    /// True only while the ephemeral status probe runtime is attached.
    @Published private(set) var isProbingStatuses = false
    @Published private(set) var unknownRPCEvents: [String] = []

    let activityMonitor: SessionActivityMonitor

    private let repository: SessionRepositoryProtocol
    private let gitService: GitStatusProviding
    /// Internal rather than private so focused extensions (the outbox, message editing) can
    /// speak to whichever selected conversation owns the current runtime.
    var runtime: PiRuntimeProtocol { activeRuntimeSlot.runtime }
    let persistence: AppPersistence
    private let activityPresenter: ActivityPresenting
    private let runtimeFactory: () -> PiRuntimeProtocol
    private let runtimeRetirementDelay: TimeInterval
    private let runtimeRetirementScheduler: RuntimeRetirementScheduler
    private var cancelRuntimeRetirement: (() -> Void)?
    private var activeRuntimeSlot: RuntimeSlot
    private var activePresentationDetached = false
    private var parkedRuntimes: [RuntimeRouteKey: RuntimeSlot] = [:]
    /// Creates the short-lived `--no-session` runtime used only to refresh extension statuses.
    /// `nil` disables probing entirely (tests never spawn a process).
    private let probeRuntimeFactory: (() -> PiRuntimeProtocol)?
    private var bootstrapped = false
    private var activeRuntimePath: String? {
        get { activeRuntimeSlot.sessionPath }
        set { activeRuntimeSlot.sessionPath = newValue }
    }
    private var activeRuntimeCwd: String? {
        get { activeRuntimeSlot.cwd }
        set { activeRuntimeSlot.cwd = newValue }
    }
    /// Distinguishes a runtime intentionally opened for New Chat from an attached session in
    /// the same folder; otherwise a new prompt could accidentally resume the previous session.
    private var activeRuntimeStartedForNewChat: Bool {
        get { activeRuntimeSlot.startedForNewChat }
        set { activeRuntimeSlot.startedForNewChat = newValue }
    }
    private var gitRefreshTask: Task<Void, Never>?
    private var selectedGitTask: Task<Void, Never>?
    private var conversationLoadTask: Task<Void, Never>?
    private var earlierMessagesTask: Task<Void, Never>?
    private var activityProjectionTask: Task<Void, Never>?
    private var conversationLoadGeneration = 0
    private var loadedConversationPage: ConversationPage?
    private var loadedConversationPath: String?
    private var loadedConversationFingerprint: SessionFileFingerprint?
    private var initialPreviousSeenCompletionID: String?
    private var toastTask: Task<Void, Never>?
    private var dialogTimeoutTask: Task<Void, Never>?
    private var probeRuntime: PiRuntimeProtocol?
    private var probeTask: Task<Void, Never>?
    private var probeStatuses: [String: String] = [:]
    private var appCancellables: Set<AnyCancellable> = []
    private let notificationService: NotificationPresenting
    private let isActiveOverride: Bool?
    /// Sentinel draft key for the new-chat route; every session route keys off its own
    /// standardized file path instead.
    private static let newChatDraftKey = "new-chat"
    private var draftStore: DraftStore
    /// Per-conversation attachments, restored while the app keeps running but never persisted:
    /// image bytes must never reach `state.json`.
    private var attachmentsByKey: [String: [ImageAttachment]] = [:]
    private var draftPersistTask: Task<Void, Never>?
    private var notificationCoalescer = NotificationCoalescer()
    /// Distinguishes the first baseline for a tracked path from a completion observed later.
    /// Persisted latest IDs provide cross-launch deduplication; this set prevents stale launch
    /// notifications while remaining bounded to discovered sessions.
    private var observedActivityPaths: Set<String> = []
    /// Terminal RPC answers remain as a bounded overlay until the same answer is visible in the
    /// authoritative JSONL page. This closes the short message_end → disk durability gap.
    private var pendingFinalMessagesByPath: [String: ChatMessage] = [:]
    private var pendingFinalOrder: [String] = []
    private var liveMessagesByPath: [String: [ChatMessage]] = [:]
    private var liveMessageOrder: [LiveMessageKey] = []
    private var finalDurabilityTasks: [UUID: Task<Void, Never>] = [:]
    private static let pendingFinalLimit = 32
    private static let liveMessageLimit = 256
    /// Set for the in-flight "prompt" of the currently attached turn; see `PendingUserTurn`.
    private var activeTurnPrompt: PendingUserTurn? {
        get { activeRuntimeSlot.pendingTurn }
        set { activeRuntimeSlot.pendingTurn = newValue }
    }
    /// Bounded in-memory transcript cache (Task 3): never persisted, purely a warm-start cache
    /// for the current app run.
    private let transcriptCache = TranscriptCache()
    private var prefetchTask: Task<Void, Never>?
    private static let prefetchLaunchCount = 8
    private static let prefetchNeighborRadius = 1
    private static let prefetchConcurrency = 3
    /// Explicit ceiling for a user-expanded transcript window. The newest page is 50 messages;
    /// older pages remain on demand without allowing a long browsing session to retain forever.
    private static let loadedMessageLimit = 1_000

    init(
        repository: SessionRepositoryProtocol = FileSessionRepository(),
        gitService: GitStatusProviding = GitService(),
        runtime: PiRuntimeProtocol = PiRPCClient(),
        runtimeFactory: @escaping () -> PiRuntimeProtocol = { PiRPCClient() },
        persistence: AppPersistence? = nil,
        activityPresenter: ActivityPresenting = ActivityPresenter(),
        activityMonitor: SessionActivityMonitor? = nil,
        probeRuntimeFactory: (() -> PiRuntimeProtocol)? = nil,
        notificationService: NotificationPresenting? = nil,
        isActiveOverride: Bool? = nil,
        runtimeRetirementDelay: TimeInterval = 120,
        runtimeRetirementScheduler: @escaping RuntimeRetirementScheduler = { delay, action in
            let task = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                action()
            }
            return { task.cancel() }
        }
    ) {
        self.repository = repository
        self.gitService = gitService
        self.runtimeFactory = runtimeFactory
        self.runtimeRetirementDelay = runtimeRetirementDelay
        self.runtimeRetirementScheduler = runtimeRetirementScheduler
        activeRuntimeSlot = RuntimeSlot(runtime: runtime)
        self.persistence = persistence ?? AppPersistence()
        self.activityPresenter = activityPresenter
        self.activityMonitor = activityMonitor ?? SessionActivityMonitor()
        self.probeRuntimeFactory = probeRuntimeFactory
        self.notificationService = notificationService ?? NotificationService()
        self.isActiveOverride = isActiveOverride
        // Never default to a TCC-protected folder (Desktop/Documents/…): a folder the user has
        // not chosen yet must not be why a fresh launch prompts for permission. `nowhereFolderURL`
        // (~/Desktop) is kept only as an explicit, user-requested value elsewhere — never used
        // automatically. See `defaultWorkingFolder` and `hasOptedIntoGitRefresh`.
        selectedFolder = Self.defaultWorkingFolder(recentFolders: self.persistence.state.recentFolders)
        cachedStatuses = self.persistence.state.cachedExtensionStatuses
        draftStore = DraftStore(texts: self.persistence.state.drafts)
        draft = draftStore.text(for: Self.newChatDraftKey)

        bindRuntime(activeRuntimeSlot)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                refreshSelectedGit()
                if let selectedSession { markRead(selectedSession) }
            }
            .store(in: &appCancellables)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.flushDraftPersistence() }
            .store(in: &appCancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.flushDraftPersistence() }
            .store(in: &appCancellables)
        self.activityMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &appCancellables)
        self.activityMonitor.$activities
            .sink { [weak self] activities in self?.handleActivitySnapshot(activities) }
            .store(in: &appCancellables)
        self.notificationService.onSelectSession = { [weak self] path in self?.focusSession(atPath: path) }
        $draft
            .dropFirst()
            .sink { [weak self] text in
                guard let self else { return }
                persistDraftText(text, for: currentDraftKey)
            }
            .store(in: &appCancellables)
    }

    private func bindRuntime(_ slot: RuntimeSlot) {
        slot.runtime.onEvent = { [weak self, weak slot] value in
            guard let slot else { return }
            self?.handleRPCEvent(value, from: slot)
        }
        slot.runtime.onExit = { [weak self, weak slot] error in
            guard let slot else { return }
            self?.handleRuntimeExit(error, from: slot)
        }
    }

    private func runtimeKey(cwd: URL, sessionPath: URL?) -> RuntimeRouteKey {
        if let sessionPath { return .session(sessionPath.standardizedFileURL.path) }
        return .newChat(cwd.standardizedFileURL.path)
    }

    private func runtimeKey(for slot: RuntimeSlot) -> RuntimeRouteKey? {
        if slot.startedForNewChat, let cwd = slot.cwd { return .newChat(cwd) }
        if let path = slot.sessionPath { return .session(path) }
        return nil
    }

    private func removeParkedReference(to slot: RuntimeSlot) {
        parkedRuntimes = parkedRuntimes.filter { $0.value !== slot }
    }

    private func state(for slot: RuntimeSlot) -> RuntimeState {
        slot === activeRuntimeSlot ? runtimeState : slot.state
    }

    private func updateState(for slot: RuntimeSlot, _ update: (inout RuntimeState) -> Void) {
        if slot === activeRuntimeSlot {
            update(&runtimeState)
            slot.state = runtimeState
        } else {
            update(&slot.state)
        }
    }

    func beginOutboxDispatch() -> (owner: UUID, dispatch: UUID) {
        beginOutboxDispatch(for: activeRuntimeSlot)
    }

    private func beginOutboxDispatch(for slot: RuntimeSlot) -> (owner: UUID, dispatch: UUID) {
        let dispatch = UUID()
        slot.outboxDispatches.insert(dispatch)
        return (slot.id, dispatch)
    }

    func finishOutboxDispatch(
        owner: UUID,
        dispatch: UUID,
        delivery: OutboxEntry.Delivery,
        result: Result<JSONValue, Error>
    ) {
        guard let slot = runtimeSlot(id: owner) else { return }
        let error: String?
        switch result {
        case let .success(response): error = responseError(response)
        case let .failure(value): error = value.localizedDescription
        }
        if delivery == .steer || error != nil { slot.outboxDispatches.remove(dispatch) }
        guard let error else { return }
        updateState(for: slot) { $0.lastError = "Queued message could not be delivered: \(error)" }
        if slot === activeRuntimeSlot { resetRuntimeRetirementLease(for: slot) }
        else if isIdleAndClean(slot) { retireBackgroundRuntime(slot) }
    }

    private func runtimeSlot(id: UUID) -> RuntimeSlot? {
        if activeRuntimeSlot.id == id { return activeRuntimeSlot }
        return parkedRuntimes.values.first { $0.id == id }
    }

    private func saveActiveRuntimePresentation() {
        guard !activePresentationDetached else { return }
        let slot = activeRuntimeSlot
        slot.state = runtimeState
        slot.metrics = liveMetrics
        slot.models = availableModels
        slot.thinkingLevels = availableThinkingLevels
        slot.optionsLoading = composerOptionsLoading
        slot.capability = activeCapability
        slot.questionnaire = pendingQuestionnaire
        slot.statuses = extensionStatuses
        slot.widgets = extensionWidgets
        slot.windowTitle = windowTitle
        slot.dialogs = dialogQueue
        slot.outbox = outbox
        slot.streamingMessage = streamingMessage
        dialogTimeoutTask?.cancel()
        dialogTimeoutTask = nil
    }

    private func restoreRuntimePresentation(_ slot: RuntimeSlot) {
        activePresentationDetached = false
        runtimeState = slot.state
        liveMetrics = slot.metrics
        availableModels = slot.models
        availableThinkingLevels = slot.thinkingLevels
        composerOptionsLoading = slot.optionsLoading
        activeCapability = slot.capability
        pendingQuestionnaire = slot.questionnaire
        extensionStatuses = slot.statuses
        extensionWidgets = slot.widgets
        windowTitle = slot.windowTitle
        dialogQueue = slot.dialogs
        activeDialog = dialogQueue.first
        outbox = slot.outbox
        streamingMessage = slot.streamingMessage
        if let activeDialog { startDialogTimeout(for: activeDialog) }

        let deferred = slot.deferredEvents
        slot.deferredEvents.removeAll(keepingCapacity: true)
        for event in deferred { handleRPCEvent(event) }
    }

    private func detachActiveRuntimePresentation() {
        guard activeRuntimeSlot.runtime.isRunning, !activePresentationDetached else { return }
        saveActiveRuntimePresentation()
        activePresentationDetached = true
        clearExtensionDialogs()
        liveMetrics = TokenMetrics()
        availableModels.removeAll()
        availableThinkingLevels = ["off"]
        composerOptionsLoading = false
        activeCapability = nil
        extensionStatuses.removeAll()
        extensionWidgets.removeAll()
        windowTitle = "Pi Desktop"
        outbox.removeAll()
        streamingMessage = nil
    }

    private func shouldPark(_ slot: RuntimeSlot) -> Bool {
        slot.runtime.isRunning && !isIdleAndClean(slot)
    }

    private func isIdleAndClean(_ slot: RuntimeSlot) -> Bool {
        let presentation = state(for: slot)
        let dialogs = slot === activeRuntimeSlot && !activePresentationDetached ? dialogQueue : slot.dialogs
        let queued = slot === activeRuntimeSlot && !activePresentationDetached ? outbox : slot.outbox
        let capability = slot === activeRuntimeSlot && !activePresentationDetached ? activeCapability : slot.capability
        let questionnaire = slot === activeRuntimeSlot && !activePresentationDetached ? pendingQuestionnaire : slot.questionnaire
        let stream = slot === activeRuntimeSlot && !activePresentationDetached ? streamingMessage : slot.streamingMessage
        return !slot.isStarting && !slot.optionsLoading && presentation.phase == .idle && !presentation.isBusy
            && slot.pendingTurn == nil && dialogs.isEmpty && queued.isEmpty
            && slot.outboxDispatches.isEmpty && slot.deferredEvents.isEmpty
            && capability == nil && questionnaire == nil && stream == nil
    }

    private func cancelRuntimeRetirementLease() {
        cancelRuntimeRetirement?()
        cancelRuntimeRetirement = nil
    }

    private func resetRuntimeRetirementLease(for slot: RuntimeSlot) {
        cancelRuntimeRetirementLease()
        guard slot === activeRuntimeSlot, slot.runtime.isRunning, slot.isReady, isIdleAndClean(slot) else { return }
        cancelRuntimeRetirement = runtimeRetirementScheduler(runtimeRetirementDelay) { [weak self, weak slot] in
            guard let self, let slot, slot === self.activeRuntimeSlot,
                  slot.runtime.isRunning, slot.isReady, self.isIdleAndClean(slot) else { return }
            self.cancelRuntimeRetirement = nil
            slot.isReady = false
            slot.runtime.stop()
            self.updateState(for: slot) { state in
                state.isConnected = false
                state.phase = .idle
            }
        }
    }

    private func activateRuntime(_ slot: RuntimeSlot) {
        guard slot !== activeRuntimeSlot else {
            restoreRuntimePresentation(slot)
            return
        }

        let previous = activeRuntimeSlot
        saveActiveRuntimePresentation()
        if shouldPark(previous), let key = runtimeKey(for: previous) {
            parkedRuntimes[key] = previous
        } else {
            previous.runtime.stop()
            removeParkedReference(to: previous)
        }

        removeParkedReference(to: slot)
        activeRuntimeSlot = slot
        restoreRuntimePresentation(slot)
    }

    /// Statuses persisted from the last live runtime or probe, shown dimmed when nothing is
    /// attached.
    private var cachedStatuses: [String: String] = [:]

    var selectedSession: SessionSummary? {
        guard case let .session(path) = route else { return nil }
        return sessions.first { $0.fileURL.standardizedFileURL.path == path }
    }

    var recentFolders: [URL] {
        let persisted = persistence.state.recentFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let fromSessions = sessions.map(\.cwd)
        var seen: Set<String> = []
        return (persisted + fromSessions).filter { seen.insert($0.standardizedFileURL.path).inserted }.prefix(8).map { $0 }
    }

    /// `NSApplication.shared` rather than the `NSApp` global so headless test hosts stay safe.
    /// `isActiveOverride` keeps notification frontmost/background rules deterministic in tests.
    private var isApplicationActive: Bool { isActiveOverride ?? NSApplication.shared.isActive }

    var isSelectedRuntime: Bool {
        guard !activePresentationDetached, let selectedSession else { return false }
        return selectedSession.fileURL.standardizedFileURL.path == activeRuntimePath
    }

    /// True for either an attached saved conversation or the query-only runtime prepared for a
    /// new Desktop chat. Picker controls use this broader route scope; transcript/session actions
    /// deliberately keep using `isSelectedRuntime`.
    var isCurrentRouteRuntime: Bool { runtimeMatchesCurrentRoute }

    var currentRouteRuntimePhase: RuntimePhase? {
        guard !activePresentationDetached, runtimeKey(for: activeRuntimeSlot) == currentRouteKey else { return nil }
        return runtimeState.phase
    }

    private var currentRouteKey: RuntimeRouteKey? {
        if let selectedSession { return .session(selectedSession.fileURL.standardizedFileURL.path) }
        guard let selectedFolder else { return nil }
        return .newChat(selectedFolder.standardizedFileURL.path)
    }

    var selectedMetrics: TokenMetrics {
        isSelectedRuntime && runtimeState.isConnected ? liveMetrics : (selectedSession?.metrics ?? TokenMetrics())
    }

    private var runningRuntimePaths: Set<String> {
        var paths: Set<String> = []
        if runtimeState.isBusy, let activeRuntimePath { paths.insert(activeRuntimePath) }
        for slot in parkedRuntimes.values where slot.state.isBusy {
            if let path = slot.sessionPath { paths.insert(path) }
        }
        return paths
    }

    // MARK: - Cross-terminal activity

    /// True when this session is working, whether it was started by this app or by any terminal.
    /// The app's own runtime state wins, then the file-based monitor.
    func isRunning(_ session: SessionSummary) -> Bool {
        let path = session.fileURL.standardizedFileURL.path
        if runningRuntimePaths.contains(path) { return true }
        return activityMonitor.activity(forPath: path)?.state == .running
    }

    /// The freshest modification time available: the monitor's live stat, else the summary.
    func liveModifiedAt(_ session: SessionSummary) -> Date {
        let observed = activityMonitor.activity(forPath: session.fileURL.standardizedFileURL.path)?.modifiedAt
        return max(observed ?? .distantPast, session.modifiedAt)
    }

    func runningSince(_ session: SessionSummary) -> Date? {
        activityMonitor.activity(forPath: session.fileURL.standardizedFileURL.path)?.runningSince
    }

    /// Menu bar / badge source: every non-archived session currently working, most recent first.
    var runningSessions: [SessionSummary] {
        sessions
            .filter { !$0.isArchived && isRunning($0) }
            .sorted { liveModifiedAt($0) > liveModifiedAt($1) }
    }

    /// Completion IDs, not run-state or mtime transitions, are the sole finished-answer signal.
    /// The first snapshot establishes a quiet baseline; every later distinct ID is persisted
    /// before notification gating so duplicate observations and relaunches stay silent.
    private func handleActivitySnapshot(_ activities: [String: SessionActivity]) {
        for (path, activity) in activities {
            let hadBaseline = observedActivityPaths.contains(path)
            observedActivityPaths.insert(path)
            guard let completionID = activity.latestCompletedEntryID else { continue }

            let previousID = persistence.state.latestCompletedEntryIDBySessionPath[path]
            let focused = isApplicationActive
                && selectedSession?.fileURL.standardizedFileURL.path == path
            let alreadySeen = persistence.state.lastSeenCompletedEntryIDBySessionPath[path] == completionID
            if previousID != completionID || (focused && !alreadySeen) || persistence.state.lastReadAt[path] != nil {
                persistence.observeCompletedEntry(
                    path: path,
                    completionID: completionID,
                    modifiedAt: activity.modifiedAt,
                    markSeen: focused
                )
            }

            guard hadBaseline, previousID != completionID,
                  let session = sessions.first(where: { $0.fileURL.standardizedFileURL.path == path }) else { continue }
            let failed = activity.lastStopReason == "error" || activity.lastStopReason == "aborted"
            notify(
                failed ? .turnFailed : .turnFinished,
                session: session,
                preview: activity.preview,
                completionID: completionID
            )
        }
    }

    /// The session behind whichever runtime is currently attached, if any — the only session the
    /// RPC event stream (as opposed to the file-based monitor) can ever be reporting about.
    private func activeSession() -> SessionSummary? {
        guard let activeRuntimePath else { return nil }
        return sessions.first { $0.fileURL.standardizedFileURL.path == activeRuntimePath }
    }

    /// Single entry point for every notification trigger: applies the "don't tell me about what
    /// I'm already looking at" rule, coalesces bursts, then routes to a toast (frontmost) or a
    /// desktop notification (backgrounded).
    private func notify(
        _ trigger: NotificationTrigger,
        session: SessionSummary?,
        preview: String? = nil,
        completionID: String? = nil
    ) {
        guard let session else { return }
        let key = session.fileURL.standardizedFileURL.path
        let focusedKey = isApplicationActive ? selectedSession?.fileURL.standardizedFileURL.path : nil
        guard !NotificationGate.isSuppressed(sessionKey: key, focusedSessionKey: focusedKey) else { return }
        // Distinct completion IDs bypass the per-session quiet window while still sharing the
        // global burst cap. Every non-completion trigger keeps the ordinary per-session key.
        let coalescingKey = completionID.map { "\(key)#\($0)" } ?? key
        guard notificationCoalescer.shouldEmit(sessionKey: coalescingKey) else { return }
        // A finished turn's body shows the beginning of Pi's actual answer when one is available
        // (a live RPC message, or a cross-terminal heartbeat preview); every other trigger keeps
        // its fixed, specific summary.
        let body = (trigger == .turnFinished ? NotificationPreviewFormatter.format(preview) : nil) ?? trigger.summary
        if isApplicationActive {
            showToast(body, style: trigger.toastStyle, sessionPath: key)
        } else {
            notificationService.presentDesktopNotification(sessionKey: key, title: session.displayName, body: body)
        }
    }

    /// A clicked desktop notification's destination: bring the conversation on screen exactly
    /// like picking it from the sidebar would.
    private func focusSession(atPath path: String) {
        guard let session = sessions.first(where: { $0.fileURL.standardizedFileURL.path == path }) else { return }
        selectSession(session)
    }

    func openToast(_ toast: ToastMessage) {
        guard let path = toast.sessionPath else { return }
        toastTask?.cancel()
        withAnimation(.easeIn(duration: 0.2)) { self.toast = nil }
        focusSession(atPath: path)
    }

    // MARK: - Extension statuses

    var statusModel: ExtensionStatusModel {
        // Live values win per key, but a key the current runtime has not reported yet keeps its
        // last known value instead of vanishing, so no chip ever flips to a placeholder while a
        // session is attached.
        if !extensionStatuses.isEmpty {
            return ExtensionStatusModel(
                values: cachedStatuses.merging(extensionStatuses) { _, live in live },
                isLive: true
            )
        }
        if !probeStatuses.isEmpty {
            return ExtensionStatusModel(
                values: cachedStatuses.merging(probeStatuses) { _, probe in probe },
                isLive: isProbingStatuses
            )
        }
        return ExtensionStatusModel(values: cachedStatuses, isLive: false)
    }

    // MARK: - Sidebar folder expansion

    /// Default expanded for folders that were touched recently or are running; explicit user
    /// choices always win and are persisted.
    func isFolderExpanded(path: String, defaultExpanded: Bool) -> Bool {
        if persistence.state.expandedFolders.contains(path) { return true }
        if persistence.state.collapsedFolders.contains(path) { return false }
        return defaultExpanded
    }

    func setFolderExpanded(_ expanded: Bool, path: String) {
        persistence.setFolderExpanded(expanded, path: path)
        objectWillChange.send()
    }

    /// A safe folder to preselect before the user has chosen one: the most recently used folder
    /// (already opted into — the user picked it from the picker) if there is one, else the plain
    /// home directory, which macOS never gates behind a permission prompt the way Desktop,
    /// Documents, and Downloads are.
    private static func defaultWorkingFolder(recentFolders: [String]) -> URL {
        if let mostRecent = recentFolders.first { return URL(fileURLWithPath: mostRecent, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        Task {
            // First paint comes straight from the persisted summary cache, then the disk scan
            // reconciles in the background.
            let cached = await repository.cachedSessions(archivedIDs: persistence.state.archivedSessionIDs)
            if sessions.isEmpty, !cached.isEmpty {
                sessions = cached
                syncActivityMonitorPaths()
            }
            await refreshSessions()
            if selectedFolder == nil {
                selectedFolder = Self.defaultWorkingFolder(recentFolders: persistence.state.recentFolders)
            }
            // Warm the transcript cache after the scan settles, so opening a recent conversation
            // is instant even before the user selects anything.
            schedulePrefetch(around: selectedSession)
        }
        startGitRefreshLoop()
        activityMonitor.start()
        installActivityExtensionIfNeeded()
        LimitsReportStore.shared.refreshAction = { [weak self] in self?.refreshLimits() }
    }

    func refreshSessions() async {
        guard !isScanning else { return }
        isScanning = true
        scanError = nil
        do {
            let selectedPath = selectedSession?.fileURL.standardizedFileURL.path
            let discovered = try await repository.discoverSessions(archivedIDs: persistence.state.archivedSessionIDs)
            sessions = discovered
            persistence.pruneCompletionState(retainingSessionPaths: discovered.map { $0.fileURL.path })
            syncActivityMonitorPaths()
            if let selectedPath, sessions.contains(where: { $0.fileURL.standardizedFileURL.path == selectedPath }) {
                route = .session(selectedPath)
            }
            if isApplicationActive { await refreshFolderGitSnapshots() }
        } catch is CancellationError {
            // A newer route/refresh owns the UI.
        } catch {
            scanError = error.localizedDescription
        }
        isScanning = false
    }

    func openNewChat() {
        if let selectedSession { markRead(selectedSession) }
        parkCurrentDraft()
        flushDraftPersistence()
        cancelConversationLoad()
        resetConversationPageState()
        let newFolder = Self.defaultWorkingFolder(recentFolders: persistence.state.recentFolders)
        if runtimeKey(for: activeRuntimeSlot) != .newChat(newFolder.standardizedFileURL.path) {
            detachActiveRuntimePresentation()
        }
        route = .newChat
        // Automations is a detail page, not a route: standard navigation always leaves it.
        schedulesPresented = false
        conversationError = nil
        messages.removeAll(keepingCapacity: false)
        streamingMessage = nil
        activities.removeAll(keepingCapacity: false)
        activeCapability = nil
        pendingQuestionnaire = nil
        draft = draftStore.text(for: Self.newChatDraftKey)
        attachments = attachmentsByKey[Self.newChatDraftKey] ?? []
        // Release the previous conversation's decoded bitmaps promptly.
        DecodedImageCache.purge()
        selectedFolder = newFolder
        refreshSelectedGit()
    }

    func selectSession(_ session: SessionSummary) {
        let path = session.fileURL.standardizedFileURL.path
        if let current = selectedSession, current.fileURL.standardizedFileURL.path != path { markRead(current) }
        parkCurrentDraft()
        cancelConversationLoad()
        prefetchTask?.cancel()
        prefetchTask = nil
        resetConversationPageState()

        let latestCompletion = activityMonitor.activity(forPath: path)?.latestCompletedEntryID
            ?? persistence.state.latestCompletedEntryIDBySessionPath[path]
        let lastSeenCompletion = persistence.state.lastSeenCompletedEntryIDBySessionPath[path]
        if let latestCompletion, latestCompletion != lastSeenCompletion {
            initialPreviousSeenCompletionID = lastSeenCompletion
            initialScrollTargetMessageID = latestCompletion
        }

        let targetKey = RuntimeRouteKey.session(path)
        if runtimeKey(for: activeRuntimeSlot) != targetKey { detachActiveRuntimePresentation() }
        conversationLoadGeneration += 1
        let generation = conversationLoadGeneration
        route = .session(path)
        schedulesPresented = false
        markRead(session)
        conversationError = nil
        streamingMessage = nil
        activeCapability = nil
        pendingQuestionnaire = nil
        draft = draftStore.text(for: path)
        attachments = attachmentsByKey[path] ?? []
        flushDraftPersistence()
        DecodedImageCache.purge()
        let cwdPath = session.cwd.standardizedFileURL.path
        selectedGit = folderGit[cwdPath] ?? .none
        selectedWorktree = folderWorktrees[cwdPath]

        // A page-cache hit publishes synchronously in the selection tick. Activity projection is
        // inspector data and stays off the main actor so it cannot delay the transcript frame.
        if let (cached, fingerprint) = cachedPage(for: session.fileURL) {
            publishConversationPage(cached, path: path, fingerprint: fingerprint)
            isConversationLoading = false
            conversationLoadTask = Task { [weak self] in
                guard let self else { return }
                let projected = await projectActivities(from: cached.messages)
                guard conversationLoadGeneration == generation,
                      selectedSession?.fileURL.standardizedFileURL.path == path else { return }
                activities = projected
                await refreshGit(for: session.cwd)
                guard conversationLoadGeneration == generation else { return }
                schedulePrefetch(around: session)
            }
            return
        }

        isConversationLoading = true
        var live = liveMessagesByPath[path] ?? []
        if let pending = pendingFinalMessagesByPath[path], !live.contains(where: { $0.id == pending.id }) {
            live.append(pending)
        }
        messages = enforcingLoadedImageBudget(live)
        activities.removeAll(keepingCapacity: false)
        conversationLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await loadNewestConversationPage(session, generation: generation)
            } catch is CancellationError {
                // A newer route owns the UI.
            } catch {
                guard conversationLoadGeneration == generation,
                      selectedSession?.fileURL.standardizedFileURL.path == path else { return }
                conversationError = error.localizedDescription
                isConversationLoading = false
            }
        }
    }

    private func loadNewestConversationPage(_ session: SessionSummary, generation: Int) async throws {
        let path = session.fileURL.standardizedFileURL.path
        let fingerprint = fileFingerprint(for: session.fileURL)
        let startedAt = Date()
        let page = try await repository.loadNewestConversationPage(from: session.fileURL)
        ConversationPerformance.mark(
            "JSONL newest page", path: path, count: page.messages.count,
            milliseconds: Date().timeIntervalSince(startedAt) * 1_000
        )
        try Task.checkCancellation()
        guard conversationLoadGeneration == generation,
              selectedSession?.fileURL.standardizedFileURL.path == path else { return }

        publishConversationPage(page, path: path, fingerprint: fingerprint)
        cachePage(page, for: session.fileURL, fingerprint: fingerprint)
        isConversationLoading = false
        ConversationPerformance.mark("Conversation first publish", path: path, count: page.messages.count)

        let projectionStartedAt = Date()
        let projected = await projectActivities(from: page.messages)
        guard conversationLoadGeneration == generation,
              selectedSession?.fileURL.standardizedFileURL.path == path else { return }
        activities = projected
        ConversationPerformance.mark(
            "Transcript activity projection", path: path, count: projected.count,
            milliseconds: Date().timeIntervalSince(projectionStartedAt) * 1_000
        )
        await refreshGit(for: session.cwd)
        guard conversationLoadGeneration == generation else { return }
        schedulePrefetch(around: session)
    }

    func loadEarlierMessages() {
        guard !isConversationLoading, !isLoadingEarlierMessages,
              !conversationHistoryLimitReached,
              let session = selectedSession,
              let current = loadedConversationPage,
              let cursor = current.olderCursor else { return }
        let path = session.fileURL.standardizedFileURL.path
        guard loadedConversationPath == path else { return }
        let generation = conversationLoadGeneration
        isLoadingEarlierMessages = true
        earlierMessagesTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            do {
                let older = try await repository.loadOlderConversationPage(from: session.fileURL, cursor: cursor)
                try Task.checkCancellation()
                guard conversationLoadGeneration == generation,
                      selectedSession?.fileURL.standardizedFileURL.path == path else { return }
                let prepended = mergeEarlierPage(older)
                isLoadingEarlierMessages = false
                if let merged = loadedConversationPage {
                    cachePage(merged, for: session.fileURL, fingerprint: loadedConversationFingerprint)
                }
                ConversationPerformance.mark(
                    "Conversation page prepend", path: path, count: prepended,
                    milliseconds: Date().timeIntervalSince(startedAt) * 1_000
                )
                let projected = await projectActivities(from: messages)
                guard conversationLoadGeneration == generation,
                      selectedSession?.fileURL.standardizedFileURL.path == path else { return }
                activities = projected
            } catch is CancellationError {
                // Route changed.
            } catch {
                guard conversationLoadGeneration == generation,
                      selectedSession?.fileURL.standardizedFileURL.path == path else { return }
                isLoadingEarlierMessages = false
                showToast("Couldn’t load earlier history: \(error.localizedDescription)", style: .warning)
            }
        }
    }

    func consumeInitialScrollTarget() {
        initialScrollTargetMessageID = nil
        initialPreviousSeenCompletionID = nil
    }

    @discardableResult
    private func mergeEarlierPage(_ older: ConversationPage) -> Int {
        guard let current = loadedConversationPage else { return 0 }
        let existingIDs = Set(current.messages.map(\.id))
        let unique = older.messages.filter { !existingIDs.contains($0.id) }
        let remaining = max(0, Self.loadedMessageLimit - current.messages.count)
        let accepted = Array(unique.suffix(remaining))
        let mergedMessages = enforcingLoadedImageBudget(accepted + current.messages)
        loadedConversationPage = ConversationPage(
            messages: mergedMessages,
            olderCursor: older.olderCursor,
            leafID: current.leafID ?? older.leafID,
            rawEntryCount: current.rawEntryCount + older.rawEntryCount,
            scannedEntryCount: current.scannedEntryCount + older.scannedEntryCount,
            scannedByteCount: current.scannedByteCount + older.scannedByteCount,
            isTruncated: older.isTruncated
        )
        replaceLoadedMessages(with: mergedMessages)
        conversationHistoryLimitReached = (older.olderCursor != nil && mergedMessages.count >= Self.loadedMessageLimit)
            || (older.isTruncated && older.olderCursor == nil)
        hasEarlierMessages = older.olderCursor != nil && !conversationHistoryLimitReached
        return accepted.count
    }

    private func publishConversationPage(
        _ page: ConversationPage,
        path: String,
        fingerprint: SessionFileFingerprint?
    ) {
        loadedConversationPage = page
        loadedConversationPath = path
        loadedConversationFingerprint = fingerprint
        if initialScrollTargetMessageID != nil {
            let completions = page.messages.filter {
                $0.role == .assistant
                    && SessionParser.terminalAssistantStopReasons.contains($0.stopReason ?? "")
            }
            if let seen = initialPreviousSeenCompletionID,
               let seenIndex = completions.firstIndex(where: { $0.id == seen }),
               completions.indices.contains(seenIndex + 1) {
                initialScrollTargetMessageID = completions[seenIndex + 1].id
            } else if let first = completions.first {
                initialScrollTargetMessageID = first.id
            }
        }
        replaceLoadedMessages(with: page.messages)
        conversationHistoryLimitReached = (page.olderCursor != nil && page.messages.count >= Self.loadedMessageLimit)
            || (page.isTruncated && page.olderCursor == nil)
        hasEarlierMessages = page.olderCursor != nil && !conversationHistoryLimitReached
    }

    private func resetConversationPageState() {
        loadedConversationPage = nil
        loadedConversationPath = nil
        loadedConversationFingerprint = nil
        hasEarlierMessages = false
        isLoadingEarlierMessages = false
        conversationHistoryLimitReached = false
        initialScrollTargetMessageID = nil
        initialPreviousSeenCompletionID = nil
    }

    private func fileFingerprint(for fileURL: URL) -> SessionFileFingerprint? {
        // A URL can retain resource values across an append. Recreate it so cache validation
        // always stats the file rather than trusting metadata from the selection summary.
        let fresh = URL(fileURLWithPath: fileURL.path)
        guard let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return SessionFileFingerprint(url: fresh, values: values)
    }

    /// Synchronous, zero-suspension cache probe — see `TranscriptCache`.
    private func cachedPage(for fileURL: URL) -> (ConversationPage, SessionFileFingerprint)? {
        guard let fingerprint = fileFingerprint(for: fileURL),
              let page = transcriptCache.page(for: fileURL.standardizedFileURL.path, fingerprint: fingerprint) else { return nil }
        return (page, fingerprint)
    }

    private func cachePage(
        _ page: ConversationPage,
        for fileURL: URL,
        fingerprint: SessionFileFingerprint?
    ) {
        guard let fingerprint, fileFingerprint(for: fileURL) == fingerprint else { return }
        transcriptCache.store(page, for: fileURL.standardizedFileURL.path, fingerprint: fingerprint)
    }

    private func projectActivities(from messages: [ChatMessage]) async -> [ActivityItem] {
        let presenter = activityPresenter
        return await Task.detached(priority: .userInitiated) {
            presenter.activities(from: messages)
        }.value
    }

    // MARK: - Prefetch

    /// Warms the transcript cache in the background so opening a recent conversation — or one
    /// next to the selected one in the sidebar's recency order — never waits on a parse. Strictly
    /// additive: this can only ever populate `transcriptCache`, never publish into `messages`, so
    /// a stale or cancelled prefetch can never corrupt what is on screen. Low priority and fully
    /// cancellable; superseded on every call.
    private func schedulePrefetch(around session: SessionSummary?) {
        prefetchTask?.cancel()
        let candidates = prefetchCandidates(around: session)
        guard !candidates.isEmpty else { return }
        prefetchTask = Task(priority: .utility) { [weak self] in
            await self?.runPrefetch(candidates)
        }
    }

    private func prefetchCandidates(around session: SessionSummary?) -> [URL] {
        var ordered = Array(sessions.filter { !$0.isArchived }.prefix(Self.prefetchLaunchCount).map(\.fileURL))
        if let session,
           let index = sessions.firstIndex(where: {
               $0.fileURL.standardizedFileURL.path == session.fileURL.standardizedFileURL.path
           }) {
            for offset in -Self.prefetchNeighborRadius...Self.prefetchNeighborRadius where offset != 0 {
                let neighborIndex = index + offset
                guard sessions.indices.contains(neighborIndex) else { continue }
                ordered.append(sessions[neighborIndex].fileURL)
            }
        }
        let selectedPath = session?.fileURL.standardizedFileURL.path
        var seen: Set<String> = []
        return ordered.filter {
            let path = $0.standardizedFileURL.path
            return path != selectedPath && seen.insert(path).inserted
        }
    }

    private func runPrefetch(_ urls: [URL]) async {
        let repository = repository
        let cache = transcriptCache
        await withTaskGroup(of: Void.self) { group in
            var iterator = urls.makeIterator()
            for _ in 0..<min(Self.prefetchConcurrency, urls.count) {
                guard let url = iterator.next() else { break }
                group.addTask { await Self.prefetchOne(url, repository: repository, cache: cache) }
            }
            while await group.next() != nil {
                guard let next = iterator.next() else { continue }
                group.addTask { await Self.prefetchOne(next, repository: repository, cache: cache) }
            }
        }
    }

    private static func prefetchOne(_ url: URL, repository: SessionRepositoryProtocol, cache: TranscriptCache) async {
        guard !Task.isCancelled else { return }
        let fresh = URL(fileURLWithPath: url.path)
        let path = fresh.standardizedFileURL.path
        guard let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let fingerprint = SessionFileFingerprint(url: fresh, values: values)
        if cache.page(for: path, fingerprint: fingerprint) != nil { return }
        guard let page = try? await repository.loadNewestConversationPage(from: url), !Task.isCancelled,
              let currentValues = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              SessionFileFingerprint(url: URL(fileURLWithPath: url.path), values: currentValues) == fingerprint else { return }
        cache.store(page, for: path, fingerprint: fingerprint)
    }

    // MARK: - Activity heartbeat extension

    /// Installs/repairs the heartbeat extension off the main actor (Task 1: blocking file I/O),
    /// then surfaces a quiet one-time toast only when this launch actually wrote something —
    /// never on an ordinary launch once it is already current, disabled, or unavailable.
    private func installActivityExtensionIfNeeded() {
        guard !ActivityExtensionSettings.isDisabled() else { return }
        Task.detached(priority: .utility) {
            let outcome = ActivityExtensionInstaller.run(isDisabled: false)
            await MainActor.run { [weak self] in self?.handleActivityExtensionOutcome(outcome) }
        }
    }

    private func handleActivityExtensionOutcome(_ outcome: ActivityExtensionInstaller.Outcome) {
        switch outcome {
        case .installed: showToast("Installed the Pi activity helper extension", style: .info)
        case .upgraded: showToast("Updated the Pi activity helper extension", style: .info)
        case .upToDate, .disabled, .skippedUserModified, .sourceUnavailable, .writeFailed:
            break // Nothing changed on disk; stay quiet.
        }
    }

    func retryConversationLoad() {
        guard let selectedSession else { return }
        // Reselecting the same session parks and immediately restores the identical draft, so
        // the composer is left untouched.
        selectSession(selectedSession)
    }

    func chooseFolder(_ url: URL) {
        let folder = url.standardizedFileURL
        if case .newChat = route, runtimeKey(for: activeRuntimeSlot) != .newChat(folder.path) {
            detachActiveRuntimePresentation()
        }
        selectedFolder = folder
        persistence.rememberFolder(url)
        refreshSelectedGit()
    }

    func toggleArchive(_ session: SessionSummary) {
        let archived = !session.isArchived
        persistence.setArchived(archived, sessionID: session.id)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index].isArchived = archived }
        showToast(archived ? "Conversation archived" : "Conversation restored", style: .info)
    }

    /// ⌘⇧A. Enabled only when a conversation is selected.
    func toggleArchiveSelected() {
        guard let session = selectedSession else {
            showToast("Select a conversation to archive.", style: .warning)
            return
        }
        toggleArchive(session)
    }

    /// Cwd is no longer needed here: run state comes from activity heartbeats (matched by
    /// session path) or the file heuristic, never from cross-checking a live process's working
    /// directory — several sessions can share one, which is exactly what made that cross-check
    /// unreliable.
    private func syncActivityMonitorPaths() {
        let paths = sessions.map { $0.fileURL.standardizedFileURL.path }
        observedActivityPaths.formIntersection(Set(paths))
        activityMonitor.setTrackedPaths(paths)
    }

    // MARK: - Draft persistence

    /// The route's draft key: a session's own standardized path, or the shared new-chat
    /// sentinel. Computed fresh from `route`/`sessions` so it always matches what is on screen.
    private var currentDraftKey: String {
        selectedSession?.fileURL.standardizedFileURL.path ?? Self.newChatDraftKey
    }

    /// Hands the outgoing route's live composer state to the draft store before switching away,
    /// so it can be restored later. Attachments are parked in memory only; they never persist.
    private func parkCurrentDraft() {
        let key = currentDraftKey
        persistDraftText(draft, for: key)
        if attachments.isEmpty { attachmentsByKey.removeValue(forKey: key) } else { attachmentsByKey[key] = attachments }
    }

    private func persistDraftText(_ text: String, for key: String) {
        let evicted = draftStore.set(text, for: key)
        for stale in evicted { attachmentsByKey.removeValue(forKey: stale) }
        scheduleDraftPersistence()
    }

    /// Idle typing debounce: writing `state.json` on every keystroke is unacceptable, so a burst
    /// of edits collapses into one write after typing pauses.
    private func scheduleDraftPersistence() {
        draftPersistTask?.cancel()
        draftPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.flushDraftPersistence()
        }
    }

    /// Immediate write, used at the points a debounce must not delay: switching conversations,
    /// the app resigning active, and termination.
    private func flushDraftPersistence() {
        draftPersistTask?.cancel()
        draftPersistTask = nil
        guard persistence.state.drafts != draftStore.texts else { return }
        persistence.updateState { $0.drafts = draftStore.texts }
    }

    /// Inline composer attachments occupy U+FFFC placeholders in the text view; those never
    /// belong in the message Pi receives.
    nonisolated static func sanitizedMessage(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func optimisticMessage(text: String) -> ChatMessage {
        ChatMessage(
            id: "local-\(UUID().uuidString)", role: .user,
            blocks: [MessageBlock(id: UUID().uuidString, kind: .text(text))],
            timestamp: Date(), raw: .null
        )
    }

    func submitDraft(delivery: DeliveryMode = .automatic) {
        let text = Self.sanitizedMessage(draft)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let prompt = ImageAttachment.prompt(text: text, attachments: attachments)

        let cwd: URL
        let sessionPath: URL?
        if let selectedSession { cwd = selectedSession.cwd; sessionPath = selectedSession.fileURL }
        else if let selectedFolder { cwd = selectedFolder; sessionPath = nil }
        else { showToast("Choose a working folder first", style: .warning); return }

        let sentText = draft
        let sentAttachments = attachments
        let origin = DraftOrigin(route: route, sessionPath: sessionPath?.standardizedFileURL.path)
        let optimisticID: String?
        if delivery == .automatic, !(isSelectedRuntime && runtimeState.isStreaming) {
            let message = Self.optimisticMessage(text: prompt)
            optimisticID = message.id
            messages = enforcingLoadedImageBudget(messages + [message])
        } else {
            optimisticID = nil
        }
        draft = ""
        attachments = []
        ensureRuntime(cwd: cwd, sessionPath: sessionPath) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(slot):
                dispatchMessage(text, originalDraft: sentText, attachments: sentAttachments,
                                delivery: delivery, cwd: cwd, optimisticID: optimisticID,
                                submissionOrigin: origin, slot: slot)
            case let .failure(error):
                if let optimisticID { messages.removeAll { $0.id == optimisticID } }
                let restored = restoreDraft(text: sentText, attachments: sentAttachments, origin: origin)
                showToast(failureMessage(error.localizedDescription, restored: restored, origin: origin), style: .error)
            }
        }
    }

    /// Pi sessions are append-only, so editing a sent turn means forking immediately before the
    /// original entry and continuing in the new session. Only the active transcript moves; the
    /// abandoned answer remains available in the source session.
    func forkAndSubmitEditedMessage(
        targetID: String,
        targetText: String,
        messagesBeforeTarget: [ChatMessage],
        completion: @escaping () -> Void
    ) {
        guard let source = selectedSession else { completion(); return }
        let sourcePath = source.fileURL.standardizedFileURL.path
        let fail: (String, ToastMessage.Style) -> Void = { [weak self] message, style in
            self?.showToast(message, style: style)
            completion()
        }

        ensureRuntime(cwd: source.cwd, sessionPath: source.fileURL) { [weak self] result in
            guard let self else { completion(); return }
            guard case let .success(slot) = result else {
                if case let .failure(error) = result { fail(error.localizedDescription, .error) }
                return
            }
            guard slot === activeRuntimeSlot,
                  selectedSession?.fileURL.standardizedFileURL.path == sourcePath else {
                completion()
                return
            }
            guard !state(for: slot).isStreaming else {
                fail("Pi did not stop the current turn, so the edit was not sent.", .warning)
                return
            }

            let invalidateForkedRuntime = { [weak self, weak slot] in
                guard let self, let slot else { return }
                slot.isReady = false
                slot.runtime.stop()
                removeParkedReference(to: slot)
                updateState(for: slot) { state in
                    state.isConnected = false
                    state.isStreaming = false
                    state.phase = .idle
                }
            }

            let sendFork: (String) -> Void = { [weak self, weak slot] entryID in
                guard let self, let slot else { completion(); return }
                slot.runtime.send(type: "fork", payload: ["entryId": .string(entryID)]) { [weak self, weak slot] result in
                    guard let self, let slot else { completion(); return }
                    switch result {
                    case let .failure(error):
                        if RPCFailureHandling.isOutcomeUnknown(error) { invalidateForkedRuntime() }
                        fail(error.localizedDescription, RPCFailureHandling.isOutcomeUnknown(error) ? .warning : .error)
                        return
                    case let .success(response):
                        if let error = responseError(response) { fail(error, .error); return }
                        if response["data"]?["cancelled"]?.boolValue == true {
                            fail("A Pi extension cancelled the edit.", .warning)
                            return
                        }
                    }

                    slot.runtime.send(type: "get_state", payload: [:]) { [weak self, weak slot] result in
                        guard let self, let slot else { completion(); return }
                        guard slot === activeRuntimeSlot,
                              selectedSession?.fileURL.standardizedFileURL.path == sourcePath else {
                            invalidateForkedRuntime()
                            completion()
                            return
                        }
                        let response: JSONValue
                        switch result {
                        case let .failure(error):
                            invalidateForkedRuntime()
                            fail(error.localizedDescription, .error)
                            return
                        case let .success(value):
                            response = value
                        }
                        guard responseError(response) == nil,
                              let data = response["data"],
                              let sessionFile = data["sessionFile"]?.stringValue,
                              let sessionID = data["sessionId"]?.stringValue else {
                            invalidateForkedRuntime()
                            fail(responseError(response) ?? "Pi did not report the edited conversation.", .error)
                            return
                        }

                        let url = URL(fileURLWithPath: sessionFile).standardizedFileURL
                        guard url.path != sourcePath else {
                            invalidateForkedRuntime()
                            fail("Pi did not create an edited conversation.", .error)
                            return
                        }
                        applyState(data, to: slot)
                        slot.startedForNewChat = false

                        let forked: SessionSummary
                        if let existing = sessions.first(where: { $0.fileURL.standardizedFileURL.path == url.path }) {
                            forked = existing
                        } else {
                            var provisional = SessionSummary(
                                id: sessionID, fileURL: url, cwd: source.cwd,
                                createdAt: Date(), modifiedAt: Date(), name: source.name,
                                preview: source.preview, messageCount: messagesBeforeTarget.count,
                                metrics: TokenMetrics()
                            )
                            provisional.prepareSearchKey()
                            sessions.insert(provisional, at: 0)
                            syncActivityMonitorPaths()
                            observedActivityPaths.insert(url.path)
                            forked = provisional
                        }

                        let editedDraft = draft
                        let editedAttachments = attachments
                        draft = ""
                        attachments = []
                        selectSession(forked)
                        messages = enforcingLoadedImageBudget(messagesBeforeTarget)
                        draft = editedDraft
                        attachments = editedAttachments
                        submitDraft()
                        completion()
                    }
                }
            }

            if targetID.hasPrefix("local-") || targetID.hasPrefix("rpc-") {
                slot.runtime.send(type: "get_fork_messages", payload: [:]) { [weak self, weak slot] result in
                    guard let self, let slot else { completion(); return }
                    guard slot === activeRuntimeSlot,
                          selectedSession?.fileURL.standardizedFileURL.path == sourcePath else {
                        completion()
                        return
                    }
                    let response: JSONValue
                    switch result {
                    case let .failure(error):
                        fail(error.localizedDescription, .error)
                        return
                    case let .success(value):
                        response = value
                    }
                    if let error = responseError(response) {
                        fail(error, .error)
                        return
                    }
                    let original = Self.sanitizedMessage(targetText)
                    let entryID = response["data"]?["messages"]?.arrayValue?.reversed().first(where: {
                        Self.sanitizedMessage($0["text"]?.stringValue ?? "") == original
                    })?["entryId"]?.stringValue
                    guard let entryID else {
                        fail("Pi could not find the original message to edit.", .error)
                        return
                    }
                    sendFork(entryID)
                }
            } else {
                sendFork(targetID)
            }
        }
    }

    // MARK: - Extension commands

    /// Extension commands (`/mode`, `/codex-fast`, `/limits`) run through the normal prompt path.
    /// Pi executes them immediately and makes no provider call, so this never starts a turn.
    func runExtensionCommand(_ command: String, successToast: String? = nil) {
        let clean = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("/") else { return }

        let cwd: URL
        let sessionPath: URL?
        if let selectedSession { cwd = selectedSession.cwd; sessionPath = selectedSession.fileURL }
        else if let selectedFolder { cwd = selectedFolder; sessionPath = nil }
        else { showToast("Choose a working folder first", style: .warning); return }

        ensureRuntime(cwd: cwd, sessionPath: sessionPath) { [weak self] result in
            guard let self else { return }
            guard case let .success(slot) = result else {
                if case let .failure(error) = result { showToast(error.localizedDescription, style: .error) }
                return
            }
            slot.runtime.send(type: "prompt", payload: ["message": .string(clean)]) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(response):
                    if let error = responseError(response) { showToast(error, style: .error) }
                    else if let successToast { showToast(successToast, style: .info) }
                case let .failure(error) where RPCFailureHandling.isOutcomeUnknown(error):
                    showToast(error.localizedDescription, style: .warning)
                case let .failure(error):
                    showToast(error.localizedDescription, style: .error)
                }
            }
        }
    }

    func setMode(_ mode: PiMode) {
        runExtensionCommand("/mode \(mode.rawValue)", successToast: "Mode set to \(mode.label)")
    }

    func toggleFastPriority() {
        runExtensionCommand("/codex-fast")
    }

    /// `/limits` renders its report through the existing extension editor dialog bridge.
    func showLimits() {
        runExtensionCommand("/limits")
    }

    /// `/limits` reports through the extension editor dialog. Desktop recognises that dialog,
    /// closes it, and draws the report natively instead of showing a text dump.
    static let limitsDialogTitlePrefix = "AI usage limits"

    static func isLimitsDialog(method: String, title: String?) -> Bool {
        method == "editor" && (title ?? "").hasPrefix(limitsDialogTitlePrefix)
    }

    /// Only ever driven by an explicit hover: this must not spawn a Pi process on its own.
    func refreshLimits() {
        guard runtimeMatchesCurrentRoute else {
            LimitsReportStore.shared.fail("Open a conversation to load the full report")
            return
        }
        runtime.send(type: "prompt", payload: ["message": .string("/limits")]) { result in
            if case let .failure(error) = result { LimitsReportStore.shared.fail(error.localizedDescription) }
        }
    }

    // MARK: - Ephemeral status probe

    /// Briefly attaches a `--no-session` RPC runtime purely to collect `setStatus` events, then
    /// stops it. No prompt of any kind is sent during the probe.
    func refreshExtensionStatuses() {
        guard let probeRuntimeFactory else { return }
        // A real runtime already publishes statuses; probing would duplicate a Pi process.
        guard !runtime.isRunning, probeRuntime == nil else { return }

        let cwd = selectedSession?.cwd ?? selectedFolder ?? FileManager.default.homeDirectoryForCurrentUser
        let probe = probeRuntimeFactory()
        probe.onEvent = { [weak self] event in self?.handleProbeEvent(event) }
        probe.onExit = { [weak self] _ in self?.finishProbe() }
        probeRuntime = probe
        probeStatuses.removeAll()
        do {
            try probe.start(cwd: cwd, sessionPath: nil)
        } catch {
            probeRuntime = nil
            return
        }
        isProbingStatuses = true
        probeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishProbe()
        }
    }

    private func handleProbeEvent(_ event: JSONValue) {
        guard event["type"]?.stringValue == "extension_ui_request",
              event["method"]?.stringValue == "setStatus",
              let key = event["statusKey"]?.stringValue else { return }
        if let value = event["statusText"]?.stringValue {
            let clean = ANSI.strip(value)
            if clean.isEmpty { probeStatuses.removeValue(forKey: key) }
            else { probeStatuses[key] = clean.suffixString(500) }
        } else {
            probeStatuses.removeValue(forKey: key)
        }
    }

    private func finishProbe() {
        probeTask?.cancel()
        probeTask = nil
        guard let probe = probeRuntime else {
            isProbingStatuses = false
            return
        }
        probeRuntime = nil
        probe.onEvent = nil
        probe.onExit = nil
        probe.stop()
        isProbingStatuses = false
        if !probeStatuses.isEmpty {
            cachedStatuses.merge(probeStatuses) { _, fresh in fresh }
            persistence.cacheExtensionStatuses(cachedStatuses)
        }
    }

    func abort() {
        guard runtimeMatchesCurrentRoute, runtimeState.isStreaming else { return }
        runtime.send(type: "abort", payload: [:]) { [weak self] result in
            if case let .failure(error) = result { self?.showToast(error.localizedDescription, style: .error) }
        }
    }

    func compact() {
        guard isSelectedRuntime else { showToast("Open this conversation with Pi first.", style: .warning); return }
        runtime.send(type: "compact", payload: [:]) { [weak self] result in
            if case let .failure(error) = result { self?.showToast(error.localizedDescription, style: .error) }
        }
    }

    func exportHTML() {
        guard isSelectedRuntime else { showToast("Open this conversation with Pi first.", style: .warning); return }
        runtime.send(type: "export_html", payload: [:]) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(response):
                if let error = responseError(response) { showToast(error, style: .error) }
                else if let path = response["data"]?["path"]?.stringValue {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            case let .failure(error): showToast(error.localizedDescription, style: .error)
            }
        }
    }

    /// Actual editor mutations prewarm Pi; merely rendering or navigating to a composer does not.
    func composerContentDidChange() { prepareComposerOptions() }

    /// Starts or attaches the route's RPC runtime and loads picker choices. These are query-only
    /// commands and never send a provider prompt.
    func prepareComposerOptions() {
        let cwd = selectedSession?.cwd ?? selectedFolder
        guard let cwd else { return }
        let sessionPath = selectedSession?.fileURL
        ensureRuntime(cwd: cwd, sessionPath: sessionPath) { [weak self] result in
            guard let self else { return }
            guard case let .success(slot) = result, slot === activeRuntimeSlot, runtimeMatchesCurrentRoute else { return }
            requestComposerOptions()
        }
    }

    func setModel(_ model: AvailableModel) {
        guard runtimeMatchesCurrentRoute else { return }
        let slot = activeRuntimeSlot
        slot.runtime.send(type: "set_model", payload: [
            "provider": .string(model.provider),
            "modelId": .string(model.modelID)
        ]) { [weak self, weak slot] result in
            guard let self, let slot, slot === activeRuntimeSlot, runtimeMatchesCurrentRoute else { return }
            switch result {
            case let .success(response) where responseError(response) == nil:
                let value = response["data"]
                runtimeState.modelID = value?["id"]?.stringValue ?? model.modelID
                runtimeState.modelName = value?["name"]?.stringValue ?? model.name
                runtimeState.provider = value?["provider"]?.stringValue ?? model.provider
                refreshRuntimeStateAfterPickerChange(slot: slot)
            case let .success(response): showToast(responseError(response) ?? "Pi rejected the model.", style: .error)
            case let .failure(error): showToast(error.localizedDescription, style: .error)
            }
        }
    }

    func setThinkingLevel(_ level: String) {
        guard runtimeMatchesCurrentRoute, availableThinkingLevels.contains(level) else { return }
        let slot = activeRuntimeSlot
        slot.runtime.send(type: "set_thinking_level", payload: ["level": .string(level)]) { [weak self, weak slot] result in
            guard let self, let slot, slot === activeRuntimeSlot, runtimeMatchesCurrentRoute else { return }
            switch result {
            case let .success(response) where responseError(response) == nil:
                runtimeState.thinkingLevel = level
            case let .success(response): showToast(responseError(response) ?? "Pi rejected the thinking level.", style: .error)
            case let .failure(error): showToast(error.localizedDescription, style: .error)
            }
        }
    }

    // Kept for menu/status-bar compatibility; composer controls use the explicit RPC setters.
    func cycleModel() {
        guard runtimeMatchesCurrentRoute else { return }
        let slot = activeRuntimeSlot
        slot.runtime.send(type: "cycle_model", payload: [:]) { [weak self, weak slot] result in
            guard let self, let slot, slot === activeRuntimeSlot, runtimeMatchesCurrentRoute,
                  case let .success(response) = result, responseError(response) == nil else { return }
            if let model = response["data"]?["model"] {
                runtimeState.modelID = model["id"]?.stringValue
                runtimeState.modelName = model["name"]?.stringValue
                runtimeState.provider = model["provider"]?.stringValue
            }
            runtimeState.thinkingLevel = response["data"]?["thinkingLevel"]?.stringValue ?? runtimeState.thinkingLevel
            requestComposerOptions(slot: slot)
        }
    }

    func cycleThinkingLevel() {
        guard runtimeMatchesCurrentRoute else { return }
        let slot = activeRuntimeSlot
        slot.runtime.send(type: "cycle_thinking_level", payload: [:]) { [weak self, weak slot] result in
            guard let self, let slot, slot === activeRuntimeSlot, runtimeMatchesCurrentRoute,
                  case let .success(response) = result, responseError(response) == nil else { return }
            runtimeState.thinkingLevel = response["data"]?["level"]?.stringValue ?? runtimeState.thinkingLevel
        }
    }

    private var runtimeMatchesCurrentRoute: Bool {
        guard !activePresentationDetached, runtime.isRunning else { return false }
        if let selectedSession {
            return activeRuntimePath == selectedSession.fileURL.standardizedFileURL.path
        }
        guard let selectedFolder else { return false }
        return activeRuntimeStartedForNewChat
            && activeRuntimeCwd == selectedFolder.standardizedFileURL.path
    }

    private func requestComposerOptions(slot: RuntimeSlot? = nil) {
        let slot = slot ?? activeRuntimeSlot
        guard slot === activeRuntimeSlot, runtimeMatchesCurrentRoute else { composerOptionsLoading = false; return }
        guard !slot.optionsLoading, !slot.optionsPrepared else { return }
        slot.optionsLoading = true
        composerOptionsLoading = true
        slot.runtime.send(type: "get_available_models", payload: [:]) { [weak self, weak slot] result in
            guard let self, let slot, slot === activeRuntimeSlot, runtimeMatchesCurrentRoute else { return }
            if case let .success(response) = result, responseError(response) == nil {
                availableModels = AvailableModel.parse(response["data"]?["models"])
                slot.models = availableModels
            }
            requestThinkingOptions(slot: slot)
        }
    }

    private func requestThinkingOptions(slot: RuntimeSlot) {
        slot.runtime.send(type: "get_available_thinking_levels", payload: [:]) { [weak self, weak slot] result in
            guard let self, let slot, slot === activeRuntimeSlot, runtimeMatchesCurrentRoute else { return }
            if case let .success(response) = result, responseError(response) == nil {
                availableThinkingLevels = RuntimePickerState.thinkingLevels(from: response["data"]?["levels"])
                runtimeState.thinkingLevel = RuntimePickerState.selectedThinkingLevel(
                    in: availableThinkingLevels,
                    current: runtimeState.thinkingLevel
                )
                slot.thinkingLevels = availableThinkingLevels
            }
            composerOptionsLoading = false
            slot.optionsLoading = false
            slot.optionsPrepared = true
            resetRuntimeRetirementLease(for: slot)
        }
    }

    private func refreshRuntimeStateAfterPickerChange(slot: RuntimeSlot) {
        slot.runtime.send(type: "get_state", payload: [:]) { [weak self, weak slot] result in
            guard let self, let slot, slot === activeRuntimeSlot, runtimeMatchesCurrentRoute else { return }
            if case let .success(response) = result, responseError(response) == nil { applyState(response["data"], to: slot) }
            requestThinkingOptions(slot: slot)
        }
    }

    func setQueueMode(steering: Bool, mode: String) {
        guard isSelectedRuntime, ["all", "one-at-a-time"].contains(mode) else { return }
        let command = steering ? "set_steering_mode" : "set_follow_up_mode"
        let slot = activeRuntimeSlot
        slot.runtime.send(type: command, payload: ["mode": .string(mode)]) { [weak self, weak slot] result in
            guard let self, let slot else { return }
            if case let .success(response) = result, responseError(response) == nil {
                updateState(for: slot) { state in
                    if steering { state.steeringMode = mode } else { state.followUpMode = mode }
                }
            } else {
                let message: String
                if case let .failure(error) = result { message = error.localizedDescription }
                else if case let .success(response) = result { message = responseError(response) ?? "Pi rejected the mode." }
                else { message = "Pi rejected the mode." }
                showToast(message, style: .error)
            }
        }
    }

    func renameSelectedSession(_ name: String) {
        guard let session = selectedSession else { return }
        renameSession(session, to: name)
    }

    func renameSession(_ session: SessionSummary, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let path = session.fileURL.standardizedFileURL.path
        let sendRename: (RuntimeSlot) -> Void = { [weak self] slot in
            guard let self else { return }
            slot.runtime.send(type: "set_session_name", payload: ["name": .string(clean)]) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(response) where responseError(response) == nil:
                    updateState(for: slot) { $0.sessionName = clean }
                    if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                        sessions[index].name = clean
                        sessions[index].prepareSearchKey()
                    }
                    showToast("Conversation renamed", style: .info)
                    Task { await self.refreshSummary(for: session) }
                case let .success(response): showToast(responseError(response) ?? "Rename failed.", style: .error)
                case let .failure(error) where RPCFailureHandling.isOutcomeUnknown(error):
                    // The rename may already be in the session file; refresh instead of claiming failure.
                    showToast(error.localizedDescription, style: .warning)
                    Task { await self.refreshSummary(for: session) }
                case let .failure(error): showToast(error.localizedDescription, style: .error)
                }
            }
        }

        if activeRuntimePath == path, activeRuntimeSlot.runtime.isRunning,
           activeRuntimeSlot.isReady, state(for: activeRuntimeSlot).isBusy {
            sendRename(activeRuntimeSlot)
            return
        }
        if let slot = parkedRuntimes[.session(path)], slot.runtime.isRunning,
           slot.isReady, state(for: slot).isBusy {
            sendRename(slot)
            return
        }
        ensureRuntime(cwd: session.cwd, sessionPath: session.fileURL) { [weak self] result in
            guard let self else { return }
            guard case let .success(slot) = result else {
                if case let .failure(error) = result { showToast(error.localizedDescription, style: .error) }
                return
            }
            sendRename(slot)
        }
    }

    func respondToExtensionDialog(value: String? = nil, confirmed: Bool? = nil, cancelled: Bool = false) {
        guard let request = activeDialog else { return }
        sendExtensionResponse(request: request, value: value, confirmed: confirmed, cancelled: cancelled)
        advanceDialogQueue()
    }

    func questionnaireQuestion(for request: ExtensionDialogRequest) -> QuestionnaireQuestion? {
        guard let session = pendingQuestionnaire, !session.submitted,
              let first = session.questions.first,
              QuestionnaireRPCBridge.matches(request, question: first) else { return nil }
        return session.currentQuestion
    }

    /// The questionnaire Pi is actually waiting on in the conversation on screen. Nil until the
    /// first matching `extension_ui_request` lands (there is nothing to answer before it), and
    /// nil while another conversation is browsed, so the inline card never accepts input Pi has
    /// not asked for.
    var activeQuestionnaireSession: QuestionnaireSession? {
        guard isSelectedRuntime, let session = pendingQuestionnaire,
              let request = activeDialog, questionnaireQuestion(for: request) != nil else { return nil }
        return session
    }

    /// Tool call identity is exact: `pendingQuestionnaire.toolCallID` is the tool call ID the
    /// transcript row carries, so a question in another transcript can never match this row.
    func activeQuestionnaire(for toolCallID: String) -> QuestionnaireSession? {
        guard let session = activeQuestionnaireSession, session.toolCallID == toolCallID else { return nil }
        return session
    }

    func saveQuestionnaireAnswer(_ answer: QuestionnaireAnswer, move: Int) {
        guard var session = pendingQuestionnaire, !session.submitted,
              let question = session.currentQuestion,
              answer.isValid(multiSelect: question.multiSelect) else { return }
        session.answers[session.currentIndex] = answer
        session.currentIndex = min(session.questions.count - 1, max(0, session.currentIndex + move))
        pendingQuestionnaire = session
    }

    func moveQuestionnaireBack() {
        guard var session = pendingQuestionnaire, session.currentIndex > 0 else { return }
        session.currentIndex -= 1
        pendingQuestionnaire = session
    }

    /// Header-chip navigation across the buffered questions. The draft answer is kept when it is
    /// already valid; no RPC traffic is produced.
    func moveQuestionnaire(to index: Int, saving answer: QuestionnaireAnswer? = nil) {
        guard var session = pendingQuestionnaire, !session.submitted else { return }
        if let answer, let question = session.currentQuestion,
           answer.isValid(multiSelect: question.multiSelect) {
            session.answers[session.currentIndex] = answer
        }
        guard session.canNavigate(to: index) else { return }
        session.currentIndex = index
        pendingQuestionnaire = session
    }

    func submitQuestionnaire(_ answer: QuestionnaireAnswer) {
        guard var session = pendingQuestionnaire, !session.submitted,
              let question = session.currentQuestion,
              answer.isValid(multiSelect: question.multiSelect),
              let request = activeDialog else { return }
        session.answers[session.currentIndex] = answer
        guard session.allAnswered else { return }
        session.submitted = true
        session.currentIndex = 0
        pendingQuestionnaire = session
        sendQuestionnaireResponse(request: request, questionIndex: 0, queued: true)
    }

    func cancelQuestionnaire() {
        guard pendingQuestionnaire != nil else { return }
        pendingQuestionnaire = nil
        respondToExtensionDialog(cancelled: true)
    }

    /// Drops the buffered questionnaire and any extension request still parked for it, so a tool
    /// call that already ended can never resurface later as a generic sheet.
    private func discardQuestionnaire() {
        guard let session = pendingQuestionnaire else { return }
        pendingQuestionnaire = nil
        if let active = activeDialog, questionnaireRequest(active, belongsTo: session) {
            advanceDialogQueue()
        } else {
            dialogQueue.removeAll { questionnaireRequest($0, belongsTo: session) }
        }
    }

    /// The same cleanup for a parked runtime. Requests may be in its saved FIFO or still be raw
    /// deferred events that have never reached `handleExtensionUI`.
    private func discardQuestionnaire(from slot: RuntimeSlot) {
        guard let session = slot.questionnaire else { return }
        slot.questionnaire = nil
        slot.dialogs.removeAll { questionnaireRequest($0, belongsTo: session) }
        slot.deferredEvents.removeAll { deferredRequest($0, belongsTo: session) }
    }

    private func questionnaireRequest(
        _ request: ExtensionDialogRequest,
        belongsTo session: QuestionnaireSession
    ) -> Bool {
        if session.questions.contains(where: { QuestionnaireRPCBridge.matches(request, question: $0) }) {
            return true
        }
        // A custom single-select answer produces one follow-up input request with no question
        // title; the sequential bridge likewise identifies it solely by this pending value.
        return session.awaitingCustomText != nil && request.method == .input
    }

    private func deferredRequest(_ event: JSONValue, belongsTo session: QuestionnaireSession) -> Bool {
        guard event["type"]?.stringValue == "extension_ui_request",
              let rawMethod = event["method"]?.stringValue,
              let method = ExtensionDialogRequest.Method(rawValue: rawMethod) else { return false }
        return questionnaireRequest(
            ExtensionDialogRequest(
                id: event["id"]?.stringValue ?? "",
                method: method,
                title: event["title"]?.stringValue ?? "Pi",
                raw: .null
            ),
            belongsTo: session
        )
    }

    private func sendExtensionResponse(
        request: ExtensionDialogRequest,
        value: String? = nil,
        confirmed: Bool? = nil,
        cancelled: Bool = false
    ) {
        var response: [String: JSONValue] = ["type": .string("extension_ui_response"), "id": .string(request.id)]
        if cancelled { response["cancelled"] = .bool(true) }
        else if let confirmed { response["confirmed"] = .bool(confirmed) }
        else if let value { response["value"] = .string(value) }
        else { response["cancelled"] = .bool(true) }
        runtime.sendUncorrelated(.object(response))
    }

    /// Pops the answered/expired dialog and presents the next queued one, so a burst of
    /// extension requests is answered in order instead of overwriting each other.
    private func advanceDialogQueue() {
        dialogTimeoutTask?.cancel()
        dialogTimeoutTask = nil
        if !dialogQueue.isEmpty { dialogQueue.removeFirst() }
        activeDialog = dialogQueue.first
        if let next = activeDialog { startDialogTimeout(for: next) }
        else { resetRuntimeRetirementLease(for: activeRuntimeSlot) }
    }

    private func startDialogTimeout(for request: ExtensionDialogRequest) {
        guard let timeout = request.timeoutMilliseconds, timeout > 0 else { return }
        dialogTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
            guard !Task.isCancelled, let self, activeDialog?.id == request.id else { return }
            // Pi owns the extension-side timeout; the desktop only stops blocking the queue.
            if questionnaireQuestion(for: request) != nil { pendingQuestionnaire = nil }
            advanceDialogQueue()
        }
    }

    /// Dialogs belong to the runtime that requested them. Clearing them before a switch and on
    /// exit prevents a stale dialog ID from being answered into a replacement runtime.
    private func clearExtensionDialogs() {
        dialogTimeoutTask?.cancel()
        dialogTimeoutTask = nil
        dialogQueue.removeAll()
        activeDialog = nil
        pendingQuestionnaire = nil
    }

    func addAttachments(_ values: [ImageAttachment]) {
        attachments.append(contentsOf: admitAttachments(values, existing: attachments))
    }

    /// Applies the image budgets against an explicit existing set and warns once, without
    /// mutating state. The composer uses this so inline insertion order stays authoritative.
    func admitAttachments(_ values: [ImageAttachment], existing: [ImageAttachment]) -> [ImageAttachment] {
        let valid = values.filter { $0.data.count <= PiTheme.imageByteLimit }
        var accepted: [ImageAttachment] = []
        var bytes = existing.reduce(0) { $0 + $1.data.count }
        for value in valid where existing.count + accepted.count < PiTheme.imageCountLimit {
            guard bytes + value.data.count <= PiTheme.totalImageByteLimit else { continue }
            accepted.append(value); bytes += value.data.count
        }
        if accepted.count != values.count {
            showToast("Some images were skipped (8 images, 16 MB each, 64 MB total maximum).", style: .warning)
        }
        return accepted
    }

    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }
    func showImage(_ image: ImagePayload) { viewedImage = ViewedImage(image: image) }

    func refreshSelectedGit() {
        selectedGitTask?.cancel()
        selectedGitTask = Task { [weak self] in await self?.refreshSelectedGitAndWait() }
    }

    /// One awaited refresh at a time; the caller (menu action or polling loop) never spawns
    /// overlapping git command chains. A session's own cwd is always fair game (Pi already
    /// reads/writes there); a bare `selectedFolder` with no conversation open yet only refreshes
    /// once the user has actually opted into it, so the passive default folder shown before any
    /// chat exists can never trigger a git subprocess — and the TCC prompt a protected directory
    /// brings with it — on its own.
    private func refreshSelectedGitAndWait() async {
        if let session = selectedSession {
            await refreshGit(for: session.cwd)
            return
        }
        guard let folder = selectedFolder, hasOptedIntoGitRefresh(folder) else { return }
        await refreshGit(for: folder)
    }

    /// A folder counts as opted into once the user has actually done something with it: chosen
    /// it from the folder picker (which remembers it), or it already backs a real session.
    private func hasOptedIntoGitRefresh(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if persistence.state.recentFolders.contains(path) { return true }
        return sessions.contains { $0.cwd.standardizedFileURL.path == path }
    }

    private func ensureRuntime(
        cwd: URL,
        sessionPath: URL?,
        completion: @escaping (Result<RuntimeSlot, Error>) -> Void
    ) {
        if probeRuntime != nil { finishProbe() }
        cancelRuntimeRetirementLease()

        let key = runtimeKey(cwd: cwd, sessionPath: sessionPath)
        if let parked = parkedRuntimes[key] {
            if parked.runtime.isRunning {
                activateRuntime(parked)
                completeOrWait(for: parked, completion: completion)
                return
            }
            parkedRuntimes.removeValue(forKey: key)
        }

        if runtime.isRunning, runtimeKey(for: activeRuntimeSlot) == key {
            if activePresentationDetached { restoreRuntimePresentation(activeRuntimeSlot) }
            completeOrWait(for: activeRuntimeSlot, completion: completion)
            return
        }

        let previous = activeRuntimeSlot
        if canReuseProcess(previous, in: cwd) {
            let oldSessionPath = state(for: previous).sessionFile ?? previous.sessionPath
            removeParkedReference(to: previous)
            previous.isSuperseded = true
            previous.runtime.onEvent = nil
            let slot = RuntimeSlot(runtime: previous.runtime)
            slot.runtime.onExit = { [weak self, weak slot] error in
                guard let self, let slot else { return }
                self.handleRuntimeExit(error, from: slot)
            }
            activeRuntimeSlot = slot
            configureRuntimeSlot(slot, cwd: cwd, sessionPath: sessionPath, phase: .openingConversation, completion: completion)
            switchReusedRuntime(slot, cwd: cwd, sessionPath: sessionPath, oldSessionPath: oldSessionPath)
            return
        }

        let slot: RuntimeSlot
        if shouldPark(previous) {
            guard let currentKey = runtimeKey(for: previous) else {
                completion(.failure(PiRPCError.processExited("Could not preserve the current Pi run.")))
                return
            }
            saveActiveRuntimePresentation()
            parkedRuntimes[currentKey] = previous
            slot = RuntimeSlot(runtime: runtimeFactory())
        } else {
            removeParkedReference(to: previous)
            slot = RuntimeSlot(runtime: previous.runtime)
        }
        bindRuntime(slot)
        activeRuntimeSlot = slot
        configureRuntimeSlot(slot, cwd: cwd, sessionPath: sessionPath, phase: .startingPi, completion: completion)
        coldStartRuntime(slot, cwd: cwd, sessionPath: sessionPath)
    }

    private func completeOrWait(
        for slot: RuntimeSlot,
        completion: @escaping (Result<RuntimeSlot, Error>) -> Void
    ) {
        if slot.isReady {
            completion(.success(slot))
            resetRuntimeRetirementLease(for: slot)
        } else {
            slot.readyWaiters.append(completion)
        }
    }

    private func canReuseProcess(_ slot: RuntimeSlot, in cwd: URL) -> Bool {
        slot.runtime.isRunning
            && slot.isReady
            && slot.cwd == cwd.standardizedFileURL.path
            && state(for: slot).lastError == nil
            && isIdleAndClean(slot)
    }

    private func configureRuntimeSlot(
        _ slot: RuntimeSlot,
        cwd: URL,
        sessionPath: URL?,
        phase: RuntimePhase,
        completion: @escaping (Result<RuntimeSlot, Error>) -> Void
    ) {
        clearExtensionDialogs()
        slot.sessionPath = sessionPath?.standardizedFileURL.path
        slot.cwd = cwd.standardizedFileURL.path
        slot.startedForNewChat = sessionPath == nil
        slot.state = RuntimeState(phase: phase)
        slot.metrics = TokenMetrics()
        slot.models.removeAll()
        slot.thinkingLevels = ["off"]
        slot.optionsLoading = false
        slot.optionsPrepared = false
        slot.capability = nil
        slot.questionnaire = nil
        slot.statuses.removeAll()
        slot.widgets.removeAll()
        slot.windowTitle = "Pi Desktop"
        slot.dialogs.removeAll()
        slot.outbox.removeAll()
        slot.streamingMessage = nil
        slot.pendingTurn = nil
        slot.outboxDispatches.removeAll()
        slot.deferredEvents.removeAll()
        slot.isReady = false
        slot.isStarting = true
        slot.startupBeganAt = Date()
        slot.promptBeganAt = nil
        slot.readyWaiters = [completion]
        restoreRuntimePresentation(slot)
    }

    private func switchReusedRuntime(
        _ slot: RuntimeSlot,
        cwd: URL,
        sessionPath: URL?,
        oldSessionPath: String?
    ) {
        let command = sessionPath == nil ? "new_session" : "switch_session"
        let payload = sessionPath.map { ["sessionPath": JSONValue.string($0.standardizedFileURL.path)] } ?? [:]
        slot.runtime.send(type: command, payload: payload) { [weak self, weak slot] result in
            guard let self, let slot else { return }
            guard case let .success(response) = result,
                  responseError(response) == nil,
                  response["data"]?["cancelled"]?.boolValue != true else {
                bindRuntime(slot)
                coldStartRuntime(slot, cwd: cwd, sessionPath: sessionPath)
                return
            }
            loadRuntimeState(
                slot,
                sessionPath: sessionPath,
                reusedFrom: oldSessionPath,
                validateReusedRoute: true,
                bindOnSuccess: true
            ) {
                self.bindRuntime(slot)
                self.coldStartRuntime(slot, cwd: cwd, sessionPath: sessionPath)
            }
        }
    }

    private func coldStartRuntime(_ slot: RuntimeSlot, cwd: URL, sessionPath: URL?) {
        slot.sessionPath = sessionPath?.standardizedFileURL.path
        slot.cwd = cwd.standardizedFileURL.path
        slot.startedForNewChat = sessionPath == nil
        updateState(for: slot) { $0 = RuntimeState(phase: .startingPi) }
        if slot.runtime.isRunning { slot.runtime.stop() }
        do {
            try slot.runtime.start(cwd: cwd, sessionPath: sessionPath)
            updateState(for: slot) { state in
                state.isConnected = true
                state.phase = .openingConversation
            }
        } catch {
            updateState(for: slot) { $0.lastError = error.localizedDescription }
            finishRuntimeStart(slot, result: .failure(error))
            return
        }
        loadRuntimeState(slot, sessionPath: sessionPath, reusedFrom: nil)
    }

    private func loadRuntimeState(
        _ slot: RuntimeSlot,
        sessionPath: URL?,
        reusedFrom oldSessionPath: String?,
        validateReusedRoute: Bool = false,
        bindOnSuccess: Bool = false,
        onReuseFailure: (() -> Void)? = nil
    ) {
        slot.runtime.send(type: "get_state", payload: [:]) { [weak self, weak slot] result in
            guard let self, let slot else { return }
            guard case let .success(response) = result, responseError(response) == nil else {
                if let onReuseFailure { onReuseFailure(); return }
                let error: Error
                switch result {
                case let .failure(value): error = value
                case let .success(response):
                    error = PiRPCError.processExited(responseError(response) ?? "Pi rejected get_state.")
                }
                failRuntimeStart(slot, error: error)
                return
            }
            applyState(response["data"], to: slot)
            if validateReusedRoute,
               !runtimeStateMatchesReusedRoute(slot, sessionPath: sessionPath, oldSessionPath: oldSessionPath) {
                onReuseFailure?()
                return
            }
            if bindOnSuccess { bindRuntime(slot) }
            finishRuntimeStart(slot, result: .success(slot))
            if slot === activeRuntimeSlot { requestStats() }
        }
    }

    private func runtimeStateMatchesReusedRoute(
        _ slot: RuntimeSlot,
        sessionPath: URL?,
        oldSessionPath: String?
    ) -> Bool {
        guard let reported = state(for: slot).sessionFile, !reported.isEmpty else { return false }
        let path = URL(fileURLWithPath: reported).standardizedFileURL.path
        if let sessionPath { return path == sessionPath.standardizedFileURL.path }
        guard let oldSessionPath else { return false }
        return path != URL(fileURLWithPath: oldSessionPath).standardizedFileURL.path
    }

    private func failRuntimeStart(_ slot: RuntimeSlot, error: Error) {
        updateState(for: slot) { state in
            state.lastError = error.localizedDescription
            state.isConnected = false
            state.phase = .idle
        }
        slot.runtime.stop()
        finishRuntimeStart(slot, result: .failure(error))
    }

    private func finishRuntimeStart(_ slot: RuntimeSlot, result: Result<RuntimeSlot, Error>) {
        slot.isStarting = false
        if case .success = result {
            slot.isReady = true
            if let beganAt = slot.startupBeganAt {
                ConversationPerformance.mark(
                    "Pi runtime ready", path: slot.sessionPath ?? slot.cwd ?? "unknown",
                    milliseconds: Date().timeIntervalSince(beganAt) * 1_000
                )
            }
        }
        slot.startupBeganAt = nil
        let waiters = slot.readyWaiters
        slot.readyWaiters.removeAll()
        for waiter in waiters { waiter(result) }
        if slot === activeRuntimeSlot {
            resetRuntimeRetirementLease(for: slot)
        } else if isIdleAndClean(slot) {
            retireBackgroundRuntime(slot)
        }
    }

    private func dispatchMessage(
        _ text: String,
        originalDraft: String,
        attachments sentAttachments: [ImageAttachment],
        delivery: DeliveryMode,
        cwd: URL,
        optimisticID: String?,
        submissionOrigin: DraftOrigin,
        slot: RuntimeSlot
    ) {
        let command: String
        switch delivery {
        case .steer: command = "steer"
        case .followUp: command = "follow_up"
        case .automatic: command = state(for: slot).isStreaming ? "steer" : "prompt"
        }

        let prompt = ImageAttachment.prompt(text: text, attachments: sentAttachments)
        let promotedOrigin = ensureProvisionalSession(cwd: cwd, prompt: prompt, slot: slot)
        let origin = promotedOrigin ?? submissionOrigin
        if command != "prompt", let optimisticID { messages.removeAll { $0.id == optimisticID } }
        if command == "prompt" {
            slot.pendingTurn = PendingUserTurn(origin: origin, text: originalDraft, attachments: sentAttachments)
        }

        let payload: [String: JSONValue] = ["message": .string(prompt)]
        let wasStreaming = state(for: slot).isStreaming
        let previousPhase = state(for: slot).phase
        if command == "prompt" {
            slot.promptBeganAt = Date()
            if slot === activeRuntimeSlot { cancelRuntimeRetirementLease() }
            updateState(for: slot) { state in
                state.isStreaming = true
                state.phase = .waitingForModel
            }
        }

        slot.runtime.send(type: command, payload: payload) { [weak self, weak slot] result in
            guard let self, let slot else { return }
            let errorText: String?
            var isOutcomeUnknown = false
            switch result {
            case let .success(response): errorText = responseError(response)
            case let .failure(error):
                errorText = error.localizedDescription
                isOutcomeUnknown = RPCFailureHandling.isOutcomeUnknown(error)
            }
            guard let errorText else {
                if command == "steer" { showToast("Steering message queued", style: .info) }
                if command == "follow_up" { showToast("Follow-up queued", style: .info) }
                return
            }
            // An unconfirmed side-effecting command may already have reached Pi. Only settle or
            // process exit can safely resolve it without risking a duplicate prompt.
            if isOutcomeUnknown {
                showToast(errorText, style: .warning)
                return
            }
            if command == "prompt" {
                updateState(for: slot) { state in
                    state.isStreaming = wasStreaming
                    state.phase = previousPhase
                }
                slot.promptBeganAt = nil
                slot.pendingTurn = nil
            }
            if let optimisticID { messages.removeAll { $0.id == optimisticID } }
            let restored = restoreDraft(text: originalDraft, attachments: sentAttachments, origin: origin)
            showToast(failureMessage(errorText, restored: restored, origin: origin), style: .error)
            if slot === activeRuntimeSlot { resetRuntimeRetirementLease(for: slot) }
            else if !state(for: slot).isBusy { retireBackgroundRuntime(slot) }
        }
    }

    /// Restores a failed submission only into the composer it came from, and reports whether it
    /// did. When the user has moved on, the current draft is left completely untouched.
    @discardableResult
    private func restoreDraft(text: String, attachments sent: [ImageAttachment], origin: DraftOrigin) -> Bool {
        let currentPath = selectedSession?.fileURL.standardizedFileURL.path
        if DraftOrigin.shouldRestoreDraft(origin: origin, currentRoute: route, currentSessionPath: currentPath) {
            draft = DraftRecovery.restoredText(sent: text, current: draft)
            attachments = DraftRecovery.restoredAttachments(sent: sent, current: attachments)
            return true
        }

        let key = origin.sessionPath ?? Self.newChatDraftKey
        persistDraftText(DraftRecovery.restoredText(sent: text, current: draftStore.text(for: key)), for: key)
        let restoredAttachments = DraftRecovery.restoredAttachments(
            sent: sent,
            current: attachmentsByKey[key] ?? []
        )
        if restoredAttachments.isEmpty { attachmentsByKey.removeValue(forKey: key) }
        else { attachmentsByKey[key] = restoredAttachments }
        return false
    }

    private func failureMessage(_ error: String, restored: Bool, origin: DraftOrigin) -> String {
        restored ? error : "\(origin.conversationDescription.capitalizedFirst): \(error)"
    }

    @discardableResult
    private func ensureProvisionalSession(cwd: URL, prompt: String, slot: RuntimeSlot) -> DraftOrigin? {
        let slotState = state(for: slot)
        guard slot.startedForNewChat,
              let sessionID = slotState.sessionID, !sessionID.isEmpty,
              let file = slotState.sessionFile, !file.isEmpty else { return nil }
        let url = URL(fileURLWithPath: file).standardizedFileURL
        let path = url.path
        let title = prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(74)
        if !sessions.contains(where: { $0.fileURL.standardizedFileURL.path == path }) {
            var provisional = SessionSummary(
                id: sessionID, fileURL: url, cwd: cwd, createdAt: Date(), modifiedAt: Date(),
                name: title.isEmpty ? "New conversation" : String(title), preview: prompt,
                messageCount: 0, metrics: TokenMetrics()
            )
            provisional.prepareSearchKey()
            sessions.insert(provisional, at: 0)
            syncActivityMonitorPaths()
            // This path was created during this app run, so its first completion is not stale
            // launch history and may notify if the user has moved away.
            observedActivityPaths.insert(path)
        }

        removeParkedReference(to: slot)
        slot.sessionPath = path
        slot.startedForNewChat = false
        if slot !== activeRuntimeSlot { parkedRuntimes[.session(path)] = slot }

        if slot === activeRuntimeSlot, case .newChat = route {
            route = .session(path)
            activities = []
        }
        return DraftOrigin(route: .session(path), sessionPath: path)
    }

    /// Disk pages never erase optimistic user content or a terminal RPC answer that has not yet
    /// reached JSONL. Once the durable equivalent appears, the overlay removes itself.
    private func replaceLoadedMessages(with loaded: [ChatMessage]) {
        let optimistic = messages.filter { $0.id.hasPrefix("local-") }
        var merged = loaded + optimistic.filter { local in
            !loaded.contains { candidate in
                guard candidate.role == .user,
                      candidate.textContent == local.textContent,
                      candidate.images.count == local.images.count,
                      let candidateTime = candidate.timestamp,
                      let localTime = local.timestamp else { return false }
                return candidateTime >= localTime.addingTimeInterval(-0.01)
            }
        }

        if let path = loadedConversationPath {
            removeDurableLiveMessages(in: loaded, path: path)
            for live in liveMessagesByPath[path] ?? [] where !merged.contains(where: { $0.id == live.id }) {
                merged.append(live)
            }
            if let pending = pendingFinalMessagesByPath[path] {
                if loaded.contains(where: { durableAnswer($0, matches: pending) }) {
                    removePendingFinal(path: path)
                } else if !merged.contains(where: { $0.id == pending.id }) {
                    merged.append(pending)
                }
            }
        }
        messages = enforcingLoadedImageBudget(merged)
    }

    private func enforcingLoadedImageBudget(_ source: [ChatMessage]) -> [ChatMessage] {
        var result = source.count > Self.loadedMessageLimit
            ? Array(source.suffix(Self.loadedMessageLimit))
            : source
        var count = 0
        var bytes = 0
        // Newer messages win. Paging backward can otherwise multiply the parser's per-page image
        // allowance into an unbounded retained window.
        for messageIndex in result.indices.reversed() {
            var message = result[messageIndex]
            for blockIndex in message.blocks.indices {
                guard case let .image(image) = message.blocks[blockIndex].kind else { continue }
                if count < PiTheme.imageCountLimit,
                   image.data.count <= PiTheme.imageByteLimit,
                   bytes + image.data.count <= PiTheme.totalImageByteLimit {
                    count += 1
                    bytes += image.data.count
                } else {
                    let block = message.blocks[blockIndex]
                    message.blocks[blockIndex] = MessageBlock(
                        id: block.id,
                        kind: .unknown(type: "image", raw: .string(ImageBudget.omittedPlaceholder))
                    )
                }
            }
            result[messageIndex] = message
        }
        return result
    }

    private func durableAnswer(_ candidate: ChatMessage, matches pending: ChatMessage) -> Bool {
        candidate.role == .assistant && durableMessage(candidate, matches: pending)
    }

    private func durableMessage(_ candidate: ChatMessage, matches live: ChatMessage) -> Bool {
        guard candidate.role == live.role, candidate.textContent == live.textContent,
              candidate.toolCallID == live.toolCallID, candidate.isError == live.isError else { return false }
        if let candidateTime = candidate.timestamp, let liveTime = live.timestamp {
            return abs(candidateTime.timeIntervalSince(liveTime)) < 0.01
        }
        return candidate.id == live.id
    }

    private func retainLiveMessage(_ message: ChatMessage, path: String) {
        let key = LiveMessageKey(path: path, id: message.id)
        var live = liveMessagesByPath[path] ?? []
        if let index = live.firstIndex(where: { $0.id == message.id }) { live[index] = message }
        else { live.append(message) }
        liveMessagesByPath[path] = live
        liveMessageOrder.removeAll { $0 == key }
        liveMessageOrder.append(key)
        while liveMessageOrder.count > Self.liveMessageLimit {
            let removed = liveMessageOrder.removeFirst()
            liveMessagesByPath[removed.path]?.removeAll { $0.id == removed.id }
            if liveMessagesByPath[removed.path]?.isEmpty == true { liveMessagesByPath.removeValue(forKey: removed.path) }
        }
        let bounded = enforcingLoadedImageBudget(liveMessageOrder.compactMap { key in
            liveMessagesByPath[key.path]?.first { $0.id == key.id }
        })
        for (key, message) in zip(liveMessageOrder, bounded) {
            guard let index = liveMessagesByPath[key.path]?.firstIndex(where: { $0.id == key.id }) else { continue }
            liveMessagesByPath[key.path]?[index] = message
        }
    }

    private func removeDurableLiveMessages(in loaded: [ChatMessage], path: String) {
        guard let live = liveMessagesByPath[path] else { return }
        let durableIDs = Set(live.filter { item in
            loaded.contains { durableMessage($0, matches: item) }
        }.map(\.id))
        guard !durableIDs.isEmpty else { return }
        liveMessagesByPath[path] = live.filter { !durableIDs.contains($0.id) }
        if liveMessagesByPath[path]?.isEmpty == true { liveMessagesByPath.removeValue(forKey: path) }
        liveMessageOrder.removeAll { $0.path == path && durableIDs.contains($0.id) }
    }

    private func retainPendingFinal(_ message: ChatMessage, for slot: RuntimeSlot) {
        guard message.role == .assistant,
              let path = slot.sessionPath ?? state(for: slot).sessionFile else { return }
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        pendingFinalMessagesByPath[key] = message
        pendingFinalOrder.removeAll { $0 == key }
        pendingFinalOrder.append(key)
        while pendingFinalOrder.count > Self.pendingFinalLimit {
            pendingFinalMessagesByPath.removeValue(forKey: pendingFinalOrder.removeFirst())
        }
        let bounded = enforcingLoadedImageBudget(pendingFinalOrder.compactMap { pendingFinalMessagesByPath[$0] })
        for (path, message) in zip(pendingFinalOrder, bounded) {
            pendingFinalMessagesByPath[path] = message
        }
    }

    private func removePendingFinal(path: String) {
        pendingFinalMessagesByPath.removeValue(forKey: path)
        pendingFinalOrder.removeAll { $0 == path }
    }

    private func requestStats() {
        let slot = activeRuntimeSlot
        guard slot.runtime.isRunning else { return }
        slot.runtime.send(type: "get_session_stats", payload: [:]) { [weak self, weak slot] result in
            guard let self, let slot, case let .success(response) = result, responseError(response) == nil,
                  let data = response["data"] else { return }
            var metrics = TokenMetrics()
            let tokens = data["tokens"]
            metrics.input = tokens?["input"]?.intValue ?? 0
            metrics.output = tokens?["output"]?.intValue ?? 0
            metrics.cacheRead = tokens?["cacheRead"]?.intValue ?? 0
            metrics.cacheWrite = tokens?["cacheWrite"]?.intValue ?? 0
            metrics.cost = data["cost"]?.doubleValue ?? 0
            metrics.contextTokens = data["contextUsage"]?["tokens"]?.intValue
            metrics.contextWindow = data["contextUsage"]?["contextWindow"]?.intValue
            metrics.contextPercent = data["contextUsage"]?["percent"]?.doubleValue
            metrics.latestCacheHitPercent = slot === activeRuntimeSlot
                ? liveMetrics.latestCacheHitPercent
                : slot.metrics.latestCacheHitPercent
            slot.metrics = metrics
            if slot === activeRuntimeSlot { liveMetrics = metrics }
        }
    }

    private func applyState(_ data: JSONValue?, to target: RuntimeSlot? = nil) {
        guard let data else { return }
        let slot = target ?? activeRuntimeSlot
        updateState(for: slot) { state in
            state.isConnected = true
            state.isStreaming = data["isStreaming"]?.boolValue ?? false
            state.phase = state.isStreaming ? .working : .idle
            state.isCompacting = data["isCompacting"]?.boolValue ?? false
            state.thinkingLevel = data["thinkingLevel"]?.stringValue
            state.sessionFile = data["sessionFile"]?.stringValue
            state.sessionID = data["sessionId"]?.stringValue
            state.sessionName = data["sessionName"]?.stringValue
            state.modelID = data["model"]?["id"]?.stringValue
            state.modelName = data["model"]?["name"]?.stringValue
            state.provider = data["model"]?["provider"]?.stringValue
            state.steeringMode = data["steeringMode"]?.stringValue ?? state.steeringMode
            state.followUpMode = data["followUpMode"]?.stringValue ?? state.followUpMode
            state.steeringQueue = queueStrings(data["steeringQueue"] ?? data["steering"])
            state.followUpQueue = queueStrings(data["followUpQueue"] ?? data["followUp"])
        }
        if let path = state(for: slot).sessionFile, !path.isEmpty {
            slot.sessionPath = URL(fileURLWithPath: path).standardizedFileURL.path
        }
    }

    private func handleRPCEvent(_ event: JSONValue, from slot: RuntimeSlot) {
        guard !slot.isSuperseded else { return }
        if slot === activeRuntimeSlot, !activePresentationDetached {
            handleRPCEvent(event)
        } else {
            handleBackgroundRPCEvent(event, slot: slot)
        }
    }

    private func recordRuntimeOutput(for slot: RuntimeSlot) {
        updateState(for: slot) { $0.phase = .working }
        guard let beganAt = slot.promptBeganAt else { return }
        slot.promptBeganAt = nil
        ConversationPerformance.mark(
            "Pi first output", path: slot.sessionPath ?? slot.cwd ?? "unknown",
            milliseconds: Date().timeIntervalSince(beganAt) * 1_000
        )
    }

    private func handleBackgroundRPCEvent(_ event: JSONValue, slot: RuntimeSlot) {
        let type = event["type"]?.stringValue ?? "unknown"
        switch type {
        case "agent_start":
            slot.outboxDispatches.removeAll()
            if slot === activeRuntimeSlot { cancelRuntimeRetirementLease() }
            updateState(for: slot) { state in
                state.isStreaming = true
                if state.phase != .waitingForModel { state.phase = .working }
            }
        case "agent_settled":
            updateState(for: slot) { state in
                state.isStreaming = false
                state.isRetrying = false
                state.phase = .idle
            }
            slot.capability = nil
            discardQuestionnaire(from: slot)
            slot.streamingMessage = nil
            slot.pendingTurn = nil
            slot.promptBeganAt = nil
            let startedFollowUp = flushBackgroundOutbox(.followUp, slot: slot)
            let session = session(for: slot)
            if let session { Task { await self.refreshSummary(for: session) } }
            if !startedFollowUp {
                if slot === activeRuntimeSlot { resetRuntimeRetirementLease(for: slot) }
                scheduleFinalDurabilityCheck(for: slot, retireWhenDone: slot !== activeRuntimeSlot)
            }
        case "message_update":
            recordRuntimeOutput(for: slot)
            if let partial = event["message"], let parsed = SessionParser.chatMessage(fromAgentMessage: partial) {
                slot.streamingMessage = parsed
            }
        case "message_end":
            recordRuntimeOutput(for: slot)
            slot.streamingMessage = nil
            if let raw = event["message"], let parsed = SessionParser.chatMessage(fromAgentMessage: raw) {
                if let path = slot.sessionPath ?? state(for: slot).sessionFile {
                    retainLiveMessage(parsed, path: URL(fileURLWithPath: path).standardizedFileURL.path)
                }
                if SessionParser.terminalAssistantStopReasons.contains(raw["stopReason"]?.stringValue ?? "") {
                    retainPendingFinal(parsed, for: slot)
                }
            }
        case "tool_execution_start":
            recordRuntimeOutput(for: slot)
            if let callID = event["toolCallId"]?.stringValue,
               let name = event["toolName"]?.stringValue,
               name.lowercased() == "ask_user_question" {
                let arguments = event["args"] ?? .object([:])
                slot.capability = CapabilityPresenter.capability(
                    toolName: name,
                    callID: callID,
                    arguments: arguments
                )
                slot.questionnaire = QuestionnaireParser.parse(toolCallID: callID, arguments: arguments)
                if slot === activeRuntimeSlot, !activePresentationDetached {
                    activeCapability = slot.capability
                    pendingQuestionnaire = slot.questionnaire
                }
                notify(.questionWaiting, session: session(for: slot))
            }
        case "queue_update":
            updateState(for: slot) { state in
                state.steeringQueue = queueStrings(event["steering"])
                state.followUpQueue = queueStrings(event["followUp"])
            }
        case "compaction_start":
            updateState(for: slot) { $0.isCompacting = true }
        case "compaction_end":
            updateState(for: slot) { state in
                state.isCompacting = false
                if let error = event["errorMessage"]?.stringValue { state.lastError = error }
            }
        case "auto_retry_start":
            updateState(for: slot) { state in
                state.isRetrying = true
                state.retryAttempt = event["attempt"]?.intValue
            }
        case "auto_retry_end":
            updateState(for: slot) { state in
                state.isRetrying = false
                if event["success"]?.boolValue == false { state.lastError = event["finalError"]?.stringValue }
            }
        case "extension_ui_request":
            handleBackgroundExtensionUI(event, slot: slot)
        case "extension_error":
            updateState(for: slot) { $0.lastError = event["error"]?.stringValue ?? "A Pi extension failed." }
        case "tool_execution_end":
            if let id = event["toolCallId"]?.stringValue {
                if slot.capability?.sourceID == id { slot.capability = nil }
                if slot.questionnaire?.toolCallID == id { discardQuestionnaire(from: slot) }
            }
        case "turn_end":
            slot.capability = nil
            discardQuestionnaire(from: slot)
            _ = flushBackgroundOutbox(.steer, slot: slot)
        case "message_start", "tool_execution_update", "bash_execution_update":
            recordRuntimeOutput(for: slot)
        case "agent_end", "turn_start", "summarization_retry_scheduled", "summarization_retry_attempt_start",
             "summarization_retry_finished":
            break
        default:
            unknownRPCEvents.append(event.prettyPrinted(maxLength: PiTheme.unknownPayloadLimit))
            if unknownRPCEvents.count > 30 { unknownRPCEvents.removeFirst(unknownRPCEvents.count - 30) }
        }
    }

    private func handleBackgroundExtensionUI(_ event: JSONValue, slot: RuntimeSlot) {
        guard let method = event["method"]?.stringValue else { return }
        switch method {
        case "select", "confirm", "input", "editor", "set_editor_text":
            if slot === activeRuntimeSlot { cancelRuntimeRetirementLease() }
            deferEvent(event, for: slot)
            if method != "set_editor_text" { notify(.approvalNeeded, session: session(for: slot)) }
        case "setStatus":
            guard let key = event["statusKey"]?.stringValue else { return }
            if let value = event["statusText"]?.stringValue, !ANSI.strip(value).isEmpty {
                let clean = ANSI.strip(value).suffixString(500)
                slot.statuses[key] = clean
                cachedStatuses[key] = clean
                persistence.cacheExtensionStatuses(cachedStatuses)
            } else {
                slot.statuses.removeValue(forKey: key)
            }
            if slot === activeRuntimeSlot, !activePresentationDetached { extensionStatuses = slot.statuses }
        case "setWidget":
            guard let key = event["widgetKey"]?.stringValue else { return }
            let lines = (event["widgetLines"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                .prefix(100).map { $0.suffixString(2_000) }
            if lines.isEmpty { slot.widgets.removeValue(forKey: key) }
            else { slot.widgets[key] = ExtensionWidget(key: key, lines: lines, placement: event["widgetPlacement"]?.stringValue ?? "aboveEditor") }
            if slot === activeRuntimeSlot, !activePresentationDetached { extensionWidgets = slot.widgets }
        case "setTitle":
            slot.windowTitle = event["title"]?.stringValue?.suffixString(500) ?? "Pi Desktop"
            if slot === activeRuntimeSlot, !activePresentationDetached { windowTitle = slot.windowTitle }
        case "notify":
            let style = ToastMessage.Style(rawValue: event["notifyType"]?.stringValue ?? "info") ?? .info
            let message = event["message"]?.stringValue ?? "Pi notification"
            if style == .info { logExtensionNotice(message) }
            else { showToast(message, style: style) }
        default:
            break
        }
    }

    private func deferEvent(_ event: JSONValue, for slot: RuntimeSlot) {
        slot.deferredEvents.append(event.boundedProjection())
        if slot.deferredEvents.count > 32 { slot.deferredEvents.removeFirst(slot.deferredEvents.count - 32) }
    }

    @discardableResult
    private func flushBackgroundOutbox(_ boundary: OutboxEntry.Delivery, slot: RuntimeSlot) -> Bool {
        let due = OutboxPolicy.due(slot.outbox, at: boundary)
        guard !due.isEmpty, slot.runtime.isRunning else { return false }
        slot.outbox = OutboxPolicy.removing(boundary, from: slot.outbox)
        for entry in due {
            let command = entry.delivery == .steer ? "steer" : "follow_up"
            let token = beginOutboxDispatch(for: slot)
            let payload: [String: JSONValue] = [
                "message": .string(ImageAttachment.prompt(text: entry.text, attachments: entry.attachments))
            ]
            slot.runtime.send(type: command, payload: payload) { [weak self] result in
                self?.finishOutboxDispatch(
                    owner: token.owner,
                    dispatch: token.dispatch,
                    delivery: entry.delivery,
                    result: result
                )
            }
        }
        return true
    }

    private func session(for slot: RuntimeSlot) -> SessionSummary? {
        guard let path = slot.sessionPath else { return nil }
        return sessions.first { $0.fileURL.standardizedFileURL.path == path }
    }

    private func retireBackgroundRuntime(_ slot: RuntimeSlot) {
        guard slot !== activeRuntimeSlot, isIdleAndClean(slot) else { return }
        removeParkedReference(to: slot)
        slot.runtime.onEvent = nil
        slot.runtime.onExit = nil
        slot.runtime.stop()
    }

    private func scheduleFinalDurabilityCheck(for slot: RuntimeSlot, retireWhenDone: Bool) {
        finalDurabilityTasks[slot.id]?.cancel()
        guard let path = slot.sessionPath,
              let pending = pendingFinalMessagesByPath[path] else {
            if retireWhenDone { retireBackgroundRuntime(slot) }
            return
        }
        let fileURL = URL(fileURLWithPath: path)
        finalDurabilityTasks[slot.id] = Task { [weak self, weak slot] in
            guard let self, let slot else { return }
            // Pi normally appends before message_end. The retries only cover filesystem/write
            // scheduling jitter and stay bounded to newest-page reads.
            for delay in [0, 100_000_000, 250_000_000, 500_000_000, 1_000_000_000] as [UInt64] {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled else { return }
                if let page = try? await repository.loadNewestConversationPage(from: fileURL),
                   page.messages.contains(where: { self.durableAnswer($0, matches: pending) }) {
                    removeDurableLiveMessages(in: page.messages, path: path)
                    removePendingFinal(path: path)
                    break
                }
            }
            finalDurabilityTasks[slot.id] = nil
            if retireWhenDone { retireBackgroundRuntime(slot) }
        }
    }

    /// Lets tests drive the exact event path a live runtime uses, rather than reaching into
    /// private state and asserting on a shape the runtime never actually produces.
    func handleRPCEventForTesting(_ event: JSONValue) { handleRPCEvent(event) }

    private func handleRPCEvent(_ event: JSONValue) {
        let type = event["type"]?.stringValue ?? "unknown"
        let selected = isSelectedRuntime
        switch type {
        case "agent_start":
            activeRuntimeSlot.outboxDispatches.removeAll()
            cancelRuntimeRetirementLease()
            runtimeState.isStreaming = true
            if runtimeState.phase != .waitingForModel { runtimeState.phase = .working }
        case "agent_settled":
            runtimeState.isStreaming = false
            runtimeState.isRetrying = false
            runtimeState.phase = .idle
            activeCapability = nil
            discardQuestionnaire()
            streamingMessage = nil
            flushOutbox(.followUp)
            // The turn concluded (cleanly or with an in-band error message) with no ambiguity
            // left: nothing about this dispatch is "pending" any more.
            activeRuntimeSlot.promptBeganAt = nil
            activeTurnPrompt = nil
            requestStats()
            let settledSession = activeSession()
            Task {
                if let settledSession { await refreshSummary(for: settledSession) }
                if isApplicationActive,
                   selectedSession?.fileURL.standardizedFileURL.path == settledSession?.fileURL.standardizedFileURL.path {
                    refreshSelectedGit()
                }
            }
            resetRuntimeRetirementLease(for: activeRuntimeSlot)
            scheduleFinalDurabilityCheck(for: activeRuntimeSlot, retireWhenDone: false)
        case "message_update":
            recordRuntimeOutput(for: activeRuntimeSlot)
            guard selected, let partial = event["message"], let parsed = SessionParser.chatMessage(fromAgentMessage: partial) else { return }
            streamingMessage = parsed
        case "message_end":
            recordRuntimeOutput(for: activeRuntimeSlot)
            guard selected, let raw = event["message"], let parsed = SessionParser.chatMessage(fromAgentMessage: raw) else { return }
            upsertMessage(parsed)
            if SessionParser.terminalAssistantStopReasons.contains(raw["stopReason"]?.stringValue ?? "") {
                retainPendingFinal(parsed, for: activeRuntimeSlot)
            }
            streamingMessage = nil
            if parsed.role == .assistant {
                var latest = TokenMetrics(); latest.addUsage(parsed.usage)
                liveMetrics.latestCacheHitPercent = latest.latestCacheHitPercent
            }
            mergeHistoryActivities()
        case "tool_execution_start":
            recordRuntimeOutput(for: activeRuntimeSlot)
            // A question can be waiting in a conversation the user has since navigated away.
            if selected, event["toolName"]?.stringValue?.lowercased() == "ask_user_question" {
                notify(.questionWaiting, session: activeSession())
            }
            guard selected else {
                handleBackgroundRPCEvent(event, slot: activeRuntimeSlot)
                return
            }
            if let callID = event["toolCallId"]?.stringValue,
               let name = event["toolName"]?.stringValue {
                let arguments = event["args"] ?? .object([:])
                activeCapability = CapabilityPresenter.capability(
                    toolName: name,
                    callID: callID,
                    arguments: arguments
                ) ?? activeCapability
                if name.lowercased() == "ask_user_question" {
                    pendingQuestionnaire = QuestionnaireParser.parse(toolCallID: callID, arguments: arguments)
                }
            }
            if let item = ActivityPresenter.activityForToolStart(
                event: event,
                modelName: runtimeState.modelName ?? runtimeState.modelID
            ) { upsertActivity(item) }
        case "tool_execution_update":
            recordRuntimeOutput(for: activeRuntimeSlot)
            guard selected, let id = event["toolCallId"]?.stringValue,
                  let index = activities.firstIndex(where: { $0.id == id || $0.sourceID == id }) else { return }
            ActivityPresenter.applyResult(event["partialResult"], finished: false, to: &activities[index])
        case "tool_execution_end":
            guard let id = event["toolCallId"]?.stringValue else { return }
            // The question belongs to the attached runtime, not to whatever is on screen, so it
            // is retired here even while the user browses another conversation.
            if pendingQuestionnaire?.toolCallID == id { discardQuestionnaire() }
            guard selected else { return }
            if activeCapability?.sourceID == id { activeCapability = nil }
            if let index = activities.firstIndex(where: { $0.id == id || $0.sourceID == id }) {
                ActivityPresenter.applyResult(
                    event["result"],
                    finished: true,
                    endedAt: Date(),
                    isError: event["isError"]?.boolValue == true,
                    to: &activities[index]
                )
            }
        case "queue_update":
            runtimeState.steeringQueue = queueStrings(event["steering"])
            runtimeState.followUpQueue = queueStrings(event["followUp"])
        case "compaction_start": runtimeState.isCompacting = true
        case "compaction_end":
            runtimeState.isCompacting = false
            // Persisted, not just a toast: a compaction failure otherwise vanishes in 3.5s while
            // the composer still looks perfectly usable.
            if let error = event["errorMessage"]?.stringValue {
                runtimeState.lastError = error
                showToast(error, style: .error)
            }
        case "auto_retry_start": runtimeState.isRetrying = true; runtimeState.retryAttempt = event["attempt"]?.intValue
        case "auto_retry_end":
            runtimeState.isRetrying = false
            // Pi's own automatic retries (provider overload/rate limit/5xx) were exhausted:
            // surface it the same durable way as any other runtime failure.
            if event["success"]?.boolValue == false, let error = event["finalError"]?.stringValue {
                runtimeState.lastError = error
                showToast(error, style: .error)
            }
        case "extension_ui_request":
            if selected { handleExtensionUI(event) }
            else { handleBackgroundExtensionUI(event, slot: activeRuntimeSlot) }
        case "extension_error": showToast(event["error"]?.stringValue ?? "A Pi extension failed.", style: .error)
        case "turn_end":
            activeCapability = nil
            discardQuestionnaire()
            // Pi delivers steering at exactly this boundary, so holding it until now costs
            // nothing and keeps it editable for as long as possible.
            flushOutbox(.steer)
        case "message_start", "bash_execution_update": recordRuntimeOutput(for: activeRuntimeSlot)
        case "agent_end", "turn_start", "summarization_retry_scheduled",
             "summarization_retry_attempt_start", "summarization_retry_finished": break
        default:
            unknownRPCEvents.append(event.prettyPrinted(maxLength: PiTheme.unknownPayloadLimit))
            if unknownRPCEvents.count > 30 { unknownRPCEvents.removeFirst(unknownRPCEvents.count - 30) }
        }
    }

    private func queueStrings(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).prefix(50).map { item in
            if let text = item.stringValue { return text.suffixString(1_000) }
            if let message = item["message"]?.stringValue { return message.suffixString(1_000) }
            if let content = item["content"]?.stringValue { return content.suffixString(1_000) }
            return item.prettyPrinted(maxLength: 1_000)
        }
    }

    private func handleQuestionnaireRequest(_ request: ExtensionDialogRequest) -> Bool {
        guard var session = pendingQuestionnaire else { return false }

        if let customText = session.awaitingCustomText, request.method == .input {
            sendExtensionResponse(request: request, value: customText)
            session.awaitingCustomText = nil
            session.nextRPCQuestionIndex += 1
            pendingQuestionnaire = session.nextRPCQuestionIndex >= session.questions.count ? nil : session
            return true
        }

        guard session.questions.indices.contains(session.nextRPCQuestionIndex) else {
            pendingQuestionnaire = nil
            return false
        }
        let question = session.questions[session.nextRPCQuestionIndex]
        guard QuestionnaireRPCBridge.matches(request, question: question) else { return false }
        guard session.submitted else { return false } // The first request owns the inline card.
        sendQuestionnaireResponse(request: request, questionIndex: session.nextRPCQuestionIndex, queued: false)
        return true
    }

    private func sendQuestionnaireResponse(request: ExtensionDialogRequest, questionIndex: Int, queued: Bool) {
        guard var session = pendingQuestionnaire,
              session.questions.indices.contains(questionIndex),
              session.answers.indices.contains(questionIndex),
              let answer = session.answers[questionIndex],
              let plan = QuestionnaireRPCBridge.response(
                question: session.questions[questionIndex],
                answer: answer,
                request: request
              ) else {
            pendingQuestionnaire = nil
            if queued { respondToExtensionDialog(cancelled: true) }
            return
        }

        switch plan {
        case let .value(value):
            sendExtensionResponse(request: request, value: value)
            session.nextRPCQuestionIndex = questionIndex + 1
            pendingQuestionnaire = session.nextRPCQuestionIndex >= session.questions.count ? nil : session
        case let .custom(sentinel, text):
            sendExtensionResponse(request: request, value: sentinel)
            session.awaitingCustomText = text
            pendingQuestionnaire = session
        }
        if queued { advanceDialogQueue() }
    }

    private func handleExtensionUI(_ event: JSONValue) {
        guard let method = event["method"]?.stringValue else { return }
        switch method {
        case "select", "confirm", "input", "editor":
            guard let id = event["id"]?.stringValue, let dialogMethod = ExtensionDialogRequest.Method(rawValue: method) else { return }
            guard !dialogQueue.contains(where: { $0.id == id }) else { return }
            if Self.isLimitsDialog(method: method, title: event["title"]?.stringValue) {
                LimitsReportStore.shared.apply(text: event["prefill"]?.stringValue?.suffixString(20_000) ?? "")
                runtime.sendUncorrelated(.object([
                    "type": .string("extension_ui_response"),
                    "id": .string(id),
                    "cancelled": .bool(true)
                ]))
                return
            }
            let request = ExtensionDialogRequest(
                id: id, method: dialogMethod, title: event["title"]?.stringValue ?? "Pi",
                message: event["message"]?.stringValue?.suffixString(4_000),
                options: Array((event["options"]?.arrayValue?.compactMap(\.stringValue) ?? []).prefix(100)),
                placeholder: event["placeholder"]?.stringValue,
                prefill: event["prefill"]?.stringValue?.suffixString(20_000),
                timeoutMilliseconds: event["timeout"]?.intValue,
                raw: event.boundedFallback(maxLength: PiTheme.unknownPayloadLimit)
            )
            if handleQuestionnaireRequest(request) { return }
            guard dialogQueue.count < Self.dialogQueueLimit else {
                // Never silently swallow a request the extension is waiting on.
                runtime.sendUncorrelated(.object([
                    "type": .string("extension_ui_response"),
                    "id": .string(id),
                    "cancelled": .bool(true)
                ]))
                showToast("Too many extension dialogs are open; one was cancelled.", style: .warning)
                return
            }
            cancelRuntimeRetirementLease()
            dialogQueue.append(request)
            if activeDialog == nil {
                activeDialog = request
                startDialogTimeout(for: request)
                // `handleQuestionnaireRequest` already returned above for an ask_user_question
                // dialog, so anything reaching here is a generic approval/permission prompt.
                notify(.approvalNeeded, session: activeSession())
            }
        case "notify":
            let style = ToastMessage.Style(rawValue: event["notifyType"]?.stringValue ?? "info") ?? .info
            let message = event["message"]?.stringValue ?? "Pi notification"
            // Only actionable notices interrupt the user as a toast (a warning or an error).
            // Purely informational extension chatter — "Ponytail loaded: full" and the like — is
            // routed to the same bounded event log the inspector already shows instead.
            if style == .info {
                logExtensionNotice(message)
            } else {
                showToast(message, style: style)
            }
        case "setStatus":
            guard let key = event["statusKey"]?.stringValue else { return }
            // Extension footers are ANSI-coloured for the TUI; the desktop stores plain text.
            if let value = event["statusText"]?.stringValue, !ANSI.strip(value).isEmpty {
                extensionStatuses[key] = ANSI.strip(value).suffixString(500)
                // Merge, never replace: a runtime that has only reported `mode` so far must not
                // erase the last known `codex-account`, which is what made the status bar fall
                // back to a bare “Codex account” placeholder mid-session.
                cachedStatuses[key] = extensionStatuses[key]
            } else {
                extensionStatuses.removeValue(forKey: key)
            }
            persistence.cacheExtensionStatuses(cachedStatuses)
        case "setWidget":
            guard let key = event["widgetKey"]?.stringValue else { return }
            let lines = (event["widgetLines"]?.arrayValue?.compactMap(\.stringValue) ?? []).prefix(100).map { $0.suffixString(2_000) }
            if lines.isEmpty { extensionWidgets.removeValue(forKey: key) }
            else { extensionWidgets[key] = ExtensionWidget(key: key, lines: lines, placement: event["widgetPlacement"]?.stringValue ?? "aboveEditor") }
        case "setTitle": windowTitle = event["title"]?.stringValue ?? "Pi Desktop"
        case "set_editor_text": draft = event["text"]?.stringValue ?? ""
        default: break
        }
    }

    /// Informational extension chatter is never a toast (see the "notify" case above); it still
    /// needs to be visible somewhere for debugging, so it shares the inspector's bounded event
    /// log rather than being silently dropped.
    private func logExtensionNotice(_ message: String) {
        unknownRPCEvents.append("[notify] \(message)")
        if unknownRPCEvents.count > 30 { unknownRPCEvents.removeFirst(unknownRPCEvents.count - 30) }
    }

    private func handleRuntimeExit(_ error: String?, from slot: RuntimeSlot) {
        slot.outboxDispatches.removeAll()
        if slot === activeRuntimeSlot {
            cancelRuntimeRetirementLease()
            clearExtensionDialogs()
            updateState(for: slot) { state in
                state.isConnected = false
                state.isStreaming = false
                state.isCompacting = false
                state.isRetrying = false
                state.phase = .idle
            }
            activeCapability = nil
            pendingQuestionnaire = nil
            composerOptionsLoading = false
        } else {
            updateState(for: slot) { state in
                state.isConnected = false
                state.isStreaming = false
                state.isCompacting = false
                state.isRetrying = false
                state.phase = .idle
            }
            slot.capability = nil
            slot.questionnaire = nil
            slot.optionsLoading = false
            slot.dialogs.removeAll()
            slot.deferredEvents.removeAll()
            removeParkedReference(to: slot)
        }
        guard let error else { return }

        // Pending prompt rejection is delivered before onExit. Outcome-unknown deliberately
        // leaves this value set, so this remains the one place that can restore it, exactly once.
        if let pending = slot.pendingTurn {
            slot.pendingTurn = nil
            let restored = restoreDraft(text: pending.text, attachments: pending.attachments, origin: pending.origin)
            let message = failureMessage(error, restored: restored, origin: pending.origin)
            updateState(for: slot) { $0.lastError = message }
            showToast(message, style: .error)
        } else {
            updateState(for: slot) { $0.lastError = error }
            showToast(error, style: .error)
        }
    }

    private func upsertMessage(_ message: ChatMessage) {
        if let path = activeRuntimeSlot.sessionPath ?? state(for: activeRuntimeSlot).sessionFile {
            retainLiveMessage(message, path: URL(fileURLWithPath: path).standardizedFileURL.path)
        }
        var updated = messages
        if let index = updated.firstIndex(where: { $0.id == message.id }) { updated[index] = message }
        else if message.role == .user,
                let localIndex = updated.lastIndex(where: { $0.id.hasPrefix("local-") && $0.textContent == message.textContent }) {
            updated[localIndex] = message
        } else { updated.append(message) }
        messages = enforcingLoadedImageBudget(updated)
    }

    private func mergeHistoryActivities() {
        activityProjectionTask?.cancel()
        let snapshot = messages
        let generation = conversationLoadGeneration
        let path = selectedSession?.fileURL.standardizedFileURL.path
        activityProjectionTask = Task { [weak self] in
            guard let self else { return }
            let history = await projectActivities(from: snapshot)
            guard !Task.isCancelled, conversationLoadGeneration == generation,
                  selectedSession?.fileURL.standardizedFileURL.path == path else { return }
            let live = activities.filter { $0.status == .running || $0.status == .waiting }
            var merged = history
            for item in live where !merged.contains(where: {
                $0.id == item.id || (item.agentID != nil && $0.agentID == item.agentID)
            }) { merged.insert(item, at: 0) }
            activities = merged
        }
    }

    private func upsertActivity(_ item: ActivityItem) {
        if let index = activities.firstIndex(where: {
            $0.id == item.id || (item.agentID != nil && $0.agentID == item.agentID)
        }) {
            activities[index] = ActivityPresenter.merged(item, with: activities[index])
        } else {
            activities.insert(item, at: 0)
        }
    }

    private func responseError(_ response: JSONValue) -> String? {
        response["success"]?.boolValue == false ? (response["error"]?.stringValue ?? "Pi rejected the command.") : nil
    }

    private func refreshSummary(for session: SessionSummary) async {
        do {
            let summary = try await repository.refreshSummary(at: session.fileURL, archivedIDs: persistence.state.archivedSessionIDs)
            if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = summary }
        } catch { /* The live conversation remains authoritative; next manual refresh retries. */ }
    }

    private func refreshFolderGitSnapshots() async {
        let paths = Array(Set(sessions.map { $0.cwd.standardizedFileURL.path }))
        let service = gitService
        await withTaskGroup(of: (String, GitSnapshot, GitWorktreeInfo?).self) { group in
            var iterator = paths.makeIterator()
            for _ in 0..<min(3, paths.count) {
                guard let path = iterator.next() else { break }
                group.addTask { await Self.fetchGitState(path, service: service) }
            }
            while let (path, snapshot, worktree) = await group.next() {
                folderGit[path] = snapshot
                folderWorktrees[path] = worktree
                if selectedSession?.cwd.standardizedFileURL.path == path {
                    selectedGit = snapshot
                    selectedWorktree = worktree
                }
                if let next = iterator.next() {
                    group.addTask { await Self.fetchGitState(next, service: service) }
                }
            }
        }
    }

    private func refreshGit(for url: URL) async {
        let normalized = url.standardizedFileURL
        let (_, snapshot, worktree) = await Self.fetchGitState(normalized.path, service: gitService)
        folderGit[normalized.path] = snapshot
        folderWorktrees[normalized.path] = worktree
        let selectedPath = selectedSession?.cwd.standardizedFileURL.path ?? selectedFolder?.standardizedFileURL.path
        if selectedPath == normalized.path {
            selectedGit = snapshot
            selectedWorktree = worktree
        }
    }

    /// Fetches the status snapshot and the (optional) worktree indicator together, in parallel,
    /// so the worktree check (Task 2) never adds serial latency to the existing Git refresh.
    private static func fetchGitState(_ path: String, service: GitStatusProviding) async -> (String, GitSnapshot, GitWorktreeInfo?) {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        async let snapshot = service.snapshot(for: directory)
        async let worktree = service.worktreeInfo(for: directory)
        return await (path, snapshot, worktree)
    }

    private func startGitRefreshLoop() {
        gitRefreshTask?.cancel()
        gitRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                // Awaited, not fire-and-forget: a slow repository cannot pile up refreshes.
                if isApplicationActive { await refreshSelectedGitAndWait() }
            }
        }
    }

    private func cancelConversationLoad() {
        conversationLoadTask?.cancel()
        earlierMessagesTask?.cancel()
        activityProjectionTask?.cancel()
        conversationLoadTask = nil
        earlierMessagesTask = nil
        activityProjectionTask = nil
        isConversationLoading = false
        isLoadingEarlierMessages = false
    }

    private func showToast(_ text: String, style: ToastMessage.Style, sessionPath: String? = nil) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            toast = ToastMessage(text: text, style: style, sessionPath: sessionPath)
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { self?.toast = nil }
        }
    }

    deinit {
        gitRefreshTask?.cancel(); selectedGitTask?.cancel(); conversationLoadTask?.cancel(); earlierMessagesTask?.cancel()
        activityProjectionTask?.cancel()
        toastTask?.cancel(); dialogTimeoutTask?.cancel(); probeTask?.cancel(); draftPersistTask?.cancel()
        prefetchTask?.cancel(); cancelRuntimeRetirement?()
        for task in finalDurabilityTasks.values { task.cancel() }
        probeRuntime?.stop()
        for slot in parkedRuntimes.values { slot.runtime.stop() }
        activeRuntimeSlot.runtime.stop()
    }
}

private extension String {
    func suffixString(_ length: Int) -> String { count <= length ? self : "…" + suffix(length) }
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}
