import AppKit
import Combine
import Foundation
import PiDeskKit
import SwiftUI

/// The destructive archive the user is deciding on, with the fresh linked-automation count.
struct ArchiveConfirmation: Identifiable, Equatable {
    let sessionID: String
    let automationCount: Int
    var id: String { sessionID }

    var message: String {
        automationCount == 1
            ? "This conversation has an automation tied to it. Archiving will also delete the automation."
            : "This conversation has \(automationCount) automations tied to it. Archiving will also delete them."
    }

    var actionTitle: String {
        automationCount == 1 ? "Archive and Delete Automation" : "Archive and Delete Automations"
    }
}

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

private enum ManagedWriterState: Sendable {
    case none
    case heartbeat
    case fileFallback
}

/// One independent agent process plus the route-visible state that must follow it when the user
/// switches conversations mid-turn. Idle processes are still reused; only live work is parked.
private final class RuntimeSlot {
    let id = UUID()
    let runtime: AgentRuntimeProtocol
    /// Which agent this process is. Read from the runtime so a slot can never disagree with the
    /// binary actually running behind it.
    var agent: AgentKind { runtime.agent }
    var capabilities: AgentCapabilities { runtime.agent.capabilities }
    /// The agent's current operating mode (Pi `/mode`, Codex sandbox, Claude permission mode).
    var mode: String?
    var sessionPath: String?
    var cwd: String?
    var startedForNewChat = false
    var state = RuntimeState()
    var metrics = TokenMetrics()
    var models: [AvailableModel] = []
    var thinkingLevels = ["off"]
    /// This agent's slash commands / skills, bounded by `AgentCommand.parse`.
    var commands: [AgentCommand] = []
    var commandsLoading = false
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
    var outboxPromptPreflighting = false
    var outboxPromptAbortRequested = false
    var promptPreflightID: UUID?
    var pendingStartupPrompts = 0
    var deferredEvents: [JSONValue] = []
    var connectivityRetryAbortRequested = false
    var connectivityResumeCancelled = false
    var connectivityResumePreparing = false
    var connectivityResumeInFlight = false
    var providerRetryPending = false
    var providerRetryAttempt = 0
    var providerRetryID: UUID?
    var cancelProviderRetry: (() -> Void)?
    var isReady = false
    var isStarting = false
    var startupBeganAt: Date?
    var promptBeganAt: Date?
    var readyWaiters: [(Result<RuntimeSlot, Error>) -> Void] = []
    var managedProcessIDs: Set<String> = []
    var managedProcessStartedAt: Date?
    var isSuperseded = false

    init(runtime: AgentRuntimeProtocol) { self.runtime = runtime }
}

/// Runtime routes are keyed by agent as well as location: a parked Pi process for a folder is
/// not a usable runtime for a Codex conversation in the same folder.
private enum RuntimeRouteKey: Hashable {
    case session(String)
    case newChat(AgentKind, String)
}

typealias RuntimeRetirementScheduler = (
    _ delay: TimeInterval,
    _ action: @escaping @MainActor () -> Void
) -> () -> Void

typealias ManagedTurnResumer = @MainActor (
    _ sessionPath: String,
    _ instruction: String,
    _ clientID: String
) async throws -> Void

typealias ManagedTurnWriterProbe = @MainActor (_ sessionPath: String) async -> Bool

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

/// High-frequency partial answers observed only by the transcript leaf.
@MainActor
final class TranscriptStreamModel: ObservableObject {
    @Published fileprivate(set) var message: ChatMessage?
}

/// High-frequency process and subagent progress observed only by the inspector.
@MainActor
final class RuntimeActivityModel: ObservableObject {
    @Published fileprivate(set) var items: [ActivityItem] = []
}

@MainActor
final class AppStore: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var route: AppRoute = .newChat
    @Published var searchText = ""
    @Published var isScanning = false
    @Published var scanError: String?

    @Published var messages: [ChatMessage] = [] {
        didSet {
            transcriptRevision &+= 1
            pullRequestLinkKey = -1
        }
    }
    let transcriptStream = TranscriptStreamModel()
    var streamingMessage: ChatMessage? {
        get { transcriptStream.message }
        set {
            guard transcriptStream.message != newValue else { return }
            transcriptRevision &+= 1
            transcriptStream.message = newValue
        }
    }
    /// Plain revision counter for memoizing transcript projection. Stream changes publish only
    /// through `transcriptStream`, while settled `messages` still invalidate the shared store.
    private(set) var transcriptRevision = 0
    private var pullRequestLinkKey = -1
    private var cachedPullRequestLink: URL?
    /// The pull request this conversation opened, for the header's quick link. Memoized on
    /// message count and explicitly invalidated when `messages` is replaced: streaming deltas
    /// land in `streamingMessage`, so a token burst never rescans the whole transcript.
    var pullRequestLink: URL? {
        if pullRequestLinkKey != messages.count {
            pullRequestLinkKey = messages.count
            cachedPullRequestLink = PullRequestLink.latest(in: messages)
        }
        return cachedPullRequestLink
    }
    /// Streaming deltas are coalesced to this cadence before publishing: each publish reprojects
    /// the whole loaded transcript, and raw `message_update` bursts arrive far faster than the
    /// user can read. Parsing is deferred with the publish, so skipped deltas cost nothing.
    static let streamingPublishInterval: TimeInterval = 0.08
    private var streamingPublishTask: Task<Void, Never>?
    private var pendingStreamingUpdate: JSONValue?
    private var lastStreamingPublish = Date.distantPast
    @Published var isConversationLoading = false
    @Published private(set) var isLoadingEarlierMessages = false
    @Published private(set) var isLoadingNewerMessages = false
    @Published private(set) var hasEarlierMessages = false
    @Published private(set) var hasNewerMessages = false
    @Published private(set) var isBrowsingEarlierHistory = false
    @Published private(set) var latestScrollRequest = 0
    @Published private(set) var conversationHistoryLimitReached = false
    @Published private(set) var initialScrollTargetMessageID: String?
    @Published var conversationError: String?

    /// Composer edits have their own observation scope so a key-repeat burst does not invalidate
    /// the transcript, sidebar, inspector, and menu-bar trees.
    let composer = ComposerModel()
    var draft: String {
        get { composer.content.text }
        set {
            var value = composer.content
            value.text = newValue
            guard value != composer.content else { return }
            composer.content = value
        }
    }
    var attachments: [ImageAttachment] {
        get { composer.content.attachments }
        set {
            var value = composer.content
            value.attachments = newValue
            guard value != composer.content else { return }
            composer.content = value
        }
    }
    @Published var selectedFolder: URL?
    /// The app-created worktree a pending new chat will run in, plus the folder it was cut from
    /// so unchecking the box can go back. Both clear once the chat is sent (the session adopts
    /// the worktree) or a different new chat starts (the unused worktree is removed).
    @Published private(set) var newChatWorktree: URL?
    private var newChatWorktreeOrigin: URL?
    /// Once submitted, navigation may hide this selection but must never delete its live cwd.
    private var newChatWorktreeSubmitted = false
    @Published var runtimeState = RuntimeState()
    /// Agents whose executable resolved at launch, in a stable order. Empty means nothing is
    /// installed, which the new-chat surface reports instead of failing at spawn time.
    /// Excludes any the user has switched off; `detectedAgents` is the unfiltered list.
    @Published private(set) var installedAgents: [AgentKind] = []
    /// Every agent found on this machine, whether or not it is switched on. Settings needs both
    /// so a disabled agent is still shown as a thing that exists.
    @Published private(set) var detectedAgents: [AgentKind] = []
    /// Whether the sidebar also lists conversations this app did not start. Off by default: an
    /// agent's directory holds work from terminals, other desktop apps, and automations, and
    /// driving one of those means two processes writing one transcript.
    @Published private(set) var showsForeignConversations = false
    /// How many discovered conversations the ownership filter is currently hiding, so the
    /// sidebar can offer to show them rather than silently swallowing history.
    @Published private(set) var hiddenForeignCount = 0

    /// Agents the user switched off. Their conversations stop being scanned and they stop being
    /// offered for a new chat; nothing about their history is touched.
    @Published private(set) var disabledAgents: Set<AgentKind> = []
    /// The agent a new conversation will use. Persisted so the choice survives relaunch.
    @Published var newChatAgent: AgentKind = .pi {
        didSet {
            guard newChatAgent != oldValue else { return }
            persistence.updateState { $0.lastAgent = newChatAgent.rawValue }
            // Options are agent-specific, so anything cached for the previous agent is wrong now.
            if route == .newChat { resetRuntimeOptionsForNewChat() }
        }
    }
    @Published private(set) var isOffline = false
    @Published private(set) var isCaffeinated = false
    @Published var liveMetrics = TokenMetrics()
    @Published private(set) var availableModels: [AvailableModel] = []
    @Published private(set) var availableThinkingLevels: [String] = ["off"]
    @Published private(set) var composerOptionsLoading = false
    /// The attached runtime's slash commands, for the composer palette.
    @Published private(set) var availableCommands: [AgentCommand] = []
    @Published private(set) var commandsLoading = false
    @Published private(set) var activeCapability: ToolCapability?
    @Published private(set) var pendingQuestionnaire: QuestionnaireSession?

    @Published var folderGit: [String: GitSnapshot] = [:]
    @Published var selectedGit = GitSnapshot.none
    /// Present only for directories that resolve to linked Git worktrees. The selected entry may
    /// follow an explicit tool cwd/edit path away from the session's original cwd.
    @Published var folderWorktrees: [String: GitWorktreeInfo] = [:]
    @Published var selectedWorktree: GitWorktreeInfo?
    let runtimeActivities = RuntimeActivityModel()
    var activities: [ActivityItem] {
        get { runtimeActivities.items }
        set { runtimeActivities.items = newValue }
    }
    @Published var extensionStatuses: [String: String] = [:]
    @Published var extensionWidgets: [String: ExtensionWidget] = [:]
    @Published var activeDialog: ExtensionDialogRequest?
    /// FIFO of extension dialogs so a second request never replaces an unanswered one.
    private var dialogQueue: [ExtensionDialogRequest] = []
    private static let dialogQueueLimit = 16
    @Published var toast: ToastMessage?
    @Published var viewedImage: ViewedImage?
    @Published var windowTitle = "Pi Desktop"
    @Published var inspectorVisible = true {
        didSet { persistence.updateState { $0.inspectorVisible = inspectorVisible } }
    }
    @Published var quickSwitchPresented = false
    /// Shared request surface: sidebar and application menu present the same creation alert.
    @Published var newVirtualFolderRequested = false
    @Published var schedulesPresented = false
    /// Messages the user queued while Pi was working, still editable until they are flushed to
    /// Pi at the boundary Pi would have delivered them anyway. See `Outbox.swift`.
    @Published var outbox: [OutboxEntry] = []
    /// Lazily created so the panel keeps one service for the app's lifetime.
    var cachedScheduleService: (any ScheduleServing)?
    /// Thread IDs any automation targets, so the sidebar can mark them. IDs only, capped — the
    /// automations panel still owns the schedules themselves. See `ScheduleService.swift`.
    @Published private(set) var scheduledThreadIDs: Set<String> = []
    /// Conversations whose latest agent-created GitHub pull request is still open.
    @Published private(set) var openPullRequestSessionIDs: Set<String> = []
    private static let scheduledThreadIDLimit = 500
    static let pullRequestReviewMaxAge: TimeInterval = 24 * 60 * 60
    @Published private(set) var archiveConfirmation: ArchiveConfirmation?
    /// Set by the Conversation menu so the rename sheet can live with the transcript.
    @Published var renameRequested = false
    /// True only while the ephemeral status probe runtime is attached.
    @Published private(set) var isProbingStatuses = false
    @Published private(set) var unknownRPCEvents: [String] = []
    /// The operating mode of the attached runtime (Pi `/mode`, Codex sandbox, Claude permission
    /// mode). Nil when the agent has not reported one yet.
    @Published var runtimeMode: String?

    /// The agent behind whatever is on screen. Drives every capability-gated affordance.
    var activeAgent: AgentKind {
        route == .newChat ? newChatAgent : activeRuntimeSlot.agent
    }

    var activeCapabilities: AgentCapabilities { activeAgent.capabilities }

    /// True while the slash-command palette has no authoritative answer yet: the route's runtime
    /// is still attaching, or `get_commands` is in flight. Lets the palette say "Loading…"
    /// instead of claiming the agent has no commands.
    var isLoadingCommands: Bool {
        guard activeCapabilities.listsCommands else { return false }
        return commandsLoading || !isCurrentRouteRuntime
    }

    /// The composer ladder's stops for the current agent, weakest first.
    ///
    /// Pi's ladder is its declared `/mode` list. Codex and Claude Code have no comparable
    /// effort ladder, but they do have a model list, and picking a stronger model is the same
    /// gesture; agents present those strongest-first, so the ladder reads them in reverse.
    var availableModes: [AgentMode] {
        switch activeCapabilities.ladder {
        case .modes:
            return activeCapabilities.modes
        case .models:
            let models = scopedModels
            guard models.count > 1 else { return [] }
            return models.reversed().enumerated().map { rank, model in
                AgentMode(
                    id: model.id, title: model.compactLabel, detail: model.detailLabel, rank: rank
                )
            }
        }
    }

    /// Menu/toolbar enablement for the capability-gated actions, so a greyed-out item and the
    /// toast behind it can never disagree about whether the agent supports something.
    var canCompact: Bool {
        isSelectedRuntime && !runtimeState.isBusy && activeRuntimeSlot.capabilities.canCompact
    }

    var canExportHTML: Bool {
        isSelectedRuntime && activeRuntimeSlot.capabilities.canExportHTML
    }

    var canEditHistory: Bool {
        isSelectedRuntime && activeRuntimeSlot.capabilities.canFork
    }

    /// The agents discovery should read, or nil when nothing is switched off (the common case,
    /// where narrowing would only cost a set construction per scan).
    private var enabledAgentFilter: Set<AgentKind>? {
        disabledAgents.isEmpty ? nil : Set(AgentKind.allCases.filter { !disabledAgents.contains($0) })
    }

    /// Shows or hides conversations this app did not start.
    func setShowsForeignConversations(_ shows: Bool) {
        guard showsForeignConversations != shows else { return }
        showsForeignConversations = shows
        persistence.setShowsForeignConversations(shows)
        Task { await refreshSessions() }
    }

    /// True when this app started the conversation, or the agent's own record says it did.
    private func isAppStarted(_ summary: SessionSummary) -> Bool {
        persistence.state.appStartedSessionPaths.contains(summary.fileURL.standardizedFileURL.path)
    }

    /// Switches an agent on or off. Disabling stops scanning its transcripts and offering it for
    /// a new chat; it never deletes or rewrites anything the agent owns.
    func setAgent(_ agent: AgentKind, enabled: Bool) {
        let wasDisabled = disabledAgents.contains(agent)
        guard wasDisabled == enabled else { return }
        if enabled { disabledAgents.remove(agent) } else { disabledAgents.insert(agent) }
        persistence.updateState { $0.disabledAgents = Set(disabledAgents.map(\.rawValue)) }
        installedAgents = detectedAgents.filter { !disabledAgents.contains($0) }
        if disabledAgents.contains(newChatAgent) {
            newChatAgent = installedAgents.first ?? .pi
        }
        // The repository's roots are fixed at construction, so the sidebar is refiltered here and
        // the next full scan picks up the narrower root list.
        Task { await refreshSessions() }
    }

    /// Whether sidebar rows should carry an agent glyph. On a machine with one agent it is noise
    /// on every row, so it only appears once history actually spans more than one.
    var showsAgentBadges: Bool {
        var seen: Set<AgentKind> = []
        for session in sessions where seen.insert(session.agent).inserted && seen.count > 1 { return true }
        return installedAgents.count > 1
    }

    /// The mode currently in force. Pi reports its own through the `mode` extension's status
    /// line, which is more authoritative than anything the app remembers; the other agents
    /// answer over their protocol and are tracked here.
    var currentMode: AgentMode? {
        let id: String?
        switch activeCapabilities.ladder {
        case .modes:
            id = activeAgent == .pi ? statusModel.mode?.rawValue : runtimeMode
        case .models:
            // The ladder *is* the model selection, so the runtime's own model is the position.
            id = currentProviderID.flatMap { provider in
                currentModelID.map { "\(provider)/\($0)" }
            }
        }
        guard let id else { return nil }
        return availableModes.first { $0.id == id }
    }

    let activityMonitor: SessionActivityMonitor

    private let repository: SessionRepositoryProtocol
    private let gitService: GitStatusProviding
    private let pullRequestStateProvider: PullRequestStateProviding
    /// Internal rather than private so focused extensions (the outbox, message editing) can
    /// speak to whichever selected conversation owns the current runtime.
    var runtime: AgentRuntimeProtocol { activeRuntimeSlot.runtime }
    let persistence: AppPersistence
    private let activityPresenter: ActivityPresenting
    private let runtimeFactory: (AgentKind) -> AgentRuntimeProtocol
    private let connectivityMonitor: ConnectivityMonitor?
    private let runtimeRetirementDelay: TimeInterval
    private let runtimeRetirementScheduler: RuntimeRetirementScheduler
    private let providerRetryScheduler: RuntimeRetirementScheduler
    private let managedTurnResumer: ManagedTurnResumer
    private let managedTurnWriterProbe: ManagedTurnWriterProbe?
    private let daemonWorktreeProjectsURL: URL
    private var cancelRuntimeRetirement: (() -> Void)?
    private var activeRuntimeSlot: RuntimeSlot
    private var activePresentationDetached = false
    private var parkedRuntimes: [RuntimeRouteKey: RuntimeSlot] = [:]
    /// Creates the short-lived `--no-session` runtime used only to refresh extension statuses.
    /// `nil` disables probing entirely (tests never spawn a process).
    private let probeRuntimeFactory: (() -> AgentRuntimeProtocol)?
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
    private var selectedGitDirectoryPath: String?
    private var selectedGitCandidatePath: String?
    private var selectedGitGeneration = 0
    private var gitRefreshTask: Task<Void, Never>?
    private var pullRequestRefreshTask: Task<Void, Never>?
    private var pullRequestRefreshLoopTask: Task<Void, Never>?
    private var pullRequestRefreshGeneration = 0
    private var dispatchedPullRequestReviews: Set<String> = []
    private var selectedGitTask: Task<Void, Never>?
    private var selectedWorkspaceTask: Task<Void, Never>?
    private var conversationLoadTask: Task<Void, Never>?
    private var conversationRefreshTask: Task<Void, Never>?
    private var historyNavigationTask: Task<Void, Never>?
    private var activityProjectionTask: Task<Void, Never>?
    private var conversationLoadGeneration = 0
    private var loadedConversationPage: ConversationPage?
    private var latestConversationPage: ConversationPage?
    /// Frozen visible latest window shown below the focused history page. This keeps history and
    /// the live turn visibly connected without retaining every intervening page.
    private var latestConversationMessages: [ChatMessage] = []
    private var historyDepth = 0
    /// ponytail: Reload cursors make nearby Newer navigation one bounded read. Deep history keeps
    /// only an LRU; a miss replays with constant page memory. Add a disk index only if measured.
    private var historyReloadCursors: [Int: ConversationPageCursor] = [:]
    private var historyReloadOrder: [Int] = []
    private static let historyReloadCursorLimit = 256
    private var loadedConversationPath: String?
    private var loadedConversationFingerprint: SessionFileFingerprint?
    private var refreshingConversationFingerprint: SessionFileFingerprint?
    private var initialPreviousSeenCompletionID: String?
    private var toastTask: Task<Void, Never>?
    private var dialogTimeoutTask: Task<Void, Never>?
    private var probeRuntime: AgentRuntimeProtocol?
    private var probeTask: Task<Void, Never>?
    private var probeStatuses: [String: String] = [:]
    private var appCancellables: Set<AnyCancellable> = []
    private let notificationService: NotificationPresenting
    private let sleepPreventionHandler: SleepPreventionHandler
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
    /// History retains one focused page, one detailed latest page, and that session's bounded
    /// optimistic/RPC overlay. Older navigation replaces only the focused page.
    private static let displayedMessageLimit = ConversationPage.maximumMessageCount * 2 + liveMessageLimit + 1
    private static let connectivityResumeCommand = "/pi-desktop-resume"
    private static let connectivityResumeDescription = "Continue an interrupted turn after a transient failure"
    private static let connectivityResumeInstruction =
        "A transient failure interrupted the previous turn. Continue from where it stopped without repeating completed work."
    private static let providerRetryDelays: [TimeInterval] = [15, 30, 60, 120, 300, 600, 1_200, 3_600]
    private static let relaunchRecoveryInstruction =
        "Pi Desktop restarted during the previous turn. Inspect the durable conversation and continue from where it stopped. Do not repeat completed actions; if an outcome is uncertain, explain that and ask before repeating it."

    init(
        repository: SessionRepositoryProtocol = FileSessionRepository(),
        gitService: GitStatusProviding = GitService(),
        pullRequestStateProvider: PullRequestStateProviding = GitHubPullRequestStateService(),
        runtime: AgentRuntimeProtocol = AgentRuntimeClient(),
        runtimeFactory: @escaping (AgentKind) -> AgentRuntimeProtocol = { AgentRuntimeClient.make(for: $0) },
        persistence: AppPersistence? = nil,
        activityPresenter: ActivityPresenting = ActivityPresenter(),
        activityMonitor: SessionActivityMonitor? = nil,
        connectivityMonitor: ConnectivityMonitor? = nil,
        probeRuntimeFactory: (() -> AgentRuntimeProtocol)? = nil,
        notificationService: NotificationPresenting? = nil,
        sleepPrevention: @escaping SleepPreventionHandler = { _ in },
        isActiveOverride: Bool? = nil,
        runtimeRetirementDelay: TimeInterval = 120,
        runtimeRetirementScheduler: @escaping RuntimeRetirementScheduler = { delay, action in
            let task = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                action()
            }
            return { task.cancel() }
        },
        providerRetryScheduler: @escaping RuntimeRetirementScheduler = { delay, action in
            let task = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                action()
            }
            return { task.cancel() }
        },
        managedTurnResumer: @escaping ManagedTurnResumer = { path, instruction, clientID in
            let client = PiDeskKit.PiDeskClient.unixSocket(requestTimeout: 5)
            var ready = false
            var lastError: Error?
            for delay in [UInt64(0), 500_000_000, 1_000_000_000] {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                do {
                    _ = try await client.health()
                    ready = true
                    break
                } catch {
                    lastError = error
                }
            }
            guard ready else { throw lastError ?? ScheduleServiceError.daemonUnavailable }
            // Exactly one side-effecting request. A lost response is outcome-unknown even with a
            // stable client ID because an optional standalone host could restart and forget it.
            _ = try await client.sendMessage(
                threadId: path,
                PiDeskKit.SendMessageRequest(text: instruction, clientId: clientID)
            )
        },
        managedTurnWriterProbe: ManagedTurnWriterProbe? = nil,
        daemonWorktreeProjectsURL: URL = PiDeskPaths.supportDirectory.appendingPathComponent("daemon-thread-overlay.json")
    ) {
        self.repository = repository
        self.gitService = gitService
        self.pullRequestStateProvider = pullRequestStateProvider
        self.runtimeFactory = runtimeFactory
        self.runtimeRetirementDelay = runtimeRetirementDelay
        self.runtimeRetirementScheduler = runtimeRetirementScheduler
        self.providerRetryScheduler = providerRetryScheduler
        self.managedTurnResumer = managedTurnResumer
        self.managedTurnWriterProbe = managedTurnWriterProbe
        self.daemonWorktreeProjectsURL = daemonWorktreeProjectsURL
        self.connectivityMonitor = connectivityMonitor
        activeRuntimeSlot = RuntimeSlot(runtime: runtime)
        self.persistence = persistence ?? AppPersistence()
        inspectorVisible = self.persistence.state.inspectorVisible
        self.activityPresenter = activityPresenter
        self.activityMonitor = activityMonitor ?? SessionActivityMonitor()
        self.probeRuntimeFactory = probeRuntimeFactory
        self.notificationService = notificationService ?? NotificationService()
        self.sleepPreventionHandler = sleepPrevention
        self.isActiveOverride = isActiveOverride
        // Pi requires a cwd even for a global conversation; Desktop is the neutral default and
        // passive Git inspection explicitly skips it until a real prompt starts Pi. The folder
        // the last chat used wins over it when it is still on disk.
        let startFolder = Self.existingFolder(atPath: self.persistence.state.lastFolder)
            ?? WorkspaceOrganization.globalWorkingDirectory
        selectedFolder = startFolder
        selectedGitDirectoryPath = startFolder.standardizedFileURL.path
        cachedStatuses = self.persistence.state.cachedExtensionStatuses
        var prunedCachedStatuses = false
        // A retired extension can no longer send setStatus(nil); migrate its last cached key here.
        let startupPurgeKeys = ExtensionStatusParser.ephemeralKeys.union(["pi-caffeinate"])
        for key in startupPurgeKeys where cachedStatuses.removeValue(forKey: key) != nil {
            prunedCachedStatuses = true
        }
        if prunedCachedStatuses { self.persistence.cacheExtensionStatuses(cachedStatuses) }
        draftStore = DraftStore(texts: self.persistence.state.drafts)
        draft = draftStore.text(for: Self.newChatDraftKey)

        // Detection is a filesystem check, cheap enough to do once at launch and honest enough
        // that an uninstalled agent never appears as a choice that would fail at spawn time.
        detectedAgents = AgentCatalog.installed()
        disabledAgents = Set(self.persistence.state.disabledAgents.compactMap(AgentKind.init(rawValue:)))
        showsForeignConversations = self.persistence.state.showsForeignConversations
        let installed = detectedAgents.filter { !disabledAgents.contains($0) }
        installedAgents = installed
        let remembered = self.persistence.state.lastAgent.flatMap(AgentKind.init(rawValue:))
        // Fall back through: remembered choice, first installed agent, then Pi. Never offer an
        // agent that is not there.
        newChatAgent = remembered.flatMap { installed.contains($0) ? $0 : nil } ?? installed.first ?? .pi
        runtimeMode = self.persistence.state.agentModes[newChatAgent.rawValue]

        bindRuntime(activeRuntimeSlot)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                refreshSelectedGit()
                if let selectedSession { markRead(selectedSession) }
            }
            .store(in: &appCancellables)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.flushCurrentDraftPersistence() }
            .store(in: &appCancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.flushCurrentDraftPersistence()
                self?.setSleepPrevention(false)
            }
            .store(in: &appCancellables)
        self.activityMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &appCancellables)
        self.activityMonitor.$activities
            .sink { [weak self] activities in self?.handleActivitySnapshot(activities) }
            .store(in: &appCancellables)
        self.activityMonitor.$hasRunningActivity
            .removeDuplicates()
            .sink { [weak self] running in self?.updateSleepPrevention(hasRunningActivity: running) }
            .store(in: &appCancellables)
        self.notificationService.onSelectSession = { [weak self] path in self?.focusSession(atPath: path) }
        composer.$content
            .map(\.text)
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                persistIdleComposerDraft(text, for: currentDraftKey)
            }
            .store(in: &appCancellables)
        self.connectivityMonitor?.start { [weak self] isOnline in
            Task { @MainActor in self?.updateConnectivity(isOnline: isOnline) }
        }
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

    private func runtimeKey(agent: AgentKind, cwd: URL, sessionPath: URL?) -> RuntimeRouteKey {
        if let sessionPath { return .session(sessionPath.standardizedFileURL.path) }
        return .newChat(agent, cwd.standardizedFileURL.path)
    }

    private func runtimeKey(for slot: RuntimeSlot) -> RuntimeRouteKey? {
        if slot.startedForNewChat, let cwd = slot.cwd { return .newChat(slot.agent, cwd) }
        if let path = slot.sessionPath { return .session(path) }
        return nil
    }

    /// Which agent owns a route. An existing conversation belongs to whichever agent wrote its
    /// transcript, which is never a guess; a new chat belongs to the agent the user picked.
    func agent(forSessionPath sessionPath: URL?) -> AgentKind {
        guard let sessionPath else { return newChatAgent }
        let path = sessionPath.standardizedFileURL.path
        if let known = sessions.first(where: { $0.fileURL.standardizedFileURL.path == path }) {
            return known.agent
        }
        return repository.agent(for: sessionPath)
    }

    private func removeParkedReference(to slot: RuntimeSlot) {
        parkedRuntimes = parkedRuntimes.filter { $0.value !== slot }
    }

    private func state(for slot: RuntimeSlot) -> RuntimeState {
        slot === activeRuntimeSlot ? runtimeState : slot.state
    }

    private func updateState(for slot: RuntimeSlot, _ update: (inout RuntimeState) -> Void) {
        let wasBusy = state(for: slot).isBusy
        if slot === activeRuntimeSlot {
            update(&runtimeState)
            slot.state = runtimeState
        } else {
            update(&slot.state)
        }
        if state(for: slot).isBusy != wasBusy { updateSleepPrevention() }
    }

    private func runtimeSlots() -> [RuntimeSlot] {
        var seen: Set<UUID> = []
        return ([activeRuntimeSlot] + Array(parkedRuntimes.values)).filter { seen.insert($0.id).inserted }
    }

    func setConnectivityForTesting(isOnline: Bool) { updateConnectivity(isOnline: isOnline) }

    private func updateConnectivity(isOnline: Bool) {
        let offline = !isOnline
        guard offline != isOffline else { return }
        isOffline = offline
        if offline {
            for slot in runtimeSlots() where state(for: slot).isRetrying { pauseRetryForConnectivity(slot) }
        } else {
            for slot in runtimeSlots() { resumeAfterConnectivityIfPossible(slot) }
        }
    }

    private func markWaitingForConnectivity(_ slot: RuntimeSlot) {
        guard slot.runtime.isRunning, !slot.isSuperseded else { return }
        updateState(for: slot) { $0.isWaitingForNetwork = true }
        if slot === activeRuntimeSlot { cancelRuntimeRetirementLease() }
    }

    private func pauseRetryForConnectivity(_ slot: RuntimeSlot) {
        guard isOffline, state(for: slot).isRetrying, !slot.connectivityResumeCancelled else { return }
        markWaitingForConnectivity(slot)
        if slot.providerRetryID != nil {
            cancelProviderRetry(for: slot, resetAttempt: false)
            updateState(for: slot) { $0.clearRetryState() }
            return
        }
        guard !slot.connectivityRetryAbortRequested else { return }
        slot.connectivityRetryAbortRequested = true
        slot.runtime.send(type: "abort_retry", payload: [:]) { _ in }
    }

    private func clearConnectivityWait(for slot: RuntimeSlot) {
        slot.connectivityRetryAbortRequested = false
        slot.connectivityResumePreparing = false
        updateState(for: slot) { $0.isWaitingForNetwork = false }
    }

    private func cancelProviderRetry(for slot: RuntimeSlot, resetAttempt: Bool) {
        slot.cancelProviderRetry?()
        slot.cancelProviderRetry = nil
        slot.providerRetryID = nil
        slot.providerRetryPending = false
        if resetAttempt { slot.providerRetryAttempt = 0 }
    }

    private func scheduleProviderRetry(for slot: RuntimeSlot) {
        guard slot.providerRetryPending, !slot.connectivityResumeCancelled,
              slot.runtime.isRunning, slot.isReady, !slot.isStarting, !slot.isSuperseded else { return }
        slot.providerRetryPending = false
        if isOffline {
            markWaitingForConnectivity(slot)
            return
        }

        let index = min(slot.providerRetryAttempt, Self.providerRetryDelays.count - 1)
        let delay = Self.providerRetryDelays[index]
        slot.providerRetryAttempt = min(index + 1, Self.providerRetryDelays.count)
        let retryID = UUID()
        slot.providerRetryID = retryID
        updateState(for: slot) { state in
            state.isRetrying = true
            state.retryAttempt = slot.providerRetryAttempt
            state.retryDelayMs = Int(delay * 1_000)
            state.retryStartedAt = Date()
            state.lastError = nil
        }
        if slot === activeRuntimeSlot { cancelRuntimeRetirementLease() }
        slot.cancelProviderRetry = providerRetryScheduler(delay) { [weak self, weak slot] in
            guard let self, let slot, slot.providerRetryID == retryID, !slot.isSuperseded else { return }
            prepareInterruptedTurnContinuation(for: slot)
        }
    }

    private func resumeAfterConnectivityIfPossible(_ slot: RuntimeSlot) {
        let current = state(for: slot)
        guard !isOffline, current.isWaitingForNetwork, !current.isStreaming, !current.isRetrying else { return }
        prepareInterruptedTurnContinuation(for: slot)
    }

    private func prepareInterruptedTurnContinuation(for slot: RuntimeSlot) {
        let current = state(for: slot)
        guard !isOffline, !current.isStreaming, (!current.isRetrying || slot.providerRetryID != nil),
              !slot.connectivityResumeCancelled, !slot.connectivityResumePreparing,
              slot.runtime.isRunning, slot.isReady, !slot.isStarting, !slot.isSuperseded else { return }

        // Verify the helper command on this already-running Pi process. The extension may have
        // been disabled or upgraded after launch; in that case a plain visible continuation is
        // safer than sending an unknown slash command.
        slot.connectivityResumePreparing = true
        slot.runtime.send(type: "get_commands", payload: [:]) { [weak self, weak slot] result in
            guard let self, let slot else { return }
            slot.connectivityResumePreparing = false
            let current = state(for: slot)
            guard !isOffline, !current.isStreaming, (!current.isRetrying || slot.providerRetryID != nil),
                  !slot.connectivityResumeCancelled, slot.runtime.isRunning, !slot.isSuperseded else { return }

            let response: JSONValue
            switch result {
            case let .success(value): response = value
            case .failure:
                sendInterruptedTurnContinuation(to: slot, hidden: false)
                return
            }
            guard responseError(response) == nil else {
                sendInterruptedTurnContinuation(to: slot, hidden: false)
                return
            }
            let helperPath = ActivityExtensionInstaller.installedFileURL().standardizedFileURL.path
            let hasHelper = (response["data"]?["commands"]?.arrayValue ?? []).contains {
                $0["name"]?.stringValue == "pi-desktop-resume"
                    && $0["source"]?.stringValue == "extension"
                    && $0["description"]?.stringValue == Self.connectivityResumeDescription
                    && $0["sourceInfo"]?["path"]?.stringValue.map {
                        URL(fileURLWithPath: $0).standardizedFileURL.path == helperPath
                    } == true
            }
            sendInterruptedTurnContinuation(to: slot, hidden: hasHelper)
        }
    }

    private func sendInterruptedTurnContinuation(to slot: RuntimeSlot, hidden: Bool) {
        let current = state(for: slot)
        guard !isOffline, !current.isStreaming, (!current.isRetrying || slot.providerRetryID != nil),
              !slot.connectivityResumeCancelled, slot.runtime.isRunning, !slot.isSuperseded else { return }
        slot.cancelProviderRetry = nil
        slot.providerRetryID = nil
        updateState(for: slot) { $0.clearRetryState() }
        clearConnectivityWait(for: slot)
        slot.connectivityResumeInFlight = true
        slot.promptBeganAt = Date()
        if slot === activeRuntimeSlot { cancelRuntimeRetirementLease() }
        updateState(for: slot) { state in
            state.isStreaming = true
            state.phase = .waitingForModel
            state.lastError = nil
        }
        slot.runtime.send(
            type: "prompt",
            payload: ["message": .string(hidden ? Self.connectivityResumeCommand : Self.connectivityResumeInstruction)]
        ) { [weak self, weak slot] result in
            guard let self, let slot, !slot.isSuperseded else { return }
            let errorText: String?
            var outcomeUnknown = false
            switch result {
            case let .success(response): errorText = responseError(response)
            case let .failure(error):
                errorText = error.localizedDescription
                outcomeUnknown = RPCFailureHandling.isOutcomeUnknown(error)
            }
            guard let errorText else { return }
            if outcomeUnknown {
                if slot === activeRuntimeSlot, !activePresentationDetached {
                    showToast(errorText, style: .warning)
                }
                return
            }
            failInterruptedTurnContinuation(slot, error: errorText)
        }
    }

    private func failInterruptedTurnContinuation(_ slot: RuntimeSlot, error: String) {
        clearConnectivityWait(for: slot)
        cancelProviderRetry(for: slot, resetAttempt: true)
        slot.connectivityResumeInFlight = false
        let message = "Could not retry the interrupted turn: \(error)"
        updateState(for: slot) { state in
            state.isStreaming = false
            state.phase = .idle
            state.lastError = message
        }
        slot.promptBeganAt = nil
        if slot === activeRuntimeSlot, !activePresentationDetached {
            showToast(message, style: .error)
            resetRuntimeRetirementLease(for: slot)
        } else if isIdleAndClean(slot) {
            retireBackgroundRuntime(slot)
        }
    }

    func retryLastFailedTurn() {
        guard let session = selectedSession, canRetryLastFailure else { return }
        guard !isOffline else {
            showToast("Reconnect before retrying this turn.", style: .warning)
            return
        }
        let path = session.fileURL.standardizedFileURL.path
        runtimeState.lastError = nil
        ensureRuntime(cwd: session.cwd, sessionPath: session.fileURL) { [weak self] result in
            guard let self, selectedSession?.fileURL.standardizedFileURL.path == path else { return }
            switch result {
            case let .success(slot):
                slot.connectivityResumeCancelled = false
                prepareInterruptedTurnContinuation(for: slot)
            case let .failure(error):
                runtimeState.lastError = error.localizedDescription
                showToast(error.localizedDescription, style: .error)
            }
        }
    }

    func beginOutboxDispatch() -> (owner: UUID, dispatch: UUID) {
        beginOutboxDispatch(for: activeRuntimeSlot)
    }

    @discardableResult
    func dispatchNextActiveFollowUp() -> Bool {
        guard !activePresentationDetached else { return false }
        return dispatchNextFollowUp(for: activeRuntimeSlot)
    }

    @discardableResult
    private func dispatchNextFollowUp(for slot: RuntimeSlot) -> Bool {
        let usesLivePresentation = slot === activeRuntimeSlot && !activePresentationDetached
        let entries = usesLivePresentation ? outbox : slot.outbox
        guard let entry = entries.first(where: { $0.delivery == .followUp }), slot.runtime.isRunning else { return false }
        if usesLivePresentation { outbox.removeAll { $0.id == entry.id } }
        else { slot.outbox.removeAll { $0.id == entry.id } }

        let token = beginOutboxDispatch(for: slot)
        slot.outboxPromptPreflighting = true
        slot.outboxPromptAbortRequested = false
        slot.promptPreflightID = token.dispatch
        slot.promptBeganAt = Date()
        updateState(for: slot) { state in
            state.isStreaming = true
            state.phase = .waitingForModel
        }
        var payload: [String: JSONValue] = [
            "message": .string(ImageAttachment.prompt(text: entry.text, attachments: entry.attachments))
        ]
        if !entry.attachments.isEmpty { payload["images"] = .array(entry.attachments.map(\.rpcValue)) }
        beginManagedTurnRecovery(for: slot)
        slot.runtime.send(type: "prompt", payload: payload) { [weak self, weak slot] result in
            guard let self, let slot, !slot.isSuperseded else { return }
            let definitelyRejected: Bool
            switch result {
            case let .success(response):
                definitelyRejected = responseError(response) != nil
            case let .failure(error):
                definitelyRejected = !RPCFailureHandling.isOutcomeUnknown(error)
            }
            if definitelyRejected {
                clearManagedTurnRecovery(for: slot)
                restoreOutboxEntry(entry, owner: token.owner)
            } else if case let .success(response) = result, responseError(response) == nil {
                updateManagedTurn(for: slot) { $0.phase = ManagedTurnRecovery.accepted }
            }
            finishOutboxDispatch(
                owner: token.owner,
                dispatch: token.dispatch,
                delivery: entry.delivery,
                result: result
            )
            guard !definitelyRejected else {
                slot.outboxPromptPreflighting = false
                slot.outboxPromptAbortRequested = false
                slot.promptPreflightID = nil
                slot.promptBeganAt = nil
                updateState(for: slot) { state in
                    state.isStreaming = false
                    state.phase = .idle
                }
                return
            }
            guard case let .success(response) = result, responseError(response) == nil else { return }
            slot.runtime.send(type: "get_state", payload: [:]) { [weak self, weak slot] result in
                guard let self, let slot, !slot.isSuperseded,
                      slot.outboxDispatches.contains(token.dispatch),
                      slot.promptPreflightID == token.dispatch,
                      case let .success(response) = result, responseError(response) == nil,
                      let isStreaming = response["data"]?["isStreaming"]?.boolValue else { return }
                updateState(for: slot) { state in
                    state.isStreaming = isStreaming
                    if !isStreaming { state.phase = .idle }
                }
                guard !isStreaming else { return }
                slot.outboxPromptPreflighting = false
                slot.outboxPromptAbortRequested = false
                slot.promptPreflightID = nil
                slot.promptBeganAt = nil
                slot.outboxDispatches.remove(token.dispatch)
                clearManagedTurnRecovery(for: slot)
                if !dispatchNextFollowUp(for: slot) {
                    if slot === activeRuntimeSlot { resetRuntimeRetirementLease(for: slot) }
                    else if isIdleAndClean(slot) { retireBackgroundRuntime(slot) }
                }
            }
        }
        return true
    }

    private func beginOutboxDispatch(for slot: RuntimeSlot) -> (owner: UUID, dispatch: UUID) {
        let dispatch = UUID()
        slot.outboxDispatches.insert(dispatch)
        return (slot.id, dispatch)
    }

    func restoreOutboxEntry(_ entry: OutboxEntry, owner: UUID) {
        guard let slot = runtimeSlot(id: owner), !slot.isSuperseded else { return }
        if slot === activeRuntimeSlot, !activePresentationDetached {
            outbox = OutboxPolicy.restoring(entry, to: outbox)
        } else {
            slot.outbox = OutboxPolicy.restoring(entry, to: slot.outbox)
        }
    }

    func finishOutboxDispatch(
        owner: UUID,
        dispatch: UUID,
        delivery: OutboxEntry.Delivery,
        result: Result<JSONValue, Error>
    ) {
        guard let slot = runtimeSlot(id: owner), !slot.isSuperseded else { return }
        let error: String?
        let outcomeUnknown: Bool
        switch result {
        case let .success(response):
            error = responseError(response)
            outcomeUnknown = false
        case let .failure(value):
            error = value.localizedDescription
            outcomeUnknown = RPCFailureHandling.isOutcomeUnknown(value)
        }
        if delivery == .steer || (error != nil && !outcomeUnknown) { slot.outboxDispatches.remove(dispatch) }
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
        slot.commands = availableCommands
        slot.commandsLoading = commandsLoading
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
        availableCommands = slot.commands
        commandsLoading = slot.commandsLoading
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
        availableCommands.removeAll()
        commandsLoading = false
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
        let statuses = slot === activeRuntimeSlot && !activePresentationDetached ? extensionStatuses : slot.statuses
        // Background subagents run inside this runtime's process: stopping it kills them
        // silently mid-work. The subagents extension only publishes this key while agents are
        // running or queued and clears it when the last one finishes, so its presence is a
        // keep-alive. A blank value counts as "no work" so a degenerate status cannot pin a
        // process open forever.
        let subagents = statuses[ExtensionStatusParser.subagentsKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !slot.isStarting && !slot.optionsLoading && presentation.phase == .idle && !presentation.isBusy
            && slot.pendingTurn == nil && dialogs.isEmpty && queued.isEmpty
            && !slot.providerRetryPending && slot.providerRetryID == nil
            && slot.outboxDispatches.isEmpty && slot.deferredEvents.isEmpty
            && capability == nil && questionnaire == nil && stream == nil && subagents.isEmpty
            && slot.managedProcessIDs.isEmpty
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

    /// The folder Pi runs in. New-chat organization stays on the selected project while an
    /// optional worktree replaces only this execution cwd.
    private var selectedExecutionFolder: URL? {
        selectedSession?.cwd ?? newChatWorktree ?? selectedFolder
    }

    /// Filesystem projects already known from sidebar conversations. A virtual-folder assignment
    /// must not make its underlying project disappear from the new-chat chooser.
    var sidebarFolders: [URL] {
        var seen: Set<String> = []
        return sessions.compactMap { session in
            let folder = projectFolder(for: session).standardizedFileURL
            guard !WorkspaceOrganization.isGlobalWorkingDirectory(folder), seen.insert(folder.path).inserted else { return nil }
            return folder
        }
    }

    /// `NSApplication.shared` rather than the `NSApp` global so headless test hosts stay safe.
    /// `isActiveOverride` keeps notification frontmost/background rules deterministic in tests.
    private var isApplicationActive: Bool { isActiveOverride ?? NSApplication.shared.isActive }

    var isSelectedRuntime: Bool {
        guard !activePresentationDetached, let selectedSession else { return false }
        return selectedSession.fileURL.standardizedFileURL.path == activeRuntimePath
    }

    /// True for either an attached saved conversation or the query-only runtime prepared for a
    /// new global chat. Picker controls use this broader route scope; transcript/session actions
    /// deliberately keep using `isSelectedRuntime`.
    var isCurrentRouteRuntime: Bool { runtimeMatchesCurrentRoute }

    private var currentRouteRuntimeSlot: RuntimeSlot? {
        guard let key = currentRouteKey else { return nil }
        if runtimeKey(for: activeRuntimeSlot) == key { return activeRuntimeSlot }
        return parkedRuntimes[key]
    }

    var canStopCurrentThread: Bool {
        guard let slot = currentRouteRuntimeSlot else { return false }
        let current = state(for: slot)
        let queued = slot === activeRuntimeSlot && !activePresentationDetached ? outbox : slot.outbox
        return slot.isStarting || current.isBusy || !queued.isEmpty || current.queueCount > 0
            || !slot.outboxDispatches.isEmpty
    }

    var canRetryLastFailure: Bool {
        isSelectedRuntime && runtimeState.lastError != nil && !runtimeState.isBusy
    }

    var currentRouteRuntimePhase: RuntimePhase? {
        guard !activePresentationDetached, runtimeKey(for: activeRuntimeSlot) == currentRouteKey else { return nil }
        return runtimeState.phase
    }

    private var currentRouteKey: RuntimeRouteKey? {
        if let selectedSession { return .session(selectedSession.fileURL.standardizedFileURL.path) }
        guard let selectedExecutionFolder else { return nil }
        return .newChat(activeAgent, selectedExecutionFolder.standardizedFileURL.path)
    }

    var selectedMetrics: TokenMetrics {
        isSelectedRuntime && runtimeState.isConnected ? liveMetrics : (selectedSession?.metrics ?? TokenMetrics())
    }

    private var runningRuntimePaths: Set<String> {
        Set(runtimeSlots().compactMap { slot in
            guard state(for: slot).isBusy || !slot.managedProcessIDs.isEmpty else { return nil }
            return slot.sessionPath
        })
    }

    private func updateSleepPrevention(
        activities: [String: SessionActivity]? = nil,
        hasRunningActivity: Bool? = nil
    ) {
        let observedActivities = activities ?? activityMonitor.activities
        let shouldPreventSleep = runtimeSlots().contains {
            state(for: $0).isBusy || !$0.managedProcessIDs.isEmpty
        } || (hasRunningActivity ?? activityMonitor.hasRunningActivity)
            || observedActivities.values.contains { $0.state == .running }
        setSleepPrevention(shouldPreventSleep)
    }

    private func setSleepPrevention(_ active: Bool) {
        guard active != isCaffeinated else { return }
        isCaffeinated = active
        sleepPreventionHandler(active)
    }

    private func isWaitingForProviderRecovery(at path: String) -> Bool {
        runtimeSlots().contains { slot in
            let waiting = state(for: slot).isWaitingForNetwork || slot.connectivityResumeInFlight
                || slot.providerRetryPending || slot.providerRetryID != nil
            guard waiting,
                  let candidate = slot.sessionPath ?? state(for: slot).sessionFile else { return false }
            return URL(fileURLWithPath: candidate).standardizedFileURL.path == path
        }
    }

    // MARK: - Cross-terminal activity

    /// True when this session is working, whether it was started by this app or by any terminal.
    /// The app's own runtime state wins, then the file-based monitor.
    func isRunning(_ session: SessionSummary) -> Bool {
        let path = session.fileURL.standardizedFileURL.path
        if runningRuntimePaths.contains(path) { return true }
        return activityMonitor.activity(forPath: path)?.state == .running
    }

    /// True only once this runtime has issued the extension request that makes its buffered
    /// questionnaire answerable. This includes questions parked while another thread is open.
    func isWaitingForQuestion(_ session: SessionSummary) -> Bool {
        let path = session.fileURL.standardizedFileURL.path
        let slot = activeRuntimePath == path ? activeRuntimeSlot : parkedRuntimes[.session(path)]
        guard let slot else { return false }

        let usesLivePresentation = slot === activeRuntimeSlot && !activePresentationDetached
        guard let questionnaire = usesLivePresentation ? pendingQuestionnaire : slot.questionnaire,
              !questionnaire.submitted else { return false }
        let requests = usesLivePresentation ? dialogQueue : slot.dialogs
        return requests.contains { questionnaireRequest($0, belongsTo: questionnaire) }
            || slot.deferredEvents.contains { deferredRequest($0, belongsTo: questionnaire) }
    }

    /// The freshest modification time available: the monitor's live stat, else the summary.
    func liveModifiedAt(_ session: SessionSummary) -> Date {
        let observed = activityMonitor.activity(forPath: session.fileURL.standardizedFileURL.path)?.modifiedAt
        return max(observed ?? .distantPast, session.modifiedAt)
    }

    /// The app knows its prompt start before the shared activity monitor's next poll. Prefer that
    /// while available so a new turn never inherits an older conversation timestamp.
    func runningSince(_ session: SessionSummary) -> Date? {
        let path = session.fileURL.standardizedFileURL.path
        if activeRuntimePath == path, runtimeState.isBusy, let beganAt = activeRuntimeSlot.promptBeganAt {
            return beganAt
        }
        if let slot = parkedRuntimes[.session(path)], slot.state.isBusy, let beganAt = slot.promptBeganAt {
            return beganAt
        }
        if let observed = activityMonitor.activity(forPath: path)?.runningSince { return observed }
        if activeRuntimePath == path, !activeRuntimeSlot.managedProcessIDs.isEmpty {
            return activeRuntimeSlot.managedProcessStartedAt
        }
        if let slot = parkedRuntimes[.session(path)], !slot.managedProcessIDs.isEmpty {
            return slot.managedProcessStartedAt
        }
        return nil
    }

    /// The user-turn/run boundary stays fixed while tool and assistant writes keep changing mtime.
    /// A runtime can briefly precede the monitor's first observation; the summary date is stable
    /// during that gap and avoids reordering on every subsequent write.
    func runningSortDate(_ session: SessionSummary) -> Date {
        runningSince(session) ?? session.modifiedAt
    }

    func resourceUsage(_ session: SessionSummary) -> ThreadResourceUsage? {
        activityMonitor.activity(forPath: session.fileURL.standardizedFileURL.path)?.resources
    }

    /// Menu bar source: every non-archived session currently working, newest run first.
    var runningSessions: [SessionSummary] {
        sessions
            .filter { !$0.isArchived && isRunning($0) }
            .sorted {
                let left = runningSortDate($0)
                let right = runningSortDate($1)
                return left == right
                    ? $0.fileURL.standardizedFileURL.path < $1.fileURL.standardizedFileURL.path
                    : left > right
            }
    }

    var aggregateResourceUsage: ThreadResourceUsage? {
        activityMonitor.aggregateResources
    }

    /// The sidebar's Status buckets, also used by the menu bar panel, so both file and sort
    /// every conversation identically instead of each repeating the store's predicates.
    func statusGroups(_ sessions: [SessionSummary]) -> [SidebarStatusGroup] {
        SidebarStatusGroup.groups(
            sessions,
            isRunning: { self.isRunning($0) },
            isUnread: { self.isUnread($0) },
            hasOpenPullRequest: { self.openPullRequestSessionIDs.contains($0.id) },
            isAutomated: { self.scheduledThreadIDs.contains($0.id) },
            runningAt: { self.runningSortDate($0) },
            modifiedAt: { self.liveModifiedAt($0) }
        )
    }

    /// Dock badge source: the same Done bucket shown by the sidebar's Status view.
    var doneSessionCount: Int {
        sessions.reduce(0) { count, session in
            count + (SidebarStatusGroup.section(
                for: session,
                isRunning: isRunning(session),
                isUnread: isUnread(session),
                hasOpenPullRequest: openPullRequestSessionIDs.contains(session.id),
                isAutomated: scheduledThreadIDs.contains(session.id)
            ) == .done ? 1 : 0)
        }
    }

    private func managedTurnPath(for slot: RuntimeSlot) -> String? {
        guard let path = slot.sessionPath ?? state(for: slot).sessionFile, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func beginManagedTurnRecovery(for slot: RuntimeSlot) {
        guard let path = managedTurnPath(for: slot) else { return }
        let visibleBaseline = selectedSession?.fileURL.standardizedFileURL.path == path
            ? messages.reversed().first(where: {
                $0.role == .assistant && SessionParser.terminalAssistantStopReasons.contains($0.stopReason ?? "")
            })?.id
            : nil
        let baseline = activityMonitor.activity(forPath: path)?.latestCompletedEntryID
            ?? persistence.state.latestCompletedEntryIDBySessionPath[path]
            ?? visibleBaseline
        let heartbeatObserved = ActivityHeartbeatStore.scan(
            directory: ActivityHeartbeatStore.defaultDirectory()
        )[path] != nil
        persistence.updateState {
            $0.setManagedTurnRecovery(ManagedTurnRecovery(
                id: UUID(), sessionPath: path, phase: ManagedTurnRecovery.dispatching,
                baselineCompletionID: baseline, activeToolCallIDs: [],
                heartbeatObserved: heartbeatObserved, startedAt: Date()
            ))
        }
    }

    private func updateManagedTurn(for slot: RuntimeSlot, _ update: (inout ManagedTurnRecovery) -> Void) {
        guard let path = managedTurnPath(for: slot),
              var recovery = persistence.state.managedTurnRecoveries[path] else { return }
        update(&recovery)
        persistence.updateState { $0.setManagedTurnRecovery(recovery) }
    }

    private func clearManagedTurnRecovery(for slot: RuntimeSlot) {
        guard let path = managedTurnPath(for: slot) else { return }
        clearManagedTurnRecovery(path: path)
    }

    private func clearManagedTurnRecovery(path: String) {
        guard persistence.state.managedTurnRecoveries[path] != nil else { return }
        persistence.updateState { $0.removeManagedTurnRecovery(path: path) }
    }

    private func updateManagedTool(_ event: JSONValue, running: Bool, slot: RuntimeSlot) {
        guard let id = event["toolCallId"]?.stringValue else { return }
        updateManagedTurn(for: slot) { recovery in
            if running { recovery.activeToolCallIDs.insert(id) }
            else { recovery.activeToolCallIDs.remove(id) }
        }
    }

    private func latestManagedCompletionID(at path: String) async -> String? {
        await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path)
            return SessionActivityClassifier.readTail(at: url, limit: SessionParser.tailScanWindowBytes)
                .flatMap {
                    SessionParser.latestTerminalAssistantCompletion(
                        inTail: $0, transcoder: .forSessionPath(path)
                    )
                }?.id
        }.value
    }

    private func liveWriterRemains(at path: String) async -> Bool {
        for attempt in 0..<32 {
            let source = await Task.detached(priority: .utility) { () -> ManagedWriterState in
                let heartbeats = ActivityHeartbeatStore.scan(
                    directory: ActivityHeartbeatStore.defaultDirectory()
                )[path] ?? []
                // Any live attached process wins, including an idle/suspended terminal whose
                // heartbeat timestamp is old. If no heartbeat exists, retain the bounded file
                // fallback for terminals running without the extension.
                if heartbeats.contains(where: { ActivityHeartbeatClassifier.isProcessAlive(pid: $0.pid) }) {
                    return .heartbeat
                }
                // Dead heartbeat files are not proof that nobody else is writing: a direct
                // terminal without the extension may share this path, so still consult the file.
                return SessionActivityClassifier.classifyFile(at: URL(fileURLWithPath: path))?.state == .running
                    ? .fileFallback : .none
            }.value
            if source == .none { return false }
            // A live PID gets a short teardown window. The file-only fallback needs its own
            // 15-second stale window to distinguish the killed app worker from a terminal that
            // keeps writing without the extension.
            if source == .heartbeat, attempt >= 5 { return true }
            if attempt < 31 { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        return true
    }

    /// A dead provider stream cannot be reattached. For an app-owned accepted turn with no tool
    /// left in an outcome-ambiguous state, enqueue one new continuation against the same durable
    /// Pi session. Dispatching/tool-active/prior-recovery states require review instead of a
    /// blind replay. Plain terminal sessions have no app-owned record and are never touched.
    private func recoverManagedTurnsAfterLaunch() async {
        let recoveries = persistence.state.managedTurnRecoveries.values.sorted { $0.startedAt < $1.startedAt }
        guard !recoveries.isEmpty else { return }

        for original in recoveries {
            guard sessions.contains(where: { $0.fileURL.standardizedFileURL.path == original.sessionPath }) else { continue }
            let path = original.sessionPath
            let currentCompletion = await latestManagedCompletionID(at: path)
            if let currentCompletion, currentCompletion != original.baselineCompletionID {
                clearManagedTurnRecovery(path: path)
                continue
            }

            let writerRemains = if let managedTurnWriterProbe {
                await managedTurnWriterProbe(path)
            } else {
                await liveWriterRemains(at: path)
            }
            if writerRemains {
                var review = original
                review.phase = ManagedTurnRecovery.needsReview
                persistence.updateState { $0.setManagedTurnRecovery(review) }
                showToast(
                    "This interrupted thread is still active in another Pi process; it was not resumed.",
                    style: .warning,
                    sessionPath: path
                )
                continue
            }

            // The writer may have settled during the bounded liveness wait. Re-read the durable
            // tail immediately before dispatch so a completed answer never gets a continuation.
            if let completionAfterWait = await latestManagedCompletionID(at: path),
               completionAfterWait != original.baselineCompletionID {
                clearManagedTurnRecovery(path: path)
                continue
            }

            guard original.phase == ManagedTurnRecovery.accepted,
                  original.activeToolCallIDs.isEmpty,
                  original.heartbeatObserved == true else {
                var review = original
                review.phase = ManagedTurnRecovery.needsReview
                persistence.updateState { $0.setManagedTurnRecovery(review) }
                showToast(
                    "A previous turn was interrupted and needs review before continuing.",
                    style: .warning,
                    sessionPath: path
                )
                continue
            }

            var recovering = original
            recovering.phase = ManagedTurnRecovery.recovering
            persistence.updateState { $0.setManagedTurnRecovery(recovering) }

            do {
                try await managedTurnResumer(
                    path,
                    Self.relaunchRecoveryInstruction,
                    "recovery-\(original.id.uuidString)"
                )
                showToast("Resuming an interrupted turn.", style: .info, sessionPath: path)
            } catch {
                recovering.phase = ManagedTurnRecovery.needsReview
                persistence.updateState { $0.setManagedTurnRecovery(recovering) }
                showToast(
                    "Could not confirm recovery; review the interrupted turn before continuing.",
                    style: .warning,
                    sessionPath: path
                )
            }
        }
    }

    func recoverManagedTurnsForTesting() async { await recoverManagedTurnsAfterLaunch() }

    /// Completion IDs, not run-state or mtime transitions, are the sole finished-answer signal.
    /// The first snapshot establishes a quiet baseline; every later distinct ID is persisted
    /// before notification gating so duplicate observations and relaunches stay silent.
    private func handleActivitySnapshot(_ activities: [String: SessionActivity]) {
        defer { updateSleepPrevention(activities: activities) }
        if let selectedPath = selectedSession?.fileURL.standardizedFileURL.path,
           activities[selectedPath] != nil {
            refreshSelectedConversationIfNeeded()
        }

        for (path, activity) in activities {
            let hadBaseline = observedActivityPaths.contains(path)
            observedActivityPaths.insert(path)
            guard let completionID = activity.latestCompletedEntryID else { continue }
            if let recovery = persistence.state.managedTurnRecoveries[path],
               completionID != recovery.baselineCompletionID {
                clearManagedTurnRecovery(path: path)
            }
            let failed = activity.lastStopReason == "error" || activity.lastStopReason == "aborted"
            // Pi may append an error before its automatic retry. Do not persist or notify that
            // completion until the session settles; a recovered answer will replace it first.
            if activity.lastStopReason == "error", activity.state == .running { continue }
            // A transport error is intermediate while Desktop owns a pending continuation.
            // Deferring it avoids an error notification immediately followed by a success one.
            if isWaitingForProviderRecovery(at: path) { continue }

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
            let title = NotificationPreviewFormatter.format(session.displayName) ?? "Pi"
            notificationService.presentDesktopNotification(sessionKey: key, title: title, body: body)
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
        // Live values win per key while a runtime starts. Once get_state succeeds, that runtime's
        // complete status snapshot replaces the cache, pruning keys from removed extensions.
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

    private func replaceCachedStatuses(with snapshot: [String: String]) {
        let durable = snapshot.filter { !ExtensionStatusParser.ephemeralKeys.contains($0.key) }
        guard durable != cachedStatuses else { return }
        cachedStatuses = durable
        persistence.cacheExtensionStatuses(durable)
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
                selectedFolder = WorkspaceOrganization.globalWorkingDirectory
            }
            await recoverManagedTurnsAfterLaunch()
            // Warm the transcript cache after the scan settles, so opening a recent conversation
            // is instant even before the user selects anything.
            schedulePrefetch(around: selectedSession)
        }
        // The daemon can still be spawning/binding its socket while the window comes up (see
        // DaemonSupervisor), so the first load can lose that race. One retry covers it; anything
        // longer is the automations panel's or the refresh button's job, not a polling loop.
        Task {
            if await refreshScheduledThreads() { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await refreshScheduledThreads()
        }
        startGitRefreshLoop()
        startPullRequestRefreshLoop()
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
            let overlayURL = daemonWorktreeProjectsURL
            let daemonWorktrees = await Task.detached(priority: .utility) {
                DaemonWorktreeProjects.load(from: overlayURL)
            }.value
            let scanned = applyArchiveRetention(
                to: try await repository.discoverSessions(
                    archivedIDs: persistence.state.archivedSessionIDs,
                    agents: enabledAgentFilter
                )
            )
            // Ownership is applied after discovery rather than inside it: the hidden count has
            // to be honest, and a conversation only stops being listed, never stops existing.
            let discovered = showsForeignConversations ? scanned : scanned.filter(isAppStarted)
            hiddenForeignCount = scanned.count - discovered.count
            let discoveredCwds = Set(discovered.map { $0.cwd.standardizedFileURL.path })
            persistence.mergeManagedWorktreeProjects(
                daemonWorktrees.filter { discoveredCwds.contains($0.key) }
            )
            sessions = discovered
            refreshPullRequestStates(for: discovered)
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

    private func refreshPullRequestStates(for summaries: [SessionSummary]) {
        pullRequestRefreshTask?.cancel()
        pullRequestRefreshGeneration &+= 1
        let generation = pullRequestRefreshGeneration
        let linked = Array(summaries.lazy.filter {
            !$0.isArchived && $0.pullRequestURL != nil
        }.prefix(GitHubPullRequestStateService.maximumURLCount))
        guard !linked.isEmpty else {
            openPullRequestSessionIDs = []
            return
        }

        let urls = Array(Set(linked.compactMap(\.pullRequestURL)))
        let previous = openPullRequestSessionIDs
        let provider = pullRequestStateProvider
        pullRequestRefreshTask = Task { [weak self] in
            let states = await provider.states(for: urls)
            guard !Task.isCancelled, let self,
                  pullRequestRefreshGeneration == generation else { return }
            let resolved = Set(linked.compactMap { session -> String? in
                guard let url = session.pullRequestURL else { return nil }
                let state = states[url] ?? .unknown
                if state.isOpen { return session.id }
                if state == .unknown, previous.contains(session.id) { return session.id }
                return nil
            })
            if openPullRequestSessionIDs != resolved { openPullRequestSessionIDs = resolved }

            // Review polling belongs to Pi Desktop itself. It wakes the thread only after Codex
            // has actually reviewed the PR, never by creating a user-visible automation.
            dispatchedPullRequestReviews.formIntersection(linked.compactMap { session in
                session.pullRequestURL.map { "\(session.id)\u{0}\($0.absoluteString)" }
            })
            let ready = Self.pullRequestReviewsReady(
                in: linked, states: states, now: Date(), isRunning: isRunning
            )
            for (session, url, deadline) in ready where !Task.isCancelled {
                let key = "\(session.id)\u{0}\(url.absoluteString)"
                guard dispatchedPullRequestReviews.insert(key).inserted else { continue }
                let deadlineMilliseconds = Int64(deadline.timeIntervalSince1970 * 1_000)
                do {
                    try await managedTurnResumer(
                        session.fileURL.standardizedFileURL.path,
                        "/pi-desktop-pr-review \(url.absoluteString) \(deadlineMilliseconds)",
                        "pr-review-\(session.id)-\(url.lastPathComponent)"
                    )
                } catch {
                    dispatchedPullRequestReviews.remove(key)
                }
            }
        }
    }

    static func pullRequestReviewsReady(
        in summaries: [SessionSummary],
        states: [URL: PullRequestState],
        now: Date,
        isRunning: (SessionSummary) -> Bool
    ) -> [(SessionSummary, URL, Date)] {
        summaries.compactMap { session in
            guard !session.isArchived, !isRunning(session),
                  let url = session.pullRequestURL,
                  states[url] == .openWithCodexReview,
                  let createdAt = session.pullRequestCreatedAt else { return nil }
            let age = now.timeIntervalSince(createdAt)
            guard age >= 0, age <= pullRequestReviewMaxAge else { return nil }
            return (session, url, createdAt.addingTimeInterval(pullRequestReviewMaxAge))
        }
    }

    /// Loads the automations only to learn which conversations they target. A failure keeps the
    /// previous set: a daemon that is briefly down must not erase clocks from the sidebar.
    /// Returns whether the load succeeded, so a caller can decide to try once more.
    @discardableResult
    func refreshScheduledThreads() async -> Bool {
        guard let entries = try? await scheduleService.loadSchedules() else { return false }
        for watch in entries where watch.isInternalPullRequestReviewWatch {
            try? await scheduleService.delete(id: watch.id)
        }
        updateScheduledThreads(from: entries)
        return true
    }

    /// Called by the automations panel whenever its list changes, so an edit shows up in the
    /// sidebar without a second round trip. A paused automation still counts — the conversation
    /// is still associated with one — and a new-thread target marks no existing row.
    func updateScheduledThreads(from entries: [ScheduleEntry]) {
        var ids: Set<String> = []
        for entry in entries {
            guard !entry.isInternalPullRequestReviewWatch,
                  case let .existingThread(threadID) = entry.target, !threadID.isEmpty else { continue }
            ids.insert(threadID)
            // A display hint, not a copy of the schedule list.
            if ids.count >= Self.scheduledThreadIDLimit { break }
        }
        scheduledThreadIDs = ids
    }

    func openNewChat() {
        if let selectedSession { markRead(selectedSession) }
        parkCurrentDraft()
        flushDraftPersistence()
        cancelConversationLoad()
        resetConversationPageState()
        // Anything still pending here was never sent, so the worktree is unused; drop it instead
        // of leaving an orphan under ~/.pi/worktrees.
        discardPendingWorktree()
        let newFolder = defaultNewChatFolder
        if runtimeKey(for: activeRuntimeSlot) != .newChat(newChatAgent, newFolder.standardizedFileURL.path) {
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
        resetSelectedGitDirectory(to: newFolder)
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
        if runtimeKey(for: activeRuntimeSlot) != targetKey {
            detachActiveRuntimePresentation()
        } else if !activePresentationDetached, pendingQuestionnaire?.submitted == false {
            saveActiveRuntimePresentation()
        }
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
        resetSelectedGitDirectory(to: session.cwd)

        // Transient queues and questions belong to the live runtime. Reattach it immediately
        // instead of hiding them until the user next edits the composer.
        if let slot = currentRouteRuntimeSlot,
           slot !== activeRuntimeSlot || activePresentationDetached || slot.questionnaire?.submitted == false {
            activateRuntime(slot)
        }

        // A page-cache hit publishes synchronously in the selection tick. Activity projection is
        // inspector data and stays off the main actor so it cannot delay the transcript frame.
        if let (cached, fingerprint) = cachedPage(for: session.fileURL) {
            publishConversationPage(cached, path: path, fingerprint: fingerprint)
            isConversationLoading = false
            updateSelectedWorkspace(from: cached.messages, for: session)
            conversationLoadTask = Task { [weak self] in
                guard let self else { return }
                let projected = await projectActivities(from: cached.messages)
                guard conversationLoadGeneration == generation,
                      selectedSession?.fileURL.standardizedFileURL.path == path else { return }
                activities = projected
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
        updateSelectedWorkspace(from: page.messages, for: session)
        refreshSelectedConversationIfNeeded()
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
        schedulePrefetch(around: session)
    }

    /// Refreshes only the selected latest page's changed tail. Historical pages stay frozen until
    /// the reader returns to Live, so live work never replaces what they are reading.
    private func refreshSelectedConversationIfNeeded() {
        guard !isConversationLoading, !isLoadingEarlierMessages, !isLoadingNewerMessages,
              !isBrowsingEarlierHistory,
              let session = selectedSession,
              loadedConversationPage != nil else { return }
        let path = session.fileURL.standardizedFileURL.path
        guard loadedConversationPath == path,
              let fingerprint = fileFingerprint(for: session.fileURL),
              fingerprint != loadedConversationFingerprint,
              fingerprint != refreshingConversationFingerprint else { return }

        let generation = conversationLoadGeneration
        conversationRefreshTask?.cancel()
        refreshingConversationFingerprint = fingerprint
        conversationRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await repository.loadNewestConversationPage(from: session.fileURL)
                try Task.checkCancellation()
                guard conversationLoadGeneration == generation,
                      selectedSession?.fileURL.standardizedFileURL.path == path,
                      !isLoadingEarlierMessages, !isBrowsingEarlierHistory,
                      let current = loadedConversationPage else {
                    finishConversationRefresh(fingerprint)
                    return
                }
                mergeNewestConversationPage(page, current: current, path: path, fingerprint: fingerprint)
                finishConversationRefresh(fingerprint)
            } catch {
                finishConversationRefresh(fingerprint)
            }
        }
    }

    private func finishConversationRefresh(_ fingerprint: SessionFileFingerprint) {
        guard refreshingConversationFingerprint == fingerprint else { return }
        refreshingConversationFingerprint = nil
        conversationRefreshTask = nil
    }

    private func mergeNewestConversationPage(
        _ newest: ConversationPage,
        current: ConversationPage,
        path: String,
        fingerprint: SessionFileFingerprint
    ) {
        let overlap = newest.messages.lazy.compactMap { message in
            current.messages.firstIndex(where: { $0.id == message.id })
        }.first
        let combined = overlap.map { Array(current.messages[..<$0]) + newest.messages } ?? newest.messages
        let retained = enforcingLoadedImageBudget(combined)
        let preservedHistory = overlap != nil
        let merged = ConversationPage(
            messages: retained,
            olderCursor: preservedHistory ? current.olderCursor : newest.olderCursor,
            leafID: newest.leafID,
            rawEntryCount: max(current.rawEntryCount, newest.rawEntryCount),
            scannedEntryCount: max(current.scannedEntryCount, newest.scannedEntryCount),
            scannedByteCount: max(current.scannedByteCount, newest.scannedByteCount),
            // When the refresh page overlapped the loaded history, its own scan-budget truncation
            // is irrelevant: only the overlap tail was consumed. Mixing `newest.isTruncated` in
            // here used to flip "history is outside the bounded window" on for a fully loaded
            // conversation whenever a large live turn made the refresh scan hit its byte cap.
            isTruncated: preservedHistory ? current.isTruncated : newest.isTruncated
        )
        loadedConversationPage = merged
        loadedConversationPath = path
        loadedConversationFingerprint = fingerprint
        replaceLoadedMessages(with: retained)
        if let session = selectedSession { updateSelectedWorkspace(from: retained, for: session) }
        conversationHistoryLimitReached = merged.isTruncated && merged.olderCursor == nil
        hasEarlierMessages = merged.olderCursor != nil
        cachePage(merged, for: URL(fileURLWithPath: path), fingerprint: fingerprint)
        mergeHistoryActivities()
    }

    @discardableResult
    func loadEarlierMessages() -> Bool {
        guard !isConversationLoading, !isLoadingEarlierMessages, !isLoadingNewerMessages,
              !conversationHistoryLimitReached,
              let session = selectedSession,
              let current = loadedConversationPage,
              let cursor = current.olderCursor else { return false }
        let path = session.fileURL.standardizedFileURL.path
        guard loadedConversationPath == path else { return false }
        conversationRefreshTask?.cancel()
        conversationRefreshTask = nil
        refreshingConversationFingerprint = nil
        cancelEditingLastMessage()
        let generation = conversationLoadGeneration
        let nextDepth = historyDepth + 1
        let latestMessages = messages
        isLoadingEarlierMessages = true
        historyNavigationTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            do {
                let older = try await repository.loadFocusedHistoryPage(from: session.fileURL, cursor: cursor)
                try Task.checkCancellation()
                guard conversationLoadGeneration == generation,
                      selectedSession?.fileURL.standardizedFileURL.path == path else { return }
                if historyDepth == 0 {
                    latestConversationPage = current
                    latestConversationMessages = latestMessages
                }
                rememberHistoryReloadCursor(cursor, depth: nextDepth)
                publishHistoryPage(older, depth: nextDepth)
                isLoadingEarlierMessages = false
                historyNavigationTask = nil
                ConversationPerformance.mark(
                    "Focused history page", path: path, count: older.messages.count,
                    milliseconds: Date().timeIntervalSince(startedAt) * 1_000
                )
            } catch is CancellationError {
                if conversationLoadGeneration == generation,
                   selectedSession?.fileURL.standardizedFileURL.path == path {
                    refreshSelectedConversationIfNeeded()
                }
            } catch {
                guard conversationLoadGeneration == generation,
                      selectedSession?.fileURL.standardizedFileURL.path == path else { return }
                isLoadingEarlierMessages = false
                historyNavigationTask = nil
                refreshSelectedConversationIfNeeded()
                showToast("Couldn’t load earlier history: \(error.localizedDescription)", style: .warning)
            }
        }
        return true
    }

    @discardableResult
    func loadNewerMessages() -> Bool {
        guard !isConversationLoading, !isLoadingEarlierMessages, !isLoadingNewerMessages,
              historyDepth > 0, let session = selectedSession,
              let latest = latestConversationPage else { return false }
        let path = session.fileURL.standardizedFileURL.path
        guard loadedConversationPath == path else { return false }
        let targetDepth = historyDepth - 1
        if targetDepth == 0 {
            restoreLatestConversation(latest)
            return true
        }

        let generation = conversationLoadGeneration
        let cachedCursor = historyReloadCursors[targetDepth]
        isLoadingNewerMessages = true
        historyNavigationTask = Task { [weak self] in
            guard let self else { return }
            do {
                var remembered: [(Int, ConversationPageCursor)] = []
                let page: ConversationPage
                if let cachedCursor {
                    page = try await repository.loadFocusedHistoryPage(from: session.fileURL, cursor: cachedCursor)
                    remembered.append((targetDepth, cachedCursor))
                } else {
                    var replayed = latest
                    for depth in 1...targetDepth {
                        try Task.checkCancellation()
                        guard let cursor = replayed.olderCursor else { throw ConversationPagingError.invalidCursor }
                        if depth > targetDepth - Self.historyReloadCursorLimit {
                            remembered.append((depth, cursor))
                        }
                        replayed = try await repository.loadFocusedHistoryPage(from: session.fileURL, cursor: cursor)
                    }
                    page = replayed
                }
                try Task.checkCancellation()
                guard conversationLoadGeneration == generation,
                      selectedSession?.fileURL.standardizedFileURL.path == path else { return }
                for (depth, cursor) in remembered { rememberHistoryReloadCursor(cursor, depth: depth) }
                publishHistoryPage(page, depth: targetDepth)
                isLoadingNewerMessages = false
                historyNavigationTask = nil
            } catch is CancellationError {
                // Route changed or the reader jumped back to latest.
            } catch {
                guard conversationLoadGeneration == generation,
                      selectedSession?.fileURL.standardizedFileURL.path == path else { return }
                isLoadingNewerMessages = false
                historyNavigationTask = nil
                showToast("Couldn’t load newer history: \(error.localizedDescription)", style: .warning)
            }
        }
        return true
    }

    func jumpToLatestMessages() {
        historyNavigationTask?.cancel()
        historyNavigationTask = nil
        isLoadingEarlierMessages = false
        isLoadingNewerMessages = false
        if let latest = latestConversationPage { restoreLatestConversation(latest) }
        latestScrollRequest &+= 1
    }

    private func publishHistoryPage(_ page: ConversationPage, depth: Int) {
        loadedConversationPage = page
        historyDepth = depth
        isBrowsingEarlierHistory = true
        hasNewerMessages = true
        conversationHistoryLimitReached = page.isTruncated && page.olderCursor == nil
        hasEarlierMessages = page.olderCursor != nil
        streamingMessage = nil
        let latestIDs = Set(latestConversationMessages.map(\.id))
        let history = page.messages.filter { !latestIDs.contains($0.id) }
        messages = enforcingLoadedImageBudget(history + latestConversationMessages)
    }

    private func restoreLatestConversation(_ latest: ConversationPage) {
        historyDepth = 0
        isBrowsingEarlierHistory = false
        hasNewerMessages = false
        latestConversationPage = nil
        latestConversationMessages.removeAll(keepingCapacity: false)
        historyReloadCursors.removeAll(keepingCapacity: false)
        historyReloadOrder.removeAll(keepingCapacity: false)
        loadedConversationPage = latest
        conversationHistoryLimitReached = latest.isTruncated && latest.olderCursor == nil
        hasEarlierMessages = latest.olderCursor != nil
        replaceLoadedMessages(with: latest.messages)
        if isSelectedRuntime { streamingMessage = activeRuntimeSlot.streamingMessage }
        refreshSelectedConversationIfNeeded()
    }

    private func rememberHistoryReloadCursor(_ cursor: ConversationPageCursor, depth: Int) {
        historyReloadCursors[depth] = cursor
        historyReloadOrder.removeAll { $0 == depth }
        historyReloadOrder.append(depth)
        while historyReloadOrder.count > Self.historyReloadCursorLimit {
            historyReloadCursors.removeValue(forKey: historyReloadOrder.removeFirst())
        }
    }

    func consumeInitialScrollTarget() {
        initialScrollTargetMessageID = nil
        initialPreviousSeenCompletionID = nil
    }

    private func publishConversationPage(
        _ page: ConversationPage,
        path: String,
        fingerprint: SessionFileFingerprint?
    ) {
        loadedConversationPage = page
        latestConversationPage = nil
        latestConversationMessages.removeAll(keepingCapacity: false)
        historyDepth = 0
        historyReloadCursors.removeAll(keepingCapacity: false)
        historyReloadOrder.removeAll(keepingCapacity: false)
        isBrowsingEarlierHistory = false
        hasNewerMessages = false
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
        conversationHistoryLimitReached = page.isTruncated && page.olderCursor == nil
        hasEarlierMessages = page.olderCursor != nil
    }

    private func resetConversationPageState() {
        loadedConversationPage = nil
        latestConversationPage = nil
        latestConversationMessages.removeAll(keepingCapacity: false)
        historyDepth = 0
        historyReloadCursors.removeAll(keepingCapacity: false)
        historyReloadOrder.removeAll(keepingCapacity: false)
        loadedConversationPath = nil
        loadedConversationFingerprint = nil
        refreshingConversationFingerprint = nil
        hasEarlierMessages = false
        hasNewerMessages = false
        isBrowsingEarlierHistory = false
        isLoadingEarlierMessages = false
        isLoadingNewerMessages = false
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
        var projected = await Task.detached(priority: .userInitiated) {
            presenter.activities(from: messages)
        }.value
        if isSelectedRuntime, activeRuntimeSlot.isReady,
           extensionStatuses[ExtensionStatusParser.subagentsKey] == nil {
            Self.stopInactiveSubagents(in: &projected)
        }
        return projected
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

    /// A remembered folder path that still exists, standardized. `nil` for anything moved away.
    static func existingFolder(atPath path: String?) -> URL? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Where ⌘N starts: the folder the last chat used, else Global.
    private var defaultNewChatFolder: URL {
        Self.existingFolder(atPath: persistence.state.lastFolder) ?? WorkspaceOrganization.globalWorkingDirectory
    }

    func chooseFolder(_ url: URL) {
        let folder = url.standardizedFileURL
        if case .newChat = route, selectedFolder?.standardizedFileURL.path != folder.path {
            discardPendingWorktree()
        }
        if case .newChat = route, runtimeKey(for: activeRuntimeSlot) != .newChat(newChatAgent, folder.path) {
            detachActiveRuntimePresentation()
        }
        selectedFolder = folder
        // A generated worktree is never "the folder you work in": remembering it would make the
        // next new chat start in a throwaway checkout and crowd the folder menu.
        if !WorktreeService.isManaged(folder) { persistence.setLastFolder(folder.path) }
        if !WorkspaceOrganization.isGlobalWorkingDirectory(folder), !WorktreeService.isManaged(folder) {
            persistence.rememberFolder(folder)
        }
        if selectedSession == nil { resetSelectedGitDirectory(to: folder) }
        refreshSelectedGit()
    }

    // MARK: - Conversation worktrees

    /// The new-chat `Worktree` checkbox. Turning it on cuts a fresh worktree off the project's
    /// main line and uses it only as Pi's execution cwd; the selected project stays unchanged for
    /// the new-chat row and desktop organization.
    func setNewChatWorktree(_ enabled: Bool) {
        guard enabled else { discardPendingWorktree(restoringFolder: true); return }
        guard newChatWorktree == nil else { return }
        guard let folder = selectedFolder, !WorkspaceOrganization.isGlobalWorkingDirectory(folder) else {
            showToast("Choose a project folder before adding a worktree.", style: .warning)
            return
        }
        Task {
            switch await WorktreeService.create(from: folder) {
            case let .success(worktree):
                // The user navigated away or changed projects while git worked: nothing will use
                // this checkout.
                guard case .newChat = route,
                      newChatWorktree == nil,
                      selectedFolder?.standardizedFileURL.path == folder.standardizedFileURL.path else {
                    await WorktreeService.remove(at: worktree)
                    return
                }
                persistence.setManagedWorktreeProject(folder, for: worktree)
                newChatWorktreeOrigin = folder
                newChatWorktreeSubmitted = false
                newChatWorktree = worktree
                if runtimeKey(for: activeRuntimeSlot) != .newChat(newChatAgent, worktree.path) {
                    detachActiveRuntimePresentation()
                }
                showToast("Worktree ready: \(worktree.lastPathComponent)", style: .info)
            case let .failure(error):
                showToast(error.message, style: .warning)
            }
        }
    }

    /// Drops a worktree that was created for a chat that never started. `remove` is non-force, so
    /// anything already written there survives as a plain directory git still tracks.
    private func discardPendingWorktree(restoringFolder: Bool = false) {
        guard let worktree = newChatWorktree else { return }
        let origin = newChatWorktreeOrigin
        let shouldRemove = !newChatWorktreeSubmitted
        newChatWorktree = nil
        newChatWorktreeOrigin = nil
        newChatWorktreeSubmitted = false
        if shouldRemove { persistence.setManagedWorktreeProject(nil, for: worktree) }
        if restoringFolder, let origin { chooseFolder(origin) }
        if shouldRemove { Task { await WorktreeService.remove(at: worktree) } }
    }

    /// Archived conversations (and the worktrees they ran in) are cleared from the sidebar this
    /// long after archiving — long enough that an accidental archive can still be restored. Pi's
    /// own session file is never touched, so a pruned conversation is hidden, not destroyed.
    static let archiveRetention: TimeInterval = 7 * 24 * 60 * 60

    static func expiredArchiveIDs(
        _ sessions: [SessionSummary],
        archivedAt: [String: Date],
        now: Date
    ) -> Set<String> {
        Set(sessions.lazy
            .filter { $0.isArchived }
            .filter { now.timeIntervalSince(archivedAt[$0.id] ?? now) >= archiveRetention }
            .map(\.id))
    }

    /// Stamps newly seen archives (including ones archived by older builds, whose clock starts
    /// now) and drops the expired ones, removing any worktree no surviving conversation still uses.
    private func applyArchiveRetention(to discovered: [SessionSummary], now: Date = Date()) -> [SessionSummary] {
        persistence.updateState { state in
            for session in discovered where session.isArchived && state.archivedAt[session.id] == nil {
                state.archivedAt[session.id] = now
            }
        }
        let expired = Self.expiredArchiveIDs(discovered, archivedAt: persistence.state.archivedAt, now: now)
        guard !expired.isEmpty else { return discovered }
        let surviving = discovered.filter { !expired.contains($0.id) }
        let stillUsed = Set(surviving.map { $0.cwd.standardizedFileURL.path })
        let releasable = Set(discovered
            .filter { expired.contains($0.id) }
            .map(\.cwd)
            .filter { WorktreeService.isManaged($0) && !stillUsed.contains($0.standardizedFileURL.path) }
            .map { $0.standardizedFileURL })
        for worktree in releasable {
            persistence.setManagedWorktreeProject(nil, for: worktree)
            Task { await WorktreeService.remove(at: worktree) }
        }
        return surviving
    }

    func archivedDate(_ session: SessionSummary) -> Date {
        persistence.state.archivedAt[session.id] ?? session.modifiedAt
    }

    func toggleArchive(_ session: SessionSummary) {
        if session.isArchived {
            setArchived(false, session: session)
        } else {
            Task { await requestArchive(session) }
        }
    }

    /// Re-reads the durable schedule store before deciding whether confirmation is needed, so an
    /// automation created from the CLI or web cannot be missed by an older sidebar clock.
    func requestArchive(_ session: SessionSummary) async {
        do {
            let entries = try await scheduleService.loadSchedules()
            updateScheduledThreads(from: entries)
            guard let current = sessions.first(where: { $0.id == session.id }), !current.isArchived else { return }
            let linked = linkedSchedules(in: entries, threadID: session.id)
            if linked.isEmpty {
                setArchived(true, session: current)
            } else {
                archiveConfirmation = ArchiveConfirmation(sessionID: session.id, automationCount: linked.count)
            }
        } catch {
            showToast("Couldn’t check linked automations: \(error.localizedDescription)", style: .error)
        }
    }

    func cancelArchiveConfirmation() {
        archiveConfirmation = nil
    }

    func confirmArchive(_ confirmation: ArchiveConfirmation) async {
        archiveConfirmation = nil
        guard sessions.contains(where: { $0.id == confirmation.sessionID && !$0.isArchived }) else { return }
        do {
            let entries = try await scheduleService.loadSchedules()
            let linked = linkedSchedules(in: entries, threadID: confirmation.sessionID)
            for entry in linked { try await scheduleService.delete(id: entry.id) }
            updateScheduledThreads(from: entries.filter { !linked.contains($0) })
            guard let session = sessions.first(where: { $0.id == confirmation.sessionID }), !session.isArchived else { return }
            setArchived(true, session: session)
        } catch {
            await refreshScheduledThreads()
            showToast("Couldn’t archive because linked automations couldn’t be deleted: \(error.localizedDescription)", style: .error)
        }
    }

    private func linkedSchedules(in entries: [ScheduleEntry], threadID: String) -> [ScheduleEntry] {
        entries.filter {
            if case let .existingThread(targetID) = $0.target { return targetID == threadID }
            return false
        }
    }

    private func setArchived(_ archived: Bool, session: SessionSummary) {
        let selectedPath = selectedSession?.fileURL.standardizedFileURL.path
        persistence.setArchived(archived, sessionID: session.id)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].isArchived = archived
            if archived, selectedPath == session.fileURL.standardizedFileURL.path {
                if let next = sessions[(index + 1)...].first(where: { !$0.isArchived })
                    ?? sessions[..<index].last(where: { !$0.isArchived }) {
                    selectSession(next)
                } else {
                    openNewChat()
                }
            }
        }
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

    private func persistIdleComposerDraft(_ text: String, for key: String) {
        persistDraftText(text, for: key)
        if runtimeMatchesCurrentRoute {
            let slot = activeRuntimeSlot
            resetRuntimeRetirementLease(for: slot)
        }
    }

    private func flushCurrentDraftPersistence() {
        persistDraftText(draft, for: currentDraftKey)
        flushDraftPersistence()
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

    private static func optimisticMessage(text: String, attachments: [ImageAttachment]) -> ChatMessage {
        ChatMessage(
            id: "local-\(UUID().uuidString)", role: .user,
            blocks: [MessageBlock(id: UUID().uuidString, kind: .text(text))] + attachments.map {
                let image = ImagePayload(id: $0.id.uuidString, data: $0.data, mimeType: $0.mimeType, fileName: $0.fileName)
                return MessageBlock(id: image.id, kind: .image(image))
            },
            timestamp: Date(), raw: .null
        )
    }

    func submitDraft(delivery: DeliveryMode = .automatic) {
        if isBrowsingEarlierHistory || isLoadingEarlierMessages || isLoadingNewerMessages {
            jumpToLatestMessages()
        }
        let text = Self.sanitizedMessage(draft)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let cwd: URL
        let sessionPath: URL?
        if let selectedSession {
            cwd = selectedSession.cwd
            sessionPath = selectedSession.fileURL
            if selectedSession.isArchived { setArchived(false, session: selectedSession) }
        } else if let selectedExecutionFolder {
            cwd = selectedExecutionFolder
            sessionPath = nil
        } else {
            showToast("Choose a working folder first", style: .warning)
            return
        }
        // Keep the execution cwd selected until Pi assigns the real session path, but transfer
        // ownership now so navigation can never delete a submitted worktree.
        newChatWorktreeSubmitted = newChatWorktree != nil

        let sentText = draft
        let sentAttachments = attachments
        let origin = DraftOrigin(route: route, sessionPath: sessionPath?.standardizedFileURL.path)
        let submittedDraftKey = currentDraftKey
        let optimisticID: String?
        if delivery == .automatic, !(isSelectedRuntime && runtimeState.isStreaming) {
            let message = Self.optimisticMessage(text: text, attachments: sentAttachments)
            optimisticID = message.id
            retainLiveMessage(message, path: origin.sessionPath ?? Self.newChatDraftKey)
            messages = enforcingLoadedImageBudget(messages + [message])
        } else {
            optimisticID = nil
        }
        persistDraftText("", for: submittedDraftKey)
        attachmentsByKey.removeValue(forKey: submittedDraftKey)
        draft = ""
        attachments = []
        var completedSynchronously = false
        weak var startupSlot: RuntimeSlot?
        ensureRuntime(cwd: cwd, sessionPath: sessionPath) { [weak self] result in
            completedSynchronously = true
            if let startupSlot { startupSlot.pendingStartupPrompts = max(0, startupSlot.pendingStartupPrompts - 1) }
            guard let self else { return }
            switch result {
            case let .success(slot):
                dispatchMessage(text, originalDraft: sentText, attachments: sentAttachments,
                                delivery: delivery, cwd: cwd, optimisticID: optimisticID,
                                submissionOrigin: origin, slot: slot)
            case let .failure(error):
                if case .newChat = route,
                   newChatWorktree?.standardizedFileURL.path == cwd.standardizedFileURL.path {
                    newChatWorktreeSubmitted = false
                }
                if let optimisticID { removeOptimisticMessage(optimisticID, origin: origin) }
                let restored = restoreDraft(text: sentText, attachments: sentAttachments, origin: origin)
                showToast(failureMessage(error.localizedDescription, restored: restored, origin: origin), style: .error)
            }
        }
        if !completedSynchronously, let slot = currentRouteRuntimeSlot {
            startupSlot = slot
            slot.pendingStartupPrompts += 1
        }
    }

    /// Pi sessions are append-only trees. Editing moves the current runtime immediately before
    /// the original entry, then appends the replacement on a new branch in the same session file.
    func branchAndSubmitEditedMessage(
        targetID: String,
        targetText: String,
        messagesBeforeTarget: [ChatMessage],
        completion: @escaping () -> Void
    ) {
        guard let source = selectedSession else { completion(); return }
        let sourcePath = source.fileURL.standardizedFileURL.path
        let commandName = "pi-desktop-edit-message"
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

            let discardNavigatedRuntime = { [weak self, weak slot] in
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

            let navigateAndSubmit: (String) -> Void = { [weak self, weak slot] entryID in
                guard let self, let slot else { completion(); return }
                slot.runtime.send(type: "get_commands", payload: [:]) { [weak self, weak slot] result in
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
                    let commandAvailable = response["data"]?["commands"]?.arrayValue?.contains {
                        $0["name"]?.stringValue == commandName && $0["source"]?.stringValue == "extension"
                    } == true
                    guard commandAvailable else {
                        discardNavigatedRuntime()
                        fail("Pi Desktop’s message editing helper is unavailable. Restart Pi Desktop and try again.", .warning)
                        return
                    }

                    let token = UUID().uuidString
                    let command = "/\(commandName) \(entryID) \(token)"
                    slot.runtime.send(type: "prompt", payload: ["message": .string(command)]) { [weak self, weak slot] result in
                        guard let self, let slot else { completion(); return }
                        guard slot === activeRuntimeSlot,
                              selectedSession?.fileURL.standardizedFileURL.path == sourcePath else {
                            discardNavigatedRuntime()
                            completion()
                            return
                        }
                        switch result {
                        case let .failure(error):
                            discardNavigatedRuntime()
                            fail(error.localizedDescription, RPCFailureHandling.isOutcomeUnknown(error) ? .warning : .error)
                            return
                        case let .success(response):
                            if let error = responseError(response) {
                                discardNavigatedRuntime()
                                fail(error, .error)
                                return
                            }
                        }

                        slot.runtime.send(type: "get_entries", payload: ["since": .string(entryID)]) { [weak self, weak slot] result in
                            guard let self, let slot else { completion(); return }
                            guard slot === activeRuntimeSlot,
                                  selectedSession?.fileURL.standardizedFileURL.path == sourcePath else {
                                discardNavigatedRuntime()
                                completion()
                                return
                            }
                            let response: JSONValue
                            switch result {
                            case let .failure(error):
                                discardNavigatedRuntime()
                                fail(error.localizedDescription, .error)
                                return
                            case let .success(value):
                                response = value
                            }
                            let entries = response["data"]?["entries"]?.arrayValue
                            let marker = entries?.last(where: {
                                $0["type"]?.stringValue == "custom"
                                    && $0["customType"]?.stringValue == "pi-desktop-edit-ready"
                                    && $0["data"]?["targetId"]?.stringValue == entryID
                                    && $0["data"]?["token"]?.stringValue == token
                            })
                            guard responseError(response) == nil,
                                  let markerID = marker?["id"]?.stringValue,
                                  response["data"]?["leafId"]?.stringValue == markerID else {
                                discardNavigatedRuntime()
                                fail(responseError(response) ?? "Pi did not switch to the edited history.", .error)
                                return
                            }

                            finalDurabilityTasks.removeValue(forKey: slot.id)?.cancel()
                            transcriptCache.remove(sourcePath)
                            liveMessagesByPath.removeValue(forKey: sourcePath)
                            liveMessageOrder.removeAll { $0.path == sourcePath }
                            removePendingFinal(path: sourcePath)
                            // Reselecting the same route preserves its draft while rebuilding the
                            // bounded page and pagination cursor from Pi's new active branch.
                            selectSession(source)
                            messages = enforcingLoadedImageBudget(messagesBeforeTarget)
                            submitDraft()
                            completion()
                        }
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
                    navigateAndSubmit(entryID)
                }
            } else {
                navigateAndSubmit(targetID)
            }
        }
    }

    // MARK: - Extension commands

    /// Slash commands (`/mode`, `/codex-fast`, `/limits`, and anything the palette lists) run
    /// through the normal prompt path, which is how every agent accepts them. Pi's own extension
    /// commands execute immediately and make no provider call; another agent's command may well
    /// start a turn, which is exactly what running it is supposed to do.
    func runExtensionCommand(_ command: String, successToast: String? = nil) {
        let clean = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("/") else { return }

        let cwd: URL
        let sessionPath: URL?
        if let selectedSession { cwd = selectedSession.cwd; sessionPath = selectedSession.fileURL }
        else if let selectedExecutionFolder { cwd = selectedExecutionFolder; sessionPath = nil }
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

        let cwd = selectedExecutionFolder ?? FileManager.default.homeDirectoryForCurrentUser
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
        if !probeStatuses.isEmpty { replaceCachedStatuses(with: probeStatuses) }
    }

    func activateCurrentRouteRuntimeForEscape() -> Bool {
        guard let slot = currentRouteRuntimeSlot else { return false }
        if slot !== activeRuntimeSlot || activePresentationDetached { activateRuntime(slot) }
        return runtimeMatchesCurrentRoute
    }

    var currentRouteHasPendingStartupPrompt: Bool {
        runtimeMatchesCurrentRoute && activeRuntimeSlot.pendingStartupPrompts > 0
    }

    /// Stops the active turn without retiring its runtime or touching queued continuations.
    /// Escape uses this path so Pi can start the preserved follow-up after settlement.
    func abortCurrentTurnPreservingQueues() {
        guard runtimeMatchesCurrentRoute else { return }
        let slot = activeRuntimeSlot
        let wasWaitingToRetry = slot.providerRetryPending || slot.providerRetryID != nil
        slot.connectivityResumeCancelled = true
        cancelProviderRetry(for: slot, resetAttempt: true)
        if wasWaitingToRetry {
            runtimeState.clearRetryState()
            if !runtimeState.isStreaming {
                if dispatchNextActiveFollowUp() { slot.connectivityResumeCancelled = false }
                else { resetRuntimeRetirementLease(for: slot) }
                return
            }
        }
        if slot.pendingStartupPrompts > 0 {
            slot.outboxPromptAbortRequested = true
            return
        }
        if runtimeState.isWaitingForNetwork {
            clearConnectivityWait(for: slot)
            guard runtimeState.isStreaming else {
                resetRuntimeRetirementLease(for: slot)
                return
            }
        }
        guard runtimeState.isStreaming else { return }
        if slot.outboxPromptPreflighting {
            slot.outboxPromptAbortRequested = true
            return
        }
        sendSoftAbort(to: slot)
    }

    private func sendSoftAbort(to slot: RuntimeSlot) {
        slot.runtime.send(type: "abort", payload: [:]) { [weak self, weak slot] result in
            guard let self, let slot, !slot.isSuperseded else { return }
            switch result {
            case let .success(response):
                if let error = responseError(response) { showToast(error, style: .error) }
            case let .failure(error):
                showToast(error.localizedDescription, style: .error)
            }
        }
    }

    func abort() { fullyStopCurrentRuntime(allowIdle: false) }

    func abortFromEscapeSequence() { fullyStopCurrentRuntime(allowIdle: true) }

    private func fullyStopCurrentRuntime(allowIdle: Bool) {
        guard (allowIdle || canStopCurrentThread), let slot = currentRouteRuntimeSlot else { return }
        let ownsLivePresentation = slot === activeRuntimeSlot && !activePresentationDetached
        let readyWaiters = slot.readyWaiters
        if slot === activeRuntimeSlot { cancelRuntimeRetirementLease() }
        else { objectWillChange.send() }
        finalDurabilityTasks.removeValue(forKey: slot.id)?.cancel()

        // A stop is final: discard every app-held and Pi-owned continuation, retire the process,
        // and ignore any event already en route from its superseded generation.
        clearManagedTurnRecovery(for: slot)
        slot.isSuperseded = true
        slot.isReady = false
        slot.isStarting = false
        slot.readyWaiters.removeAll()
        slot.optionsLoading = false
        slot.outbox.removeAll()
        slot.outboxDispatches.removeAll()
        slot.outboxPromptPreflighting = false
        slot.outboxPromptAbortRequested = false
        slot.promptPreflightID = nil
        slot.pendingStartupPrompts = 0
        slot.deferredEvents.removeAll()
        slot.pendingTurn = nil
        slot.streamingMessage = nil
        slot.managedProcessIDs.removeAll()
        slot.managedProcessStartedAt = nil
        slot.capability = nil
        slot.questionnaire = nil
        slot.dialogs.removeAll()
        slot.promptBeganAt = nil
        slot.startupBeganAt = nil
        slot.connectivityRetryAbortRequested = false
        slot.connectivityResumeCancelled = true
        slot.connectivityResumePreparing = false
        slot.connectivityResumeInFlight = false
        cancelProviderRetry(for: slot, resetAttempt: true)
        if ownsLivePresentation {
            outbox.removeAll()
            streamingMessage = nil
            activeCapability = nil
            composerOptionsLoading = false
            clearExtensionDialogs()
        }
        updateState(for: slot) { state in
            state.isConnected = false
            state.isStreaming = false
            state.isCompacting = false
            state.clearRetryState()
            state.isWaitingForNetwork = false
            state.phase = .idle
            state.steeringQueue.removeAll()
            state.followUpQueue.removeAll()
        }
        if slot !== activeRuntimeSlot { removeParkedReference(to: slot) }

        if slot.runtime.isRunning {
            // Write abort before stop reaches the serial RPC queue, giving Pi a chance to clean
            // up active tools; process termination is the guarantee that no accepted queue restarts.
            slot.runtime.send(type: "abort", payload: [:], completion: nil)
            slot.runtime.onEvent = nil
            slot.runtime.onExit = nil
            slot.runtime.stop()
        }
        for waiter in readyWaiters {
            waiter(.failure(AgentRuntimeError.processExited("Pi was stopped.")))
        }
        activityMonitor.tickNow()
    }

    func compact() {
        guard requireAttachedRuntime(\.canCompact, named: "compaction") else { return }
        runtime.send(type: "compact", payload: [:]) { [weak self] result in
            if case let .failure(error) = result { self?.showToast(error.localizedDescription, style: .error) }
        }
    }

    /// One gate for every capability-dependent action: the runtime has to be attached *and* the
    /// agent behind it has to actually support the thing, with a truthful message either way.
    private func requireAttachedRuntime(
        _ capability: KeyPath<AgentCapabilities, Bool>,
        named what: String
    ) -> Bool {
        guard isSelectedRuntime else {
            showToast("Open this conversation with \(activeAgent.displayName) first.", style: .warning)
            return false
        }
        let agent = activeRuntimeSlot.agent
        guard agent.capabilities[keyPath: capability] else {
            showToast("\(agent.displayName) does not support \(what).", style: .warning)
            return false
        }
        return true
    }

    func exportHTML() {
        guard requireAttachedRuntime(\.canExportHTML, named: "HTML export") else { return }
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

    /// The first editor mutation prewarms Pi. Later keys stay on AppKit's input path instead of
    /// cancelling and rebuilding the same runtime lease; the idle draft publisher touches it once.
    func composerContentDidChange() {
        if runtimeMatchesCurrentRoute {
            let slot = activeRuntimeSlot
            guard !slot.isStarting, !slot.optionsLoading, !slot.optionsPrepared else { return }
        }
        prepareComposerOptions()
    }

    /// Starts or attaches the route's RPC runtime and loads picker choices. These are query-only
    /// commands and never send a provider prompt.
    func prepareComposerOptions() {
        guard let cwd = selectedExecutionFolder else { return }
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
            case let .success(response):
                showToast(responseError(response) ?? "\(slot.agent.displayName) rejected the model.", style: .error)
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
                // An agent that only carries effort per turn or per launch still has to show the
                // new level immediately, or the control looks broken.
                if slot.capabilities.thinking != .live { refreshRuntimeStateAfterPickerChange(slot: slot) }
            case let .success(response):
                showToast(responseError(response) ?? "\(slot.agent.displayName) rejected the thinking level.", style: .error)
            case let .failure(error): showToast(error.localizedDescription, style: .error)
            }
        }
    }

    /// Applies the agent's operating mode: Pi's `/mode` effort ladder, Codex's sandbox policy,
    /// Claude Code's permission mode. All three are the same control to the user, so they are one
    /// entry point here even though only Pi's is a slash command rather than a protocol call.
    func setAgentMode(_ mode: String) {
        guard runtimeMatchesCurrentRoute, availableModes.contains(where: { $0.id == mode }) else { return }
        let slot = activeRuntimeSlot

        // For an agent whose ladder is its model list, this control and the model picker are the
        // same choice, so it goes down the same path rather than inventing a second one.
        if slot.capabilities.ladder == .models {
            guard let model = scopedModels.first(where: { $0.id == mode }) else { return }
            setModel(model)
            return
        }

        persistence.updateState { $0.agentModes[slot.agent.rawValue] = mode }

        if slot.agent == .pi {
            // Pi's mode lives in an extension, not the RPC surface, and the extension's own
            // status line is the authoritative reading afterwards.
            let title = availableModes.first { $0.id == mode }?.title ?? mode
            runExtensionCommand("/mode \(mode)", successToast: "Mode set to \(title)")
            return
        }

        let previous = runtimeMode
        runtimeMode = mode
        slot.mode = mode
        slot.runtime.send(type: "set_mode", payload: ["mode": .string(mode)]) { [weak self, weak slot] result in
            guard let self, let slot, slot === activeRuntimeSlot, runtimeMatchesCurrentRoute else { return }
            switch result {
            case let .success(response) where responseError(response) == nil:
                break
            case let .success(response):
                runtimeMode = previous
                slot.mode = previous
                showToast(responseError(response) ?? "\(slot.agent.displayName) rejected the mode.", style: .error)
            case let .failure(error):
                // Outcome-unknown must not be rolled back: the mode may well have applied.
                if !RPCFailureHandling.isOutcomeUnknown(error) {
                    runtimeMode = previous
                    slot.mode = previous
                }
                showToast(error.localizedDescription, style: .error)
            }
        }
    }

    /// Clears cached picker choices when the pending new chat switches agents; the old agent's
    /// models and levels are meaningless for the new one.
    private func resetRuntimeOptionsForNewChat() {
        availableModels = []
        availableThinkingLevels = ["off"]
        availableCommands = []
        commandsLoading = false
        composerOptionsLoading = false
        runtimeMode = persistence.state.agentModes[newChatAgent.rawValue]
            ?? newChatAgent.capabilities.modes.first(where: { $0.id == "default" })?.id
            ?? newChatAgent.capabilities.modes.first?.id
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
        guard let selectedExecutionFolder else { return false }
        return activeRuntimeStartedForNewChat
            && activeRuntimeCwd == selectedExecutionFolder.standardizedFileURL.path
    }

    private func requestComposerOptions(slot: RuntimeSlot? = nil) {
        let slot = slot ?? activeRuntimeSlot
        guard slot === activeRuntimeSlot, runtimeMatchesCurrentRoute else { composerOptionsLoading = false; return }
        guard !slot.optionsLoading, !slot.optionsPrepared else { return }
        slot.optionsLoading = true
        composerOptionsLoading = true
        requestCommandOptions(slot: slot)
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

    /// The composer palette's command list. `get_commands` is query-only (it is in
    /// `RPCTimeoutPolicy.stateQueries` and never sends a provider prompt), and it rides the same
    /// once-per-slot prewarm as the model and thinking pickers rather than any keystroke. Agents
    /// that cannot enumerate their commands are never asked.
    private func requestCommandOptions(slot: RuntimeSlot) {
        guard slot.capabilities.listsCommands else { return }
        slot.commandsLoading = true
        commandsLoading = true
        slot.runtime.send(type: "get_commands", payload: [:]) { [weak self, weak slot] result in
            guard let self, let slot else { return }
            slot.commandsLoading = false
            if case let .success(response) = result, responseError(response) == nil {
                slot.commands = AgentCommand.parse(response["data"]?["commands"])
            }
            // The slot keeps its own answer either way; only the visible route publishes, so a
            // late reply from a superseded or backgrounded runtime cannot overwrite the palette.
            guard slot === activeRuntimeSlot, runtimeMatchesCurrentRoute else { return }
            availableCommands = slot.commands
            commandsLoading = false
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
        objectWillChange.send()
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
    func showImage(_ image: ImagePayload, in group: [ImagePayload]) {
        viewedImage = ViewedImage(image: image, group: group)
    }

    func refreshSelectedGit() {
        selectedGitTask?.cancel()
        selectedGitTask = Task { [weak self] in await self?.refreshSelectedGitAndWait() }
    }

    private func resetSelectedGitDirectory(to url: URL) {
        selectedGitTask?.cancel()
        selectedWorkspaceTask?.cancel()
        selectedGitGeneration &+= 1
        selectedGitCandidatePath = nil
        let path = url.standardizedFileURL.path
        selectedGitDirectoryPath = path
        selectedGit = folderGit[path] ?? .none
        selectedWorktree = folderWorktrees[path]
    }

    private func updateSelectedWorkspace(from messages: [ChatMessage], for session: SessionSummary) {
        guard let directory = ConversationWorkspaceDetector.latestDirectory(in: messages, relativeTo: session.cwd) else {
            if selectedGitCandidatePath == nil { refreshSelectedGit() }
            return
        }
        observeSelectedWorkspace(directory, for: session)
    }

    /// A tool call is only adopted after Git confirms the explicit cwd/edit path belongs to a
    /// repository. A separate task prevents an ordinary status refresh from cancelling the move.
    private func observeSelectedWorkspace(_ directory: URL, for session: SessionSummary) {
        let sessionPath = session.fileURL.standardizedFileURL.path
        guard selectedSession?.fileURL.standardizedFileURL.path == sessionPath else { return }
        let sessionCwd = session.cwd.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = (candidate == sessionCwd || candidate.hasPrefix(sessionCwd + "/"))
            ? session.cwd.standardizedFileURL.path
            : directory.standardizedFileURL.path
        if let currentRoot = selectedWorktree.map({ URL(fileURLWithPath: $0.path, isDirectory: true).resolvingSymlinksInPath().path }),
           candidate == currentRoot || candidate.hasPrefix(currentRoot + "/") {
            selectedGitCandidatePath = candidatePath
            return
        }
        guard selectedGitCandidatePath != candidatePath else { return }

        selectedWorkspaceTask?.cancel()
        selectedGitGeneration &+= 1
        let generation = selectedGitGeneration
        selectedGitCandidatePath = candidatePath
        let service = gitService
        selectedWorkspaceTask = Task { [weak self] in
            guard let self else { return }
            let (_, snapshot, worktree) = await Self.fetchGitState(candidatePath, service: service)
            guard !Task.isCancelled, selectedGitGeneration == generation,
                  selectedSession?.fileURL.standardizedFileURL.path == sessionPath else { return }
            guard snapshot.isRepository || worktree != nil else {
                selectedGitCandidatePath = nil
                selectedWorkspaceTask = nil
                return
            }

            let targetPath = worktree.map { URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL.path }
                ?? candidatePath
            selectedGitDirectoryPath = targetPath
            folderGit[targetPath] = snapshot
            if let worktree { folderWorktrees[targetPath] = worktree }
            else { folderWorktrees.removeValue(forKey: targetPath) }
            selectedGit = snapshot
            selectedWorktree = worktree
            selectedWorkspaceTask = nil
        }
    }

    /// One awaited refresh at a time; a session follows the latest confirmed tool workspace,
    /// while a bare `selectedFolder` refreshes only after explicit selection. Global Desktop is
    /// still skipped by `fetchGitState`.
    private func refreshSelectedGitAndWait() async {
        if let session = selectedSession {
            let directory = selectedGitDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? session.cwd
            await refreshGit(for: directory)
            return
        }
        guard let folder = selectedFolder, hasOptedIntoGitRefresh(folder) else {
            selectedGit = .none
            selectedWorktree = nil
            return
        }
        let directory = selectedGitDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? folder
        await refreshGit(for: directory)
    }

    /// A project folder counts as opted into once the user chose it or it backs a real session.
    /// Global Desktop is never a project for Git-refresh purposes.
    private func hasOptedIntoGitRefresh(_ url: URL) -> Bool {
        guard !WorkspaceOrganization.isGlobalWorkingDirectory(url) else { return false }
        // A worktree this app just cut for the pending chat is opted in by construction: the
        // user asked for it, even though it is deliberately never a remembered folder.
        if WorktreeService.isManaged(url) { return true }
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

        // Derived here rather than threaded through every caller: the agent is a property of the
        // route, and every caller already supplies the route.
        let agent = agent(forSessionPath: sessionPath)
        let key = runtimeKey(agent: agent, cwd: cwd, sessionPath: sessionPath)
        if let parked = parkedRuntimes[key] {
            if parked.runtime.isRunning, parked.agent == agent {
                activateRuntime(parked)
                completeOrWait(for: parked, completion: completion)
                return
            }
            parkedRuntimes.removeValue(forKey: key)
        }

        if runtime.isRunning, activeRuntimeSlot.agent == agent, runtimeKey(for: activeRuntimeSlot) == key {
            if activePresentationDetached { restoreRuntimePresentation(activeRuntimeSlot) }
            completeOrWait(for: activeRuntimeSlot, completion: completion)
            return
        }

        let previous = activeRuntimeSlot
        if canReuseProcess(previous, agent: agent, in: cwd) {
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
                completion(.failure(AgentRuntimeError.processExited(
                    "Could not preserve the current \(previous.agent.displayName) run."
                )))
                return
            }
            saveActiveRuntimePresentation()
            parkedRuntimes[currentKey] = previous
            slot = RuntimeSlot(runtime: runtimeFactory(agent))
        } else if previous.agent == agent {
            removeParkedReference(to: previous)
            slot = RuntimeSlot(runtime: previous.runtime)
        } else {
            // A different agent needs a different binary, so the idle process cannot be reused
            // and would otherwise be orphaned: nothing else will ever stop it.
            removeParkedReference(to: previous)
            previous.runtime.onEvent = nil
            previous.runtime.stop()
            slot = RuntimeSlot(runtime: runtimeFactory(agent))
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

    private func canReuseProcess(_ slot: RuntimeSlot, agent: AgentKind, in cwd: URL) -> Bool {
        slot.agent == agent
            && slot.runtime.isRunning
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
        slot.commands.removeAll()
        slot.commandsLoading = false
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
        slot.outboxPromptPreflighting = false
        slot.outboxPromptAbortRequested = false
        slot.promptPreflightID = nil
        slot.pendingStartupPrompts = 0
        slot.deferredEvents.removeAll()
        slot.connectivityRetryAbortRequested = false
        slot.connectivityResumeCancelled = false
        slot.connectivityResumePreparing = false
        slot.connectivityResumeInFlight = false
        cancelProviderRetry(for: slot, resetAttempt: true)
        slot.isReady = false
        slot.isStarting = true
        slot.isSuperseded = false
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
            guard let self, let slot, !slot.isSuperseded else { return }
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
            guard let self, let slot, !slot.isSuperseded else { return }
            guard case let .success(response) = result, responseError(response) == nil else {
                if let onReuseFailure { onReuseFailure(); return }
                let error: Error
                switch result {
                case let .failure(value): error = value
                case let .success(response):
                    error = AgentRuntimeError.processExited(responseError(response) ?? "Pi rejected get_state.")
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
            let statusSnapshot = slot === activeRuntimeSlot && !activePresentationDetached
                ? extensionStatuses : slot.statuses
            replaceCachedStatuses(with: statusSnapshot)
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
        if let optimisticID, let promotedPath = promotedOrigin?.sessionPath {
            moveLiveMessage(
                id: optimisticID,
                from: submissionOrigin.sessionPath ?? Self.newChatDraftKey,
                to: promotedPath
            )
        }
        if command != "prompt", let optimisticID { removeOptimisticMessage(optimisticID, origin: origin) }
        if command == "prompt" {
            slot.connectivityResumeCancelled = false
            slot.connectivityResumeInFlight = false
            cancelProviderRetry(for: slot, resetAttempt: true)
            clearConnectivityWait(for: slot)
            slot.pendingTurn = PendingUserTurn(origin: origin, text: originalDraft, attachments: sentAttachments)
        }

        var payload: [String: JSONValue] = ["message": .string(prompt)]
        if !sentAttachments.isEmpty { payload["images"] = .array(sentAttachments.map(\.rpcValue)) }
        let wasStreaming = state(for: slot).isStreaming
        let previousPhase = state(for: slot).phase
        let preflightID = command == "prompt" ? UUID() : nil
        if command == "prompt" {
            slot.outboxPromptPreflighting = true
            slot.promptPreflightID = preflightID
            slot.promptBeganAt = Date()
            if slot === activeRuntimeSlot { cancelRuntimeRetirementLease() }
            updateState(for: slot) { state in
                state.clearRetryState()
                state.isStreaming = true
                state.phase = .waitingForModel
            }
            beginManagedTurnRecovery(for: slot)
        }

        slot.runtime.send(type: command, payload: payload) { [weak self, weak slot] result in
            guard let self, let slot, !slot.isSuperseded else { return }
            let errorText: String?
            var isOutcomeUnknown = false
            switch result {
            case let .success(response): errorText = responseError(response)
            case let .failure(error):
                errorText = error.localizedDescription
                isOutcomeUnknown = RPCFailureHandling.isOutcomeUnknown(error)
            }
            guard let errorText else {
                if command == "prompt" {
                    updateManagedTurn(for: slot) { $0.phase = ManagedTurnRecovery.accepted }
                }
                if command == "steer" { showToast("Steering message sent", style: .info) }
                if command == "follow_up" { showToast("Follow-up queued", style: .info) }
                if let preflightID { reconcilePromptPreflight(preflightID, slot: slot) }
                return
            }
            // An unconfirmed side-effecting command may already have reached Pi. Only settle or
            // process exit can safely resolve it without risking a duplicate prompt.
            if isOutcomeUnknown {
                showToast(errorText, style: .warning)
                return
            }
            if command == "prompt" {
                clearManagedTurnRecovery(for: slot)
                updateState(for: slot) { state in
                    state.isStreaming = wasStreaming
                    state.phase = previousPhase
                }
                if slot.promptPreflightID == preflightID {
                    slot.outboxPromptPreflighting = false
                    slot.outboxPromptAbortRequested = false
                    slot.promptPreflightID = nil
                }
                slot.promptBeganAt = nil
                slot.pendingTurn = nil
            }
            if let optimisticID { removeOptimisticMessage(optimisticID, origin: origin) }
            let restored = restoreDraft(text: originalDraft, attachments: sentAttachments, origin: origin)
            showToast(failureMessage(errorText, restored: restored, origin: origin), style: .error)
            if slot === activeRuntimeSlot { resetRuntimeRetirementLease(for: slot) }
            else if !state(for: slot).isBusy { retireBackgroundRuntime(slot) }
        }
    }

    private func reconcilePromptPreflight(_ preflightID: UUID, slot: RuntimeSlot) {
        slot.runtime.send(type: "get_state", payload: [:]) { [weak self, weak slot] result in
            guard let self, let slot, !slot.isSuperseded,
                  slot.promptPreflightID == preflightID,
                  case let .success(response) = result, responseError(response) == nil,
                  let isStreaming = response["data"]?["isStreaming"]?.boolValue else { return }
            updateState(for: slot) { state in
                state.isStreaming = isStreaming
                if !isStreaming { state.phase = .idle }
            }
            guard !isStreaming else { return }
            slot.outboxPromptPreflighting = false
            slot.outboxPromptAbortRequested = false
            slot.promptPreflightID = nil
            slot.promptBeganAt = nil
            slot.pendingTurn = nil
            clearManagedTurnRecovery(for: slot)
            if slot === activeRuntimeSlot { resetRuntimeRetirementLease(for: slot) }
            else if isIdleAndClean(slot) { retireBackgroundRuntime(slot) }
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

        if newChatWorktree?.standardizedFileURL.path == cwd.standardizedFileURL.path {
            newChatWorktree = nil
            newChatWorktreeOrigin = nil
            newChatWorktreeSubmitted = false
        }
        if slot === activeRuntimeSlot, case .newChat = route {
            route = .session(path)
            activities = []
        }
        return DraftOrigin(route: .session(path), sessionPath: path)
    }

    /// Disk pages never erase optimistic user content or a terminal RPC answer that has not yet
    /// reached JSONL. Once the durable equivalent appears, the overlay removes itself.
    private func replaceLoadedMessages(with loaded: [ChatMessage]) {
        guard !isBrowsingEarlierHistory else { return }
        var merged = loaded
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
        let bounded = enforcingLoadedImageBudget(merged)
        if messages != bounded { messages = bounded }
    }

    private func enforcingLoadedImageBudget(_ source: [ChatMessage]) -> [ChatMessage] {
        var result = source.count > Self.displayedMessageLimit
            ? Array(source.suffix(Self.displayedMessageLimit))
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
        if Self.sameOptimisticUserContent(live, candidate) {
            guard let candidateTime = candidate.timestamp, let liveTime = live.timestamp else { return false }
            return candidateTime >= liveTime.addingTimeInterval(-0.01)
        }
        guard candidate.role == live.role, candidate.textContent == live.textContent,
              candidate.toolCallID == live.toolCallID, candidate.isError == live.isError else { return false }
        if let candidateTime = candidate.timestamp, let liveTime = live.timestamp {
            return abs(candidateTime.timeIntervalSince(liveTime)) < 0.01
        }
        return candidate.id == live.id
    }

    private static func sameOptimisticUserContent(_ local: ChatMessage, _ candidate: ChatMessage) -> Bool {
        local.id.hasPrefix("local-") && candidate.role == .user
            && candidate.textContent == local.textContent && candidate.images.count == local.images.count
    }

    private func removeLiveMessage(id: String, path: String) {
        liveMessagesByPath[path]?.removeAll { $0.id == id }
        if liveMessagesByPath[path]?.isEmpty == true { liveMessagesByPath.removeValue(forKey: path) }
        liveMessageOrder.removeAll { $0.path == path && $0.id == id }
    }

    private func moveLiveMessage(id: String, from source: String, to destination: String) {
        guard source != destination,
              let message = liveMessagesByPath[source]?.first(where: { $0.id == id }) else { return }
        removeLiveMessage(id: id, path: source)
        retainLiveMessage(message, path: destination)
    }

    private func removeOptimisticMessage(_ id: String, origin: DraftOrigin) {
        removeLiveMessage(id: id, path: origin.sessionPath ?? Self.newChatDraftKey)
        messages.removeAll { $0.id == id }
    }

    private func retainLiveMessage(_ message: ChatMessage, path: String) {
        if !message.id.hasPrefix("local-"),
           let localID = liveMessagesByPath[path]?.last(where: {
               Self.sameOptimisticUserContent($0, message)
           })?.id {
            removeLiveMessage(id: localID, path: path)
        }
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
            // A conversation this app opened as a new chat is one it started. Recorded the
            // moment the agent names its file, which is the only point where the two are
            // known together.
            if slot.startedForNewChat, let owned = slot.sessionPath {
                persistence.recordAppStarted(sessionPath: owned)
            }
        }
    }

    private func handleRPCEvent(_ event: JSONValue, from slot: RuntimeSlot) {
        guard !slot.isSuperseded else { return }
        let wasBusy = state(for: slot).isBusy
        defer {
            if state(for: slot).isBusy != wasBusy { updateSleepPrevention() }
        }
        switch event["type"]?.stringValue {
        case "tool_execution_start": updateManagedTool(event, running: true, slot: slot)
        case "tool_execution_end": updateManagedTool(event, running: false, slot: slot)
        case "agent_settled": clearManagedTurnRecovery(for: slot)
        default: break
        }
        if event["type"]?.stringValue == "session_info_changed" {
            let name = event["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            updateState(for: slot) { $0.sessionName = name?.isEmpty == false ? name : nil }
            if let session = session(for: slot) {
                if let name, !name.isEmpty,
                   let index = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[index].name = name
                    sessions[index].prepareSearchKey()
                } else {
                    Task { await self.refreshSummary(for: session) }
                }
            }
            return
        }
        if event["type"]?.stringValue == "tool_execution_start",
           slot === activeRuntimeSlot, !activePresentationDetached,
           let session = session(for: slot),
           selectedSession?.fileURL.standardizedFileURL.path == session.fileURL.standardizedFileURL.path,
           let name = event["toolName"]?.stringValue,
           let directory = ConversationWorkspaceDetector.directory(
               toolName: name,
               arguments: event["args"] ?? .object([:]),
               relativeTo: session.cwd
           ) {
            observeSelectedWorkspace(directory, for: session)
        }
        if slot === activeRuntimeSlot, !activePresentationDetached {
            handleRPCEvent(event)
        } else {
            handleBackgroundRPCEvent(event, slot: slot)
        }
    }

    /// Publishes a live streaming delta, coalesced to `streamingPublishInterval`. The first
    /// delta after a quiet period publishes immediately; a burst keeps exactly one trailing
    /// publish scheduled with the newest payload.
    private func publishStreamingUpdate(_ partial: JSONValue) {
        let now = Date()
        if streamingPublishTask == nil, now.timeIntervalSince(lastStreamingPublish) >= Self.streamingPublishInterval {
            lastStreamingPublish = now
            if let parsed = SessionParser.chatMessage(fromAgentMessage: partial) {
                activeRuntimeSlot.streamingMessage = parsed
                if !isBrowsingEarlierHistory { streamingMessage = parsed }
            }
            return
        }
        pendingStreamingUpdate = partial
        guard streamingPublishTask == nil else { return }
        let route = self.route
        streamingPublishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let wait = Self.streamingPublishInterval - Date().timeIntervalSince(lastStreamingPublish)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000)) }
            streamingPublishTask = nil
            guard !Task.isCancelled, self.route == route, let pending = pendingStreamingUpdate else { return }
            pendingStreamingUpdate = nil
            lastStreamingPublish = Date()
            if let parsed = SessionParser.chatMessage(fromAgentMessage: pending) {
                activeRuntimeSlot.streamingMessage = parsed
                if !isBrowsingEarlierHistory { streamingMessage = parsed }
            }
        }
    }

    /// A settled or ended stream must never be resurrected by a stale trailing publish.
    private func cancelPendingStreamingPublish() {
        streamingPublishTask?.cancel()
        streamingPublishTask = nil
        pendingStreamingUpdate = nil
    }

    private func recordRuntimeOutput(for slot: RuntimeSlot) {
        if state(for: slot).phase != .working {
            updateState(for: slot) { $0.phase = .working }
        }
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
            let abortPreflight = slot.outboxPromptAbortRequested
            slot.outboxDispatches.removeAll()
            slot.outboxPromptPreflighting = false
            slot.outboxPromptAbortRequested = false
            slot.promptPreflightID = nil
            if slot.providerRetryPending || slot.providerRetryID != nil {
                cancelProviderRetry(for: slot, resetAttempt: false)
            }
            if slot === activeRuntimeSlot { cancelRuntimeRetirementLease() }
            updateState(for: slot) { state in
                state.isStreaming = true
                state.clearRetryState()
                if state.phase != .waitingForModel { state.phase = .working }
            }
            if abortPreflight { sendSoftAbort(to: slot) }
        case "agent_settled":
            let current = state(for: slot)
            let waitingForNetwork = current.isWaitingForNetwork
            let shouldRetryProvider = slot.providerRetryPending
            let retryErrorMessage = current.retryErrorMessage
            updateState(for: slot) { state in
                state.isStreaming = false
                state.clearRetryState()
                if shouldRetryProvider { state.retryErrorMessage = retryErrorMessage }
                state.phase = .idle
            }
            slot.connectivityResumeCancelled = false
            slot.connectivityResumeInFlight = false
            slot.capability = nil
            discardQuestionnaire(from: slot)
            slot.streamingMessage = nil
            slot.pendingTurn = nil
            slot.promptBeganAt = nil
            let startedFollowUp = waitingForNetwork || shouldRetryProvider
                ? false : flushBackgroundOutbox(.followUp, slot: slot)
            let session = session(for: slot)
            if let session { Task { await self.refreshSummary(for: session) } }
            if !startedFollowUp {
                if waitingForNetwork { resumeAfterConnectivityIfPossible(slot) }
                else if shouldRetryProvider { scheduleProviderRetry(for: slot) }
                else {
                    cancelProviderRetry(for: slot, resetAttempt: true)
                    if slot === activeRuntimeSlot { resetRuntimeRetirementLease(for: slot) }
                }
                scheduleFinalDurabilityCheck(for: slot, retireWhenDone: slot !== activeRuntimeSlot)
            }
        case "message_update":
            recordRuntimeOutput(for: slot)
            if let partial = event["message"], let parsed = SessionParser.chatMessage(fromAgentMessage: partial) {
                slot.streamingMessage = parsed
            }
        case "message_end":
            if event["message"]?["role"]?.stringValue == "assistant" { recordRuntimeOutput(for: slot) }
            slot.streamingMessage = nil
            if let raw = event["message"] {
                updateManagedProcesses(fromMessage: raw, slot: slot)
            }
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
                state.retryDelayMs = event["delayMs"]?.intValue.map { max(0, $0) }
                state.retryStartedAt = Date()
                state.retryErrorMessage = event["errorMessage"]?.stringValue?.suffixString(1_000)
            }
            pauseRetryForConnectivity(slot)
        case "auto_retry_end":
            let waitingForNetwork = state(for: slot).isWaitingForNetwork
            let succeeded = event["success"]?.boolValue == true
            updateState(for: slot) { state in
                state.clearRetryState()
                state.lastError = nil
                if !succeeded, !slot.connectivityResumeCancelled, !waitingForNetwork {
                    state.retryErrorMessage = event["finalError"]?.stringValue?.suffixString(1_000)
                }
            }
            if succeeded {
                cancelProviderRetry(for: slot, resetAttempt: true)
                clearConnectivityWait(for: slot)
            } else if !slot.connectivityResumeCancelled, !waitingForNetwork {
                slot.providerRetryPending = true
            }
        case "extension_ui_request":
            handleBackgroundExtensionUI(event, slot: slot)
        case "extension_error":
            updateState(for: slot) { $0.lastError = event["error"]?.stringValue ?? "A Pi extension failed." }
        case "tool_execution_end":
            updateManagedProcesses(fromToolEvent: event, slot: slot)
            if let id = event["toolCallId"]?.stringValue {
                if slot.capability?.sourceID == id { slot.capability = nil }
                if slot.questionnaire?.toolCallID == id { discardQuestionnaire(from: slot) }
            }
        case "turn_end":
            slot.capability = nil
            discardQuestionnaire(from: slot)
            if !state(for: slot).isWaitingForNetwork { _ = flushBackgroundOutbox(.steer, slot: slot) }
        case "message_start":
            if event["message"]?["role"]?.stringValue == "assistant" { recordRuntimeOutput(for: slot) }
        case "tool_execution_update", "bash_execution_update":
            recordRuntimeOutput(for: slot)
        case "turn_start":
            updateState(for: slot) { state in
                if state.isStreaming { state.phase = .waitingForModel }
            }
        case "agent_end", "summarization_retry_scheduled", "summarization_retry_attempt_start",
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
                if !ExtensionStatusParser.ephemeralKeys.contains(key) { cachedStatuses[key] = clean }
            } else {
                slot.statuses.removeValue(forKey: key)
                if !ExtensionStatusParser.ephemeralKeys.contains(key) { cachedStatuses.removeValue(forKey: key) }
            }
            persistence.cacheExtensionStatuses(cachedStatuses)
            if slot === activeRuntimeSlot, !activePresentationDetached { extensionStatuses = slot.statuses }
            // The turn already settled, so nothing else re-evaluates retirement once the last
            // subagent clears this key; without this the kept-alive process would never retire.
            if key == ExtensionStatusParser.subagentsKey {
                if slot === activeRuntimeSlot { resetRuntimeRetirementLease(for: slot) }
                else if isIdleAndClean(slot) { retireBackgroundRuntime(slot) }
            }
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
        if let questionnaire = slot.questionnaire,
           deferredRequest(event, belongsTo: questionnaire) {
            objectWillChange.send()
        }
        slot.deferredEvents.append(event.boundedProjection())
        if slot.deferredEvents.count > 32 { slot.deferredEvents.removeFirst(slot.deferredEvents.count - 32) }
    }

    @discardableResult
    private func flushBackgroundOutbox(_ boundary: OutboxEntry.Delivery, slot: RuntimeSlot) -> Bool {
        if boundary == .followUp { return dispatchNextFollowUp(for: slot) }
        let due = OutboxPolicy.due(slot.outbox, at: boundary)
        guard !due.isEmpty, slot.runtime.isRunning else { return false }
        slot.outbox = OutboxPolicy.removing(boundary, from: slot.outbox)
        for entry in due {
            let command = entry.delivery == .steer ? "steer" : "follow_up"
            let token = beginOutboxDispatch(for: slot)
            var payload: [String: JSONValue] = [
                "message": .string(ImageAttachment.prompt(text: entry.text, attachments: entry.attachments))
            ]
            if !entry.attachments.isEmpty { payload["images"] = .array(entry.attachments.map(\.rpcValue)) }
            slot.runtime.send(type: command, payload: payload) { [weak self] result in
                guard let self else { return }
                let definitelyRejected: Bool
                switch result {
                case let .success(response):
                    definitelyRejected = response["success"]?.boolValue == false
                case let .failure(error):
                    definitelyRejected = !RPCFailureHandling.isOutcomeUnknown(error)
                }
                if definitelyRejected { restoreOutboxEntry(entry, owner: token.owner) }
                finishOutboxDispatch(
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

    private static let liveManagedProcessStatuses: Set<String> = [
        "running", "terminating", "terminate_timeout"
    ]

    private func updateManagedProcesses(fromToolEvent event: JSONValue, slot: RuntimeSlot) {
        guard event["toolName"]?.stringValue?.lowercased() == "process",
              let details = event["result"]?["details"], details["success"]?.boolValue == true else { return }

        guard details["action"]?.stringValue == "start",
              let process = details["process"],
              let id = process["id"]?.stringValue,
              Self.liveManagedProcessStatuses.contains(process["status"]?.stringValue ?? "") else { return }
        let startedAt = process["startTime"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1_000) }
        setManagedProcesses(slot.managedProcessIDs.union([id]), startedAt: startedAt, slot: slot)
    }

    private func updateManagedProcesses(fromMessage message: JSONValue, slot: RuntimeSlot) {
        guard message["role"]?.stringValue == "custom",
              message["customType"]?.stringValue == "ad-process:update",
              let details = message["details"], details["kind"]?.stringValue == "lifecycle",
              let id = details["processId"]?.stringValue,
              ["exited", "killed"].contains(details["status"]?.stringValue ?? "") else { return }
        setManagedProcesses(slot.managedProcessIDs.subtracting([id]), slot: slot)
    }

    private func setManagedProcesses(_ ids: Set<String>, startedAt: Date? = nil, slot: RuntimeSlot) {
        guard ids != slot.managedProcessIDs else { return }
        let wasEmpty = slot.managedProcessIDs.isEmpty
        slot.managedProcessIDs = ids
        if ids.isEmpty { slot.managedProcessStartedAt = nil }
        else if wasEmpty { slot.managedProcessStartedAt = startedAt ?? Date() }
        else if let startedAt { slot.managedProcessStartedAt = min(slot.managedProcessStartedAt ?? startedAt, startedAt) }

        objectWillChange.send()
        updateSleepPrevention()
        if ids.isEmpty {
            if slot === activeRuntimeSlot { resetRuntimeRetirementLease(for: slot) }
            else if isIdleAndClean(slot) { retireBackgroundRuntime(slot) }
        } else if slot === activeRuntimeSlot {
            cancelRuntimeRetirementLease()
        }
    }

    private func retireBackgroundRuntime(_ slot: RuntimeSlot) {
        guard !slot.isSuperseded, slot !== activeRuntimeSlot, isIdleAndClean(slot) else { return }
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
    func handleRPCEventForTesting(_ event: JSONValue) { handleRPCEvent(event, from: activeRuntimeSlot) }

    private func handleRPCEvent(_ event: JSONValue) {
        let type = event["type"]?.stringValue ?? "unknown"
        let selected = isSelectedRuntime
        switch type {
        case "agent_start":
            let abortPreflight = activeRuntimeSlot.outboxPromptAbortRequested
            activeRuntimeSlot.outboxDispatches.removeAll()
            activeRuntimeSlot.outboxPromptPreflighting = false
            activeRuntimeSlot.outboxPromptAbortRequested = false
            activeRuntimeSlot.promptPreflightID = nil
            if activeRuntimeSlot.providerRetryPending || activeRuntimeSlot.providerRetryID != nil {
                cancelProviderRetry(for: activeRuntimeSlot, resetAttempt: false)
            }
            cancelRuntimeRetirementLease()
            runtimeState.isStreaming = true
            runtimeState.clearRetryState()
            if runtimeState.phase != .waitingForModel { runtimeState.phase = .working }
            if abortPreflight { sendSoftAbort(to: activeRuntimeSlot) }
        case "agent_settled":
            cancelPendingStreamingPublish()
            let waitingForNetwork = runtimeState.isWaitingForNetwork
            let shouldRetryProvider = activeRuntimeSlot.providerRetryPending
            let retryErrorMessage = runtimeState.retryErrorMessage
            runtimeState.isStreaming = false
            runtimeState.clearRetryState()
            if shouldRetryProvider { runtimeState.retryErrorMessage = retryErrorMessage }
            runtimeState.phase = .idle
            activeRuntimeSlot.connectivityResumeCancelled = false
            activeRuntimeSlot.connectivityResumeInFlight = false
            activeCapability = nil
            discardQuestionnaire()
            activeRuntimeSlot.streamingMessage = nil
            streamingMessage = nil
            if !waitingForNetwork, !shouldRetryProvider { flushOutbox(.followUp) }
            // The turn concluded (cleanly or with an in-band error message) with no ambiguity
            // left: nothing about this dispatch is "pending" any more.
            activeRuntimeSlot.promptBeganAt = nil
            activeTurnPrompt = nil
            requestStats()
            let settledSession = activeSession()
            Task {
                if let settledSession { await refreshSummary(for: settledSession) }
                if selectedSession?.fileURL.standardizedFileURL.path == settledSession?.fileURL.standardizedFileURL.path {
                    refreshSelectedGit()
                }
            }
            if waitingForNetwork { resumeAfterConnectivityIfPossible(activeRuntimeSlot) }
            else if shouldRetryProvider { scheduleProviderRetry(for: activeRuntimeSlot) }
            else {
                cancelProviderRetry(for: activeRuntimeSlot, resetAttempt: true)
                resetRuntimeRetirementLease(for: activeRuntimeSlot)
            }
            scheduleFinalDurabilityCheck(for: activeRuntimeSlot, retireWhenDone: false)
        case "message_update":
            recordRuntimeOutput(for: activeRuntimeSlot)
            guard selected, let partial = event["message"] else { return }
            publishStreamingUpdate(partial)
        case "message_end":
            if event["message"]?["role"]?.stringValue == "assistant" {
                recordRuntimeOutput(for: activeRuntimeSlot)
            }
            cancelPendingStreamingPublish()
            activeRuntimeSlot.streamingMessage = nil
            if let raw = event["message"] {
                updateManagedProcesses(fromMessage: raw, slot: activeRuntimeSlot)
            }
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
            updateManagedProcesses(fromToolEvent: event, slot: activeRuntimeSlot)
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
        case "auto_retry_start":
            runtimeState.isRetrying = true
            runtimeState.retryAttempt = event["attempt"]?.intValue
            runtimeState.retryDelayMs = event["delayMs"]?.intValue.map { max(0, $0) }
            runtimeState.retryStartedAt = Date()
            runtimeState.retryErrorMessage = event["errorMessage"]?.stringValue?.suffixString(1_000)
            pauseRetryForConnectivity(activeRuntimeSlot)
        case "auto_retry_end":
            let waitingForNetwork = runtimeState.isWaitingForNetwork
            let succeeded = event["success"]?.boolValue == true
            runtimeState.clearRetryState()
            runtimeState.lastError = nil
            if !succeeded, !activeRuntimeSlot.connectivityResumeCancelled, !waitingForNetwork {
                runtimeState.retryErrorMessage = event["finalError"]?.stringValue?.suffixString(1_000)
            }
            if succeeded {
                cancelProviderRetry(for: activeRuntimeSlot, resetAttempt: true)
                clearConnectivityWait(for: activeRuntimeSlot)
            } else if !activeRuntimeSlot.connectivityResumeCancelled, !waitingForNetwork {
                activeRuntimeSlot.providerRetryPending = true
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
            if !runtimeState.isWaitingForNetwork { flushOutbox(.steer) }
        case "message_start":
            if event["message"]?["role"]?.stringValue == "assistant" {
                recordRuntimeOutput(for: activeRuntimeSlot)
            }
        case "bash_execution_update":
            recordRuntimeOutput(for: activeRuntimeSlot)
        case "turn_start":
            if runtimeState.isStreaming { runtimeState.phase = .waitingForModel }
        case "agent_end", "summarization_retry_scheduled",
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
                // Individual events merge so a partially-started runtime cannot blank unrelated
                // values. A successful get_state later replaces the complete cache snapshot,
                // pruning statuses from extensions that are no longer loaded. Transient activity
                // is runtime-local and must never survive the process that reported it.
                if !ExtensionStatusParser.ephemeralKeys.contains(key) { cachedStatuses[key] = extensionStatuses[key] }
            } else {
                extensionStatuses.removeValue(forKey: key)
                if !ExtensionStatusParser.ephemeralKeys.contains(key) { cachedStatuses.removeValue(forKey: key) }
            }
            persistence.cacheExtensionStatuses(cachedStatuses)
            // Subagent activity gates retirement (see `isIdleAndClean`), and a settled turn has
            // no other trigger left, so the lease is re-evaluated whenever that key changes.
            if key == ExtensionStatusParser.subagentsKey {
                if extensionStatuses[key] == nil {
                    stopInactiveSubagentActivities()
                    refreshSelectedGit()
                }
                resetRuntimeRetirementLease(for: activeRuntimeSlot)
            }
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
        guard !slot.isSuperseded else { return }
        clearManagedTurnRecovery(for: slot)
        slot.managedProcessIDs.removeAll()
        slot.managedProcessStartedAt = nil
        slot.outboxDispatches.removeAll()
        slot.outboxPromptPreflighting = false
        slot.outboxPromptAbortRequested = false
        slot.promptPreflightID = nil
        slot.pendingStartupPrompts = 0
        slot.connectivityRetryAbortRequested = false
        slot.connectivityResumeCancelled = false
        slot.connectivityResumePreparing = false
        slot.connectivityResumeInFlight = false
        cancelProviderRetry(for: slot, resetAttempt: true)
        if slot === activeRuntimeSlot {
            cancelRuntimeRetirementLease()
            clearExtensionDialogs()
            updateState(for: slot) { state in
                state.isConnected = false
                state.isStreaming = false
                state.isCompacting = false
                state.clearRetryState()
                state.isWaitingForNetwork = false
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
                state.clearRetryState()
                state.isWaitingForNetwork = false
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
        guard !isBrowsingEarlierHistory else { return }
        var updated = messages
        if let index = updated.firstIndex(where: { $0.id == message.id }) { updated[index] = message }
        else if message.role == .user,
                let localIndex = updated.lastIndex(where: { Self.sameOptimisticUserContent($0, message) }) {
            updated[localIndex] = message
        } else { updated.append(message) }
        messages = enforcingLoadedImageBudget(updated)
    }

    private func mergeHistoryActivities() {
        guard !isBrowsingEarlierHistory else { return }
        activityProjectionTask?.cancel()
        let snapshot = messages
        let generation = conversationLoadGeneration
        let path = selectedSession?.fileURL.standardizedFileURL.path
        activityProjectionTask = Task { [weak self] in
            guard let self else { return }
            let history = await projectActivities(from: snapshot)
            guard !Task.isCancelled, conversationLoadGeneration == generation,
                  selectedSession?.fileURL.standardizedFileURL.path == path else { return }
            let live = activities.filter { $0.status == .running || $0.status == .waiting || $0.status == .queued }
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

    /// The subagents extension removes its status only after its final live job is gone.
    private func stopInactiveSubagentActivities() {
        Self.stopInactiveSubagents(in: &activities)
    }

    private static func stopInactiveSubagents(in items: inout [ActivityItem]) {
        let endedAt = Date()
        for index in items.indices
        where items[index].kind == .subagent
            && [.running, .waiting, .queued].contains(items[index].status) {
            items[index].status = .stopped
            items[index].endedAt = items[index].endedAt ?? endedAt
        }
    }

    private func responseError(_ response: JSONValue) -> String? {
        response["success"]?.boolValue == false ? (response["error"]?.stringValue ?? "Pi rejected the command.") : nil
    }

    private func refreshSummary(for session: SessionSummary) async {
        do {
            let summary = try await repository.refreshSummary(at: session.fileURL, archivedIDs: persistence.state.archivedSessionIDs)
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index] = summary
                refreshPullRequestStates(for: sessions)
            }
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
                if selectedGitDirectoryPath == path {
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
        if selectedGitDirectoryPath == normalized.path {
            selectedGit = snapshot
            selectedWorktree = worktree
        }
    }

    /// Fetches the status snapshot and the (optional) worktree indicator together, in parallel,
    /// so the worktree check (Task 2) never adds serial latency to the existing Git refresh.
    private static func fetchGitState(_ path: String, service: GitStatusProviding) async -> (String, GitSnapshot, GitWorktreeInfo?) {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard !WorkspaceOrganization.isGlobalWorkingDirectory(directory) else { return (path, .none, nil) }
        async let snapshot = service.snapshot(for: directory)
        async let worktree = service.worktreeInfo(for: directory)
        return await (path, snapshot, worktree)
    }

    private func startPullRequestRefreshLoop() {
        pullRequestRefreshLoopTask?.cancel()
        pullRequestRefreshLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard !Task.isCancelled, let self else { return }
                refreshPullRequestStates(for: sessions)
            }
        }
    }

    private func startGitRefreshLoop() {
        gitRefreshTask?.cancel()
        gitRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                // Awaited, not fire-and-forget: a slow repository cannot pile up refreshes.
                await refreshSelectedGitAndWait()
            }
        }
    }

    private func cancelConversationLoad() {
        conversationLoadTask?.cancel()
        conversationRefreshTask?.cancel()
        historyNavigationTask?.cancel()
        activityProjectionTask?.cancel()
        conversationLoadTask = nil
        conversationRefreshTask = nil
        historyNavigationTask = nil
        activityProjectionTask = nil
        refreshingConversationFingerprint = nil
        isConversationLoading = false
        isLoadingEarlierMessages = false
        isLoadingNewerMessages = false
    }

    func showToast(_ text: String, style: ToastMessage.Style, sessionPath: String? = nil) {
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
        gitRefreshTask?.cancel(); pullRequestRefreshTask?.cancel(); pullRequestRefreshLoopTask?.cancel()
        selectedGitTask?.cancel(); conversationLoadTask?.cancel(); conversationRefreshTask?.cancel()
        historyNavigationTask?.cancel(); activityProjectionTask?.cancel()
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
