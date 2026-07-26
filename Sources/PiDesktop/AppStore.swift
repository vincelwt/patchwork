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

    @Published var messages: [ChatMessage] = []
    @Published var streamingMessage: ChatMessage?
    @Published var isConversationLoading = false
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
    private let runtime: PiRuntimeProtocol
    let persistence: AppPersistence
    private let activityPresenter: ActivityPresenting
    /// Creates the short-lived `--no-session` runtime used only to refresh extension statuses.
    /// `nil` disables probing entirely (tests never spawn a process).
    private let probeRuntimeFactory: (() -> PiRuntimeProtocol)?
    private var bootstrapped = false
    private var activeRuntimePath: String?
    private var activeRuntimeCwd: String?
    /// Distinguishes a runtime intentionally opened for New Chat from an attached session in
    /// the same folder; otherwise a new prompt could accidentally resume the previous session.
    private var activeRuntimeStartedForNewChat = false
    private var gitRefreshTask: Task<Void, Never>?
    private var selectedGitTask: Task<Void, Never>?
    private var conversationLoadTask: Task<Void, Never>?
    private var conversationLoadGeneration = 0
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
    /// Last seen state per tracked session path, purely to detect a running→idle transition for
    /// conversations finishing in another terminal.
    private var previousActivityStates: [String: SessionRunState] = [:]
    /// Set for the in-flight "prompt" of the currently attached turn; see `PendingUserTurn`.
    private var activeTurnPrompt: PendingUserTurn?
    /// Bounded in-memory transcript cache (Task 3): never persisted, purely a warm-start cache
    /// for the current app run.
    private let transcriptCache = TranscriptCache()
    private var prefetchTask: Task<Void, Never>?
    private static let prefetchLaunchCount = 8
    private static let prefetchNeighborRadius = 1
    private static let prefetchConcurrency = 3

    init(
        repository: SessionRepositoryProtocol = FileSessionRepository(),
        gitService: GitStatusProviding = GitService(),
        runtime: PiRuntimeProtocol = PiRPCClient(),
        persistence: AppPersistence? = nil,
        activityPresenter: ActivityPresenting = ActivityPresenter(),
        activityMonitor: SessionActivityMonitor? = nil,
        probeRuntimeFactory: (() -> PiRuntimeProtocol)? = nil,
        notificationService: NotificationPresenting? = nil,
        isActiveOverride: Bool? = nil
    ) {
        self.repository = repository
        self.gitService = gitService
        self.runtime = runtime
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

        runtime.onEvent = { [weak self] value in self?.handleRPCEvent(value) }
        runtime.onExit = { [weak self] error in self?.handleRuntimeExit(error) }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshSelectedGit() }
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

    /// Statuses persisted from the last live runtime or probe, shown dimmed when nothing is
    /// attached.
    private var cachedStatuses: [String: String] = [:]

    var selectedSession: SessionSummary? {
        guard case let .session(id) = route else { return nil }
        return sessions.first { $0.id == id }
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
        guard let selectedSession else { return false }
        return selectedSession.fileURL.standardizedFileURL.path == activeRuntimePath
    }

    /// True for either an attached saved conversation or the query-only runtime prepared for a
    /// new Desktop chat. Picker controls use this broader route scope; transcript/session actions
    /// deliberately keep using `isSelectedRuntime`.
    var isCurrentRouteRuntime: Bool { runtimeMatchesCurrentRoute }

    var selectedMetrics: TokenMetrics {
        isSelectedRuntime && runtimeState.isConnected ? liveMetrics : (selectedSession?.metrics ?? TokenMetrics())
    }

    var runningSessionID: String? {
        guard runtimeState.isBusy, let activeRuntimePath else { return nil }
        return sessions.first { $0.fileURL.standardizedFileURL.path == activeRuntimePath }?.id
    }

    // MARK: - Cross-terminal activity

    /// True when this session is working, whether it was started by this app or by any terminal.
    /// The app's own runtime state wins, then the file-based monitor.
    func isRunning(_ session: SessionSummary) -> Bool {
        if runningSessionID == session.id { return true }
        return activityMonitor.activity(forPath: session.fileURL.standardizedFileURL.path)?.state == .running
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

    /// Detects a session transitioning running → idle in another terminal, the one completion
    /// signal the RPC event stream can never see on its own.
    private func handleActivitySnapshot(_ activities: [String: SessionActivity]) {
        for (path, activity) in activities {
            let previous = previousActivityStates.updateValue(activity.state, forKey: path)
            guard previous == .running, activity.state == .idle else { continue }
            guard let session = sessions.first(where: { $0.fileURL.standardizedFileURL.path == path }) else { continue }
            let failed = activity.lastStopReason == "error" || activity.lastStopReason == "aborted"
            notify(failed ? .turnFailed : .turnFinished, session: session, preview: activity.preview)
        }
        if previousActivityStates.count > activities.count {
            previousActivityStates = previousActivityStates.filter { activities[$0.key] != nil }
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
    private func notify(_ trigger: NotificationTrigger, session: SessionSummary?, preview: String? = nil) {
        guard let session else { return }
        let key = session.fileURL.standardizedFileURL.path
        let focusedKey = isApplicationActive ? selectedSession?.fileURL.standardizedFileURL.path : nil
        guard !NotificationGate.isSuppressed(sessionKey: key, focusedSessionKey: focusedKey) else { return }
        guard notificationCoalescer.shouldEmit(sessionKey: key) else { return }
        // A finished turn's body shows the beginning of Pi's actual answer when one is available
        // (a live RPC message, or a cross-terminal heartbeat preview); every other trigger keeps
        // its fixed, specific summary.
        let body = (trigger == .turnFinished ? NotificationPreviewFormatter.format(preview) : nil) ?? trigger.summary
        if isApplicationActive {
            showToast("\(session.displayName): \(body)", style: trigger.toastStyle)
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

    // MARK: - Extension statuses

    var statusModel: ExtensionStatusModel {
        if !extensionStatuses.isEmpty {
            return ExtensionStatusModel(values: extensionStatuses, isLive: true)
        }
        if !probeStatuses.isEmpty {
            return ExtensionStatusModel(values: probeStatuses, isLive: isProbingStatuses)
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
        refreshExtensionStatuses()
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
            syncActivityMonitorPaths()
            if let selectedPath, let replacement = sessions.first(where: { $0.fileURL.standardizedFileURL.path == selectedPath }) {
                route = .session(replacement.id)
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
        route = .newChat
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
        selectedFolder = Self.defaultWorkingFolder(recentFolders: persistence.state.recentFolders)
        refreshSelectedGit()
    }

    func selectSession(_ session: SessionSummary) {
        if let current = selectedSession, current.id != session.id { markRead(current) }
        parkCurrentDraft()
        cancelConversationLoad()
        conversationLoadGeneration += 1
        let generation = conversationLoadGeneration
        route = .session(session.id)
        markRead(session)
        conversationError = nil
        messages.removeAll(keepingCapacity: false)
        streamingMessage = nil
        activities.removeAll(keepingCapacity: false)
        activeCapability = nil
        pendingQuestionnaire = nil
        let draftKey = session.fileURL.standardizedFileURL.path
        draft = draftStore.text(for: draftKey)
        attachments = attachmentsByKey[draftKey] ?? []
        flushDraftPersistence()
        isConversationLoading = true
        DecodedImageCache.purge()
        selectedGit = folderGit[session.cwd.standardizedFileURL.path] ?? .none

        conversationLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let conversation = try await cachedOrFreshConversation(for: session.fileURL)
                try Task.checkCancellation()
                guard conversationLoadGeneration == generation, selectedSession?.id == session.id else { return }
                messages = conversation.messages
                activities = activityPresenter.activities(from: conversation.messages)
                isConversationLoading = false
                await refreshGit(for: session.cwd)
            } catch is CancellationError {
                // Never publish stale cancellation over a newer selection.
            } catch {
                guard conversationLoadGeneration == generation, selectedSession?.id == session.id else { return }
                conversationError = error.localizedDescription
                isConversationLoading = false
            }
        }
        // Warms the neighbours (and keeps the launch-recency set warm) so stepping through the
        // sidebar stays instant too. Additive only — see `schedulePrefetch`.
        schedulePrefetch(around: session)
    }

    /// Reuses a cached parse when the file has not changed since it was cached (Task 3);
    /// otherwise parses fresh and warms the cache for next time. Callers still apply the same
    /// generation/route check to the result regardless of which path was taken.
    private func cachedOrFreshConversation(for fileURL: URL) async throws -> SessionConversation {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return try await repository.loadConversation(from: fileURL)
        }
        let path = fileURL.standardizedFileURL.path
        let fingerprint = SessionFileFingerprint(url: fileURL, values: values)
        if let cached = await transcriptCache.conversation(for: path, fingerprint: fingerprint) { return cached }
        let conversation = try await repository.loadConversation(from: fileURL)
        await transcriptCache.store(conversation, for: path, fingerprint: fingerprint)
        return conversation
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
        guard let session, let index = sessions.firstIndex(where: { $0.id == session.id }) else { return ordered }
        for offset in -Self.prefetchNeighborRadius...Self.prefetchNeighborRadius where offset != 0 {
            let neighborIndex = index + offset
            guard sessions.indices.contains(neighborIndex) else { continue }
            ordered.append(sessions[neighborIndex].fileURL)
        }
        return ordered
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
        let path = url.standardizedFileURL.path
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let fingerprint = SessionFileFingerprint(url: url, values: values)
        if await cache.conversation(for: path, fingerprint: fingerprint) != nil { return } // Already warm.
        guard let conversation = try? await repository.loadConversation(from: url) else { return }
        guard !Task.isCancelled else { return }
        await cache.store(conversation, for: path, fingerprint: fingerprint)
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
        selectedFolder = url.standardizedFileURL
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
        activityMonitor.setTrackedPaths(sessions.map { $0.fileURL.standardizedFileURL.path })
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

    func submitDraft(delivery: DeliveryMode = .automatic) {
        let text = Self.sanitizedMessage(draft)
        guard !text.isEmpty || !attachments.isEmpty else { return }

        let cwd: URL
        let sessionPath: URL?
        if let selectedSession { cwd = selectedSession.cwd; sessionPath = selectedSession.fileURL }
        else if let selectedFolder { cwd = selectedFolder; sessionPath = nil }
        else { showToast("Choose a working folder first", style: .warning); return }

        if runtime.isRunning, runtimeState.isBusy,
           activeRuntimePath != sessionPath?.standardizedFileURL.path {
            showToast("Pi is working in another conversation. Finish or stop it first.", style: .warning)
            return
        }

        let sentText = draft
        let sentAttachments = attachments
        let origin = DraftOrigin(route: route, sessionPath: sessionPath?.standardizedFileURL.path)
        draft = ""
        attachments = []
        ensureRuntime(cwd: cwd, sessionPath: sessionPath) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                dispatchMessage(text, originalDraft: sentText, attachments: sentAttachments,
                                delivery: delivery, cwd: cwd)
            case let .failure(error):
                let restored = restoreDraft(text: sentText, attachments: sentAttachments, origin: origin)
                showToast(failureMessage(error.localizedDescription, restored: restored, origin: origin), style: .error)
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
            if case let .failure(error) = result {
                showToast(error.localizedDescription, style: .error)
                return
            }
            runtime.send(type: "prompt", payload: ["message": .string(clean)]) { [weak self] result in
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
        guard runtime.isRunning else {
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
            cachedStatuses = probeStatuses
            persistence.cacheExtensionStatuses(probeStatuses)
        }
    }

    func abort() {
        guard runtime.isRunning, runtimeState.isStreaming else { return }
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

    /// Starts or attaches the route's RPC runtime and loads picker choices. These are query-only
    /// commands: opening a composer never sends a provider prompt.
    func prepareComposerOptions() {
        let cwd = selectedSession?.cwd ?? selectedFolder
        guard let cwd else { return }
        let sessionPath = selectedSession?.fileURL
        composerOptionsLoading = true
        ensureRuntime(cwd: cwd, sessionPath: sessionPath) { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                composerOptionsLoading = false
                return
            }
            requestComposerOptions()
        }
    }

    func setModel(_ model: AvailableModel) {
        guard runtimeMatchesCurrentRoute else { return }
        runtime.send(type: "set_model", payload: [
            "provider": .string(model.provider),
            "modelId": .string(model.modelID)
        ]) { [weak self] result in
            guard let self, runtimeMatchesCurrentRoute else { return }
            switch result {
            case let .success(response) where responseError(response) == nil:
                let value = response["data"]
                runtimeState.modelID = value?["id"]?.stringValue ?? model.modelID
                runtimeState.modelName = value?["name"]?.stringValue ?? model.name
                runtimeState.provider = value?["provider"]?.stringValue ?? model.provider
                refreshRuntimeStateAfterPickerChange()
            case let .success(response): showToast(responseError(response) ?? "Pi rejected the model.", style: .error)
            case let .failure(error): showToast(error.localizedDescription, style: .error)
            }
        }
    }

    func setThinkingLevel(_ level: String) {
        guard runtimeMatchesCurrentRoute, availableThinkingLevels.contains(level) else { return }
        runtime.send(type: "set_thinking_level", payload: ["level": .string(level)]) { [weak self] result in
            guard let self, runtimeMatchesCurrentRoute else { return }
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
        runtime.send(type: "cycle_model", payload: [:]) { [weak self] result in
            guard case let .success(response) = result, self?.responseError(response) == nil else { return }
            if let model = response["data"]?["model"] {
                self?.runtimeState.modelID = model["id"]?.stringValue
                self?.runtimeState.modelName = model["name"]?.stringValue
                self?.runtimeState.provider = model["provider"]?.stringValue
            }
            self?.runtimeState.thinkingLevel = response["data"]?["thinkingLevel"]?.stringValue ?? self?.runtimeState.thinkingLevel
            self?.requestComposerOptions()
        }
    }

    func cycleThinkingLevel() {
        guard runtimeMatchesCurrentRoute else { return }
        runtime.send(type: "cycle_thinking_level", payload: [:]) { [weak self] result in
            guard case let .success(response) = result, self?.responseError(response) == nil else { return }
            self?.runtimeState.thinkingLevel = response["data"]?["level"]?.stringValue ?? self?.runtimeState.thinkingLevel
        }
    }

    private var runtimeMatchesCurrentRoute: Bool {
        guard runtime.isRunning else { return false }
        if let selectedSession {
            return activeRuntimePath == selectedSession.fileURL.standardizedFileURL.path
        }
        guard let selectedFolder else { return false }
        return activeRuntimeStartedForNewChat
            && activeRuntimeCwd == selectedFolder.standardizedFileURL.path
    }

    private func requestComposerOptions() {
        guard runtimeMatchesCurrentRoute else { composerOptionsLoading = false; return }
        composerOptionsLoading = true
        runtime.send(type: "get_available_models", payload: [:]) { [weak self] result in
            guard let self, runtimeMatchesCurrentRoute else { return }
            if case let .success(response) = result, responseError(response) == nil {
                availableModels = AvailableModel.parse(response["data"]?["models"])
            }
            requestThinkingOptions()
        }
    }

    private func requestThinkingOptions() {
        runtime.send(type: "get_available_thinking_levels", payload: [:]) { [weak self] result in
            guard let self, runtimeMatchesCurrentRoute else { return }
            if case let .success(response) = result, responseError(response) == nil {
                availableThinkingLevels = RuntimePickerState.thinkingLevels(from: response["data"]?["levels"])
                runtimeState.thinkingLevel = RuntimePickerState.selectedThinkingLevel(
                    in: availableThinkingLevels,
                    current: runtimeState.thinkingLevel
                )
            }
            composerOptionsLoading = false
        }
    }

    private func refreshRuntimeStateAfterPickerChange() {
        runtime.send(type: "get_state", payload: [:]) { [weak self] result in
            guard let self, runtimeMatchesCurrentRoute else { return }
            if case let .success(response) = result, responseError(response) == nil { applyState(response["data"]) }
            requestThinkingOptions()
        }
    }

    func setQueueMode(steering: Bool, mode: String) {
        guard isSelectedRuntime, ["all", "one-at-a-time"].contains(mode) else { return }
        let command = steering ? "set_steering_mode" : "set_follow_up_mode"
        runtime.send(type: command, payload: ["mode": .string(mode)]) { [weak self] result in
            guard let self else { return }
            if case let .success(response) = result, responseError(response) == nil {
                if steering { runtimeState.steeringMode = mode } else { runtimeState.followUpMode = mode }
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
        let requestedPath = session.fileURL.standardizedFileURL.path
        if runtimeState.isBusy {
            let location = activeRuntimePath == requestedPath ? "this conversation" : "another conversation"
            showToast("Pi is working in \(location). Rename when it becomes idle.", style: .warning)
            return
        }
        ensureRuntime(cwd: session.cwd, sessionPath: session.fileURL) { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                if case let .failure(error) = result { showToast(error.localizedDescription, style: .error) }
                return
            }
            runtime.send(type: "set_session_name", payload: ["name": .string(clean)]) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(response) where responseError(response) == nil:
                    runtimeState.sessionName = clean
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

    private func ensureRuntime(cwd: URL, sessionPath: URL?, completion: @escaping (Result<Void, Error>) -> Void) {
        // The launch-time status probe is intentionally ephemeral. Never let it race a real
        // route runtime: simultaneous Pi extension startup can delay the route's first get_state
        // long enough to make model/thinking controls appear unavailable in GUI launches.
        if probeRuntime != nil { finishProbe() }

        let requestedPath = sessionPath?.standardizedFileURL.path
        let matches = runtime.isRunning && ((requestedPath != nil && activeRuntimePath == requestedPath) ||
            (requestedPath == nil && activeRuntimeStartedForNewChat
                && activeRuntimeCwd == cwd.standardizedFileURL.path))
        if matches { completion(.success(())); return }
        if runtimeState.isBusy { completion(.failure(PiRPCError.processExited("The current Pi run is still working."))); return }

        clearExtensionDialogs()
        if runtime.isRunning { runtime.stop() }
        runtimeState = RuntimeState()
        // A fresh attach means whatever the previous runtime was doing has fully ended one way
        // or another; a stale pending turn from it must never be offered for retry here.
        activeTurnPrompt = nil
        liveMetrics = TokenMetrics()
        availableModels.removeAll()
        availableThinkingLevels = ["off"]
        composerOptionsLoading = false
        activeCapability = nil
        extensionStatuses.removeAll()
        extensionWidgets.removeAll()
        activeRuntimePath = requestedPath
        activeRuntimeCwd = cwd.standardizedFileURL.path
        activeRuntimeStartedForNewChat = requestedPath == nil

        do {
            try runtime.start(cwd: cwd, sessionPath: sessionPath)
            runtimeState.isConnected = true
        } catch {
            runtimeState.lastError = error.localizedDescription
            activeRuntimePath = nil
            activeRuntimeCwd = nil
            activeRuntimeStartedForNewChat = false
            completion(.failure(error))
            return
        }

        runtime.send(type: "get_state", payload: [:]) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(response):
                if let error = responseError(response) {
                    runtimeState.lastError = error
                    runtimeState.isConnected = false
                    runtime.stop()
                    activeRuntimePath = nil
                    activeRuntimeCwd = nil
                    activeRuntimeStartedForNewChat = false
                    completion(.failure(PiRPCError.processExited(error)))
                    return
                }
                applyState(response["data"])
                hydrateRuntimeConversationIfNeeded()
                requestStats()
                completion(.success(()))
            case let .failure(error):
                runtimeState.lastError = error.localizedDescription
                runtimeState.isConnected = false
                runtime.stop()
                activeRuntimePath = nil
                activeRuntimeCwd = nil
                activeRuntimeStartedForNewChat = false
                completion(.failure(error))
            }
        }
    }

    private func dispatchMessage(
        _ text: String,
        originalDraft: String,
        attachments sentAttachments: [ImageAttachment],
        delivery: DeliveryMode,
        cwd: URL
    ) {
        let command: String
        switch delivery {
        case .steer: command = "steer"
        case .followUp: command = "follow_up"
        case .automatic: command = runtimeState.isStreaming ? "steer" : "prompt"
        }

        ensureProvisionalSession(cwd: cwd, prompt: text)
        // A new chat is promoted to a session route in place, and that is still the same
        // composer, so the origin follows the promotion instead of being treated as a switch.
        let origin = DraftOrigin(route: route, sessionPath: selectedSession?.fileURL.standardizedFileURL.path)
        var optimisticID: String?
        if case .session = route, command == "prompt" {
            let id = "local-\(UUID().uuidString)"
            optimisticID = id
            messages.append(ChatMessage(
                id: id, role: .user,
                blocks: [MessageBlock(id: UUID().uuidString, kind: .text(text))] + sentAttachments.map {
                    let image = ImagePayload(id: $0.id.uuidString, data: $0.data, mimeType: $0.mimeType, fileName: $0.fileName)
                    return MessageBlock(id: image.id, kind: .image(image))
                },
                timestamp: Date(), raw: .null
            ))
        }
        // The message that starts a turn is the one a crash mid-turn must be able to hand back
        // for a one-click retry; see `PendingUserTurn` and `handleRuntimeExit`.
        if command == "prompt" {
            activeTurnPrompt = PendingUserTurn(origin: origin, text: originalDraft, attachments: sentAttachments)
        }

        var payload: [String: JSONValue] = ["message": .string(text)]
        if !sentAttachments.isEmpty { payload["images"] = .array(sentAttachments.map(\.rpcValue)) }
        let wasStreaming = runtimeState.isStreaming
        if command == "prompt" { runtimeState.isStreaming = true }

        runtime.send(type: command, payload: payload) { [weak self] result in
            guard let self else { return }
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
            // An unconfirmed side-effecting command may already have reached Pi. Rolling the
            // draft back here would let the user resend and prompt Pi twice, so `activeTurnPrompt`
            // (when this was the "prompt") is deliberately left set: only a later, definite signal
            // — the turn settling, or the process actually exiting — ever resolves it from here on.
            if isOutcomeUnknown {
                showToast(errorText, style: .warning)
                return
            }
            if command == "prompt" { runtimeState.isStreaming = wasStreaming; activeTurnPrompt = nil }
            if let optimisticID { messages.removeAll { $0.id == optimisticID } }
            let restored = restoreDraft(text: originalDraft, attachments: sentAttachments, origin: origin)
            showToast(failureMessage(errorText, restored: restored, origin: origin), style: .error)
        }
    }

    /// Restores a failed submission only into the composer it came from, and reports whether it
    /// did. When the user has moved on, the current draft is left completely untouched.
    @discardableResult
    private func restoreDraft(text: String, attachments sent: [ImageAttachment], origin: DraftOrigin) -> Bool {
        let currentPath = selectedSession?.fileURL.standardizedFileURL.path
        guard DraftOrigin.shouldRestoreDraft(origin: origin, currentRoute: route, currentSessionPath: currentPath) else {
            return false
        }
        draft = DraftRecovery.restoredText(sent: text, current: draft)
        attachments = DraftRecovery.restoredAttachments(sent: sent, current: attachments)
        return true
    }

    private func failureMessage(_ error: String, restored: Bool, origin: DraftOrigin) -> String {
        restored ? error : "\(origin.conversationDescription.capitalizedFirst): \(error)"
    }

    private func ensureProvisionalSession(cwd: URL, prompt: String) {
        guard case .newChat = route, let sessionID = runtimeState.sessionID, let file = runtimeState.sessionFile else { return }
        let url = URL(fileURLWithPath: file)
        let title = prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(74)
        var provisional = SessionSummary(
            id: sessionID, fileURL: url, cwd: cwd, createdAt: Date(), modifiedAt: Date(),
            name: title.isEmpty ? "New conversation" : String(title), preview: prompt,
            messageCount: 0, metrics: TokenMetrics()
        )
        provisional.prepareSearchKey()
        sessions.insert(provisional, at: 0)
        route = .session(sessionID)
        activeRuntimePath = url.standardizedFileURL.path
        activeRuntimeStartedForNewChat = false
        messages = []
        activities = []
    }

    private func hydrateRuntimeConversationIfNeeded() {
        guard isSelectedRuntime else { return }
        runtime.send(type: "get_messages", payload: [:]) { [weak self] result in
            guard let self, case let .success(response) = result, responseError(response) == nil else { return }
            let loaded = SessionParser.chatMessages(fromRPCMessages: response["data"]?["messages"])
            if !loaded.isEmpty { messages = loaded; activities = activityPresenter.activities(from: loaded) }
        }
    }

    private func requestStats() {
        guard runtime.isRunning else { return }
        runtime.send(type: "get_session_stats", payload: [:]) { [weak self] result in
            guard let self, case let .success(response) = result, responseError(response) == nil,
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
            metrics.latestCacheHitPercent = liveMetrics.latestCacheHitPercent
            liveMetrics = metrics
        }
    }

    private func applyState(_ data: JSONValue?) {
        guard let data else { return }
        runtimeState.isConnected = true
        runtimeState.isStreaming = data["isStreaming"]?.boolValue ?? false
        runtimeState.isCompacting = data["isCompacting"]?.boolValue ?? false
        runtimeState.thinkingLevel = data["thinkingLevel"]?.stringValue
        runtimeState.sessionFile = data["sessionFile"]?.stringValue
        runtimeState.sessionID = data["sessionId"]?.stringValue
        runtimeState.sessionName = data["sessionName"]?.stringValue
        runtimeState.modelID = data["model"]?["id"]?.stringValue
        runtimeState.modelName = data["model"]?["name"]?.stringValue
        runtimeState.provider = data["model"]?["provider"]?.stringValue
        runtimeState.steeringMode = data["steeringMode"]?.stringValue ?? runtimeState.steeringMode
        runtimeState.followUpMode = data["followUpMode"]?.stringValue ?? runtimeState.followUpMode
        runtimeState.steeringQueue = queueStrings(data["steeringQueue"] ?? data["steering"])
        runtimeState.followUpQueue = queueStrings(data["followUpQueue"] ?? data["followUp"])
        if let path = runtimeState.sessionFile { activeRuntimePath = URL(fileURLWithPath: path).standardizedFileURL.path }
    }

    private func handleRPCEvent(_ event: JSONValue) {
        let type = event["type"]?.stringValue ?? "unknown"
        let selected = isSelectedRuntime
        switch type {
        case "agent_start": runtimeState.isStreaming = true
        case "agent_settled":
            runtimeState.isStreaming = false
            runtimeState.isRetrying = false
            activeCapability = nil
            streamingMessage = nil
            // The turn concluded (cleanly or with an in-band error message) with no ambiguity
            // left: nothing about this dispatch is "pending" any more.
            activeTurnPrompt = nil
            requestStats()
            notify(
                messages.last?.isError == true ? .turnFailed : .turnFinished,
                session: activeSession(),
                preview: messages.last?.textContent
            )
            Task { await refreshSelectedSummary(); if isApplicationActive { refreshSelectedGit() } }
        case "message_update":
            guard selected, let partial = event["message"], let parsed = SessionParser.chatMessage(fromAgentMessage: partial) else { return }
            streamingMessage = parsed
        case "message_end":
            guard selected, let raw = event["message"], let parsed = SessionParser.chatMessage(fromAgentMessage: raw) else { return }
            upsertMessage(parsed)
            streamingMessage = nil
            if parsed.role == .assistant {
                var latest = TokenMetrics(); latest.addUsage(parsed.usage)
                liveMetrics.latestCacheHitPercent = latest.latestCacheHitPercent
            }
            mergeHistoryActivities()
        case "tool_execution_start":
            // A question can be waiting in a conversation the user has since navigated away
            // from; that must still notify even though its capability/questionnaire UI state
            // (below) is only ever tracked for the selected runtime.
            if event["toolName"]?.stringValue?.lowercased() == "ask_user_question" {
                notify(.questionWaiting, session: activeSession())
            }
            guard selected else { return }
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
            if let item = ActivityPresenter.activityForToolStart(event: event) { upsertActivity(item) }
        case "tool_execution_update":
            guard selected, let id = event["toolCallId"]?.stringValue,
                  let index = activities.firstIndex(where: { $0.id == id || $0.sourceID == id }) else { return }
            activities[index].detail = extractResultText(event["partialResult"])?.suffixString(900)
        case "tool_execution_end":
            guard selected, let id = event["toolCallId"]?.stringValue else { return }
            if activeCapability?.sourceID == id { activeCapability = nil }
            if pendingQuestionnaire?.toolCallID == id { pendingQuestionnaire = nil }
            if let index = activities.firstIndex(where: { $0.id == id || $0.sourceID == id }) {
                activities[index].status = event["isError"]?.boolValue == true ? .failed : .succeeded
                activities[index].endedAt = Date()
                activities[index].detail = extractResultText(event["result"])?.suffixString(900)
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
        case "extension_ui_request": handleExtensionUI(event)
        case "extension_error": showToast(event["error"]?.stringValue ?? "A Pi extension failed.", style: .error)
        case "turn_end":
            activeCapability = nil
            pendingQuestionnaire = nil
        case "agent_end", "turn_start", "message_start", "bash_execution_update",
             "summarization_retry_scheduled", "summarization_retry_attempt_start", "summarization_retry_finished": break
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
        guard session.submitted else { return false } // The first request owns the native sheet.
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
            } else {
                extensionStatuses.removeValue(forKey: key)
            }
            cachedStatuses = extensionStatuses
            persistence.cacheExtensionStatuses(extensionStatuses)
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

    private func handleRuntimeExit(_ error: String?) {
        clearExtensionDialogs()
        runtimeState.isConnected = false
        runtimeState.isStreaming = false
        runtimeState.isCompacting = false
        runtimeState.isRetrying = false
        activeCapability = nil
        pendingQuestionnaire = nil
        composerOptionsLoading = false
        guard let error else { return }

        // A "prompt" whose outcome was never resolved is handled specially: Pi may already have
        // accepted the message before dying, so this hands it back for a one-click resend rather
        // than silently losing it (the `DraftRecovery` intent). `dispatchMessage`'s own
        // completion always runs first for the very same crash — this fires from `onExit`, which
        // is queued after `rejectPending` has already delivered to every pending callback — and
        // only ever leaves `activeTurnPrompt` set when it could not tell whether Pi had received
        // the message. So this is the single place that ever acts on it, and only once: a crash
        // can never restore the same text into the draft twice.
        if let pending = activeTurnPrompt {
            activeTurnPrompt = nil
            let restored = restoreDraft(text: pending.text, attachments: pending.attachments, origin: pending.origin)
            let message = failureMessage(error, restored: restored, origin: pending.origin)
            runtimeState.lastError = message
            showToast(message, style: .error)
        } else {
            runtimeState.lastError = error
            showToast(error, style: .error)
        }
    }

    private func upsertMessage(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
        else if message.role == .user,
                let localIndex = messages.lastIndex(where: { $0.id.hasPrefix("local-") && $0.textContent == message.textContent }) {
            messages[localIndex] = message
        } else { messages.append(message) }
    }

    private func mergeHistoryActivities() {
        let history = activityPresenter.activities(from: messages)
        let live = activities.filter { $0.status == .running || $0.status == .waiting }
        var merged = history
        for item in live where !merged.contains(where: { $0.id == item.id }) { merged.insert(item, at: 0) }
        activities = merged
    }

    private func upsertActivity(_ item: ActivityItem) {
        if let index = activities.firstIndex(where: { $0.id == item.id }) { activities[index] = item }
        else { activities.insert(item, at: 0) }
    }

    private func extractResultText(_ result: JSONValue?) -> String? {
        result?["content"]?.arrayValue?.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
    }

    private func responseError(_ response: JSONValue) -> String? {
        response["success"]?.boolValue == false ? (response["error"]?.stringValue ?? "Pi rejected the command.") : nil
    }

    private func refreshSelectedSummary() async {
        guard let session = selectedSession else { return }
        await refreshSummary(for: session)
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
        await withTaskGroup(of: (String, GitSnapshot).self) { group in
            var iterator = paths.makeIterator()
            for _ in 0..<min(3, paths.count) {
                guard let path = iterator.next() else { break }
                group.addTask { (path, await service.snapshot(for: URL(fileURLWithPath: path, isDirectory: true))) }
            }
            while let (path, snapshot) = await group.next() {
                folderGit[path] = snapshot
                if selectedSession?.cwd.standardizedFileURL.path == path { selectedGit = snapshot }
                if let next = iterator.next() {
                    group.addTask { (next, await service.snapshot(for: URL(fileURLWithPath: next, isDirectory: true))) }
                }
            }
        }
    }

    private func refreshGit(for url: URL) async {
        let normalized = url.standardizedFileURL
        let snapshot = await gitService.snapshot(for: normalized)
        folderGit[normalized.path] = snapshot
        let selectedPath = selectedSession?.cwd.standardizedFileURL.path ?? selectedFolder?.standardizedFileURL.path
        if selectedPath == normalized.path { selectedGit = snapshot }
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
        conversationLoadTask = nil
        isConversationLoading = false
    }

    private func showToast(_ text: String, style: ToastMessage.Style) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = ToastMessage(text: text, style: style) }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { self?.toast = nil }
        }
    }

    deinit {
        gitRefreshTask?.cancel(); selectedGitTask?.cancel(); conversationLoadTask?.cancel()
        toastTask?.cancel(); dialogTimeoutTask?.cancel(); probeTask?.cancel(); draftPersistTask?.cancel()
        prefetchTask?.cancel()
        probeRuntime?.stop(); runtime.stop()
    }
}

private extension String {
    func suffixString(_ length: Int) -> String { count <= length ? self : "…" + suffix(length) }
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}
