import Foundation
import CryptoKit
import PiDeskKit

/// What happened to a message handed to a *live* Pi session, as opposed to one queued behind it.
enum LiveDelivery: Sendable, Equatable {
    /// Pi answered `success: true`.
    case acknowledged
    /// Pi answered `success: false`; the message did not take effect.
    case rejected(String)
    /// Written to Pi's stdin, but no acknowledgement arrived before the wait elapsed. Treated as
    /// delivered everywhere: re-queueing it could prompt Pi twice, and a duplicate prompt is a far
    /// worse failure than an unconfirmed one.
    case unacknowledged
}

/// The narrow slice of a running `PiRPCSession` that steering needs. A protocol purely so tests
/// can exercise the registry and the send handler with a fake instead of a real `pi` process.
protocol LiveRuntimeHandle: RuntimeRequesting {
    /// `command` is Pi's own RPC verb (`steer` or `follow_up`). Throws only when the write itself
    /// failed, which is the one case a caller may safely fall back to the queue from.
    func deliver(command: String, message: String) async throws -> LiveDelivery
}

/// The real handle: writes Pi's own `steer`/`follow_up` command into the live session and waits
/// briefly for its acknowledgement. The wait reads only what the run's consume loop has already
/// cached, so it can never contend with that loop for the pipe.
struct PiSessionRuntimeHandle: LiveRuntimeHandle {
    let session: PiRPCSession
    var ackTimeout: TimeInterval = 10

    func deliver(command: String, message: String) async throws -> LiveDelivery {
        let id = try session.send(type: command, payload: ["message": .string(message)])
        guard let response = await session.awaitCachedResponse(id: id, timeout: ackTimeout) else {
            return .unacknowledged
        }
        guard response["success"]?.boolValue == false else { return .acknowledged }
        return .rejected(response["error"]?.stringValue ?? "Pi rejected the message.")
    }

    func request(type: String, payload: [String: PiJSONValue]) async throws -> PiJSONValue {
        let id = try session.send(type: type, payload: payload)
        guard let response = await session.awaitCachedResponse(id: id, timeout: 30) else {
            throw RunnerError.timedOut(afterSeconds: 30)
        }
        return response
    }
}

/// Which threads currently have a daemon-owned `pi --mode rpc` process mid-run, so a message can
/// be steered into the turn in progress instead of queued behind it.
///
/// Two hazards shape this type, and both are about the *settlement boundary*:
///
/// 1. **A late write into a process being stopped.** Admission is closed under the same lock a
///    delivery claims its reservation with, so a caller either gets in before the run finishes or
///    finds nothing and falls back to a fresh queued run. There is no window in between, and the
///    executor never stops a session while a reservation is outstanding.
/// 2. **A message accepted and then killed.** Pi acknowledges a `follow_up`, then the
///    `agent_settled` for the turn already in progress arrives and the executor would stop the
///    session — discarding the message it just accepted, because a follow-up runs as its *own*
///    later turn. Such a delivery therefore banks a *turn credit*, and the executor must spend
///    those credits before admission can close.
///
///    A `steer` is different and must not bank one: Pi folds it into the turn already running, so
///    the very next `agent_settled` **is** that message's settle. Crediting it would make the
///    executor wait for a second turn that never starts, stalling the run until its deadline and
///    recording a successful conversation as a timeout. The single exception is a steer still
///    in flight when the boundary arrives — it may have landed too late to be folded in, so if it
///    could have been delivered at all, the run conservatively continues once.
///
/// 3. **A process stopped out from under a delivery.** A timeout or an abort does not arrive at a
///    settle boundary; it arrives whenever it likes, including mid-write. `drainForShutdown`
///    closes admission for good and waits, boundedly, for those writes to finish, so the executor
///    never kills a session whose acknowledgement its HTTP caller is still waiting for.
///
/// Entries are keyed by thread but generation-checked by run id: two runs on one thread cannot
/// overlap (`RunQueue` enforces per-thread mutual exclusion), but their registrations still can,
/// and a run that settles just after its successor registered must not retire the wrong session.
final class LiveSessionRegistry: @unchecked Sendable {
    /// How many extra turns one run may be extended through before it stops accepting more. A
    /// steering conversation is legitimate; an unbounded one is a way to keep a run alive forever.
    static let maxTurnCredits = 8

    /// The result of asking to close a run's admission at a settle boundary.
    enum CloseOutcome: Equatable {
        /// Admission is closed. Nothing else can reach this session; the run may finish.
        case closed
        /// A delivery was accepted since the last boundary and owns the turn that is starting.
        /// The executor must keep consuming rather than treating this settle as the end.
        case continueConsuming
        /// A write/ack is in flight right now. The executor must keep consuming and retry
        /// shortly; stopping the session here is exactly the race this type exists to prevent.
        case busy
    }

    private final class Entry {
        let runID: String
        let handle: LiveRuntimeHandle
        var admitting = true
        var inFlight = 0
        var turnCredits = 0
        /// Credits *reserved or granted* over this run's life, never decremented on spend: the
        /// lifetime extension budget. Taken under the lock at reservation time rather than at
        /// release, because a hundred simultaneous follow-ups would otherwise each observe an
        /// untouched budget and every one of them would be admitted.
        var committedCredits = 0
        /// A settle boundary was reached while deliveries were still in flight. Those deliveries
        /// crossed it, so their outcome decides whether the run continues.
        var boundaryPending = false

        init(runID: String, handle: LiveRuntimeHandle) {
            self.runID = runID
            self.handle = handle
        }
    }

    /// One reservation's claim on the entry, decided under the lock that admitted it.
    private struct Reservation {
        let entry: Entry
        /// True when this delivery already holds a turn credit, so its release either spends it
        /// or refunds it — it never has to re-check a budget that may have moved meanwhile.
        let holdsCredit: Bool
    }

    private let lock = NSLock()
    private var entries: [ThreadInstanceKey: Entry] = [:]

    init() {}

    func register(thread: ThreadInstanceKey, runID: String, handle: LiveRuntimeHandle) {
        lock.lock(); entries[thread] = Entry(runID: runID, handle: handle); lock.unlock()
    }

    func register(threadID: String, runID: String, handle: LiveRuntimeHandle) {
        register(thread: ThreadInstanceKey(path: threadID), runID: runID, handle: handle)
    }

    /// No-op unless `runID` still owns the slot, so a late unregister cannot retire its successor.
    func unregister(thread: ThreadInstanceKey, runID: String) {
        lock.lock()
        if entries[thread]?.runID == runID { entries.removeValue(forKey: thread) }
        lock.unlock()
    }

    func unregister(threadID: String, runID: String) {
        unregister(thread: ThreadInstanceKey(path: threadID), runID: runID)
    }

    func liveRunID(thread: ThreadInstanceKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        let entry = entries[thread]
        return entry?.admitting == true ? entry?.runID : nil
    }

    func liveRunID(threadID: String) -> String? {
        liveRunID(thread: ThreadInstanceKey(path: threadID))
    }

    var liveThreadIDs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.filter { $0.value.admitting }.keys.map(\.path))
    }

    /// Called by the executor when it sees `agent_settled`. See `CloseOutcome`.
    ///
    /// `.busy` closes admission too: a caller arriving during that window must fall back to a
    /// queued run rather than write into a session that is one instant from being stopped.
    /// Admission reopens only when the run genuinely continues into a credited turn.
    func closeAdmission(thread: ThreadInstanceKey, runID: String) -> CloseOutcome {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[thread], entry.runID == runID else { return .closed }
        if entry.inFlight > 0 {
            entry.admitting = false
            entry.boundaryPending = true
            return .busy
        }
        entry.boundaryPending = false
        if entry.turnCredits > 0 {
            entry.turnCredits -= 1
            entry.admitting = true
            return .continueConsuming
        }
        entry.admitting = false
        return .closed
    }

    func closeAdmission(threadID: String, runID: String) -> CloseOutcome {
        closeAdmission(thread: ThreadInstanceKey(path: threadID), runID: runID)
    }

    /// `nil` means "nothing reached Pi" — no live turn, admission already closed, the credit bound
    /// was reached, or the write itself failed — and is the *only* outcome a caller may safely
    /// re-send from. Every other case, including `.unacknowledged`, means the message may already
    /// have been applied: re-queueing it would risk prompting Pi twice.
    func deliver(thread: ThreadInstanceKey, command: String, message: String) async -> (runID: String, result: LiveDelivery)? {
        guard let reservation = reserve(thread: thread, command: command) else { return nil }
        do {
            let result = try await reservation.entry.handle.deliver(command: command, message: message)
            release(reservation, result: result)
            return (reservation.entry.runID, result)
        } catch {
            // The write failed (the process exited between reservation and send, or Pi stopped
            // accepting input), so nothing reached Pi and sending it again cannot duplicate
            // anything — and it owes no turn either way.
            release(reservation, result: nil)
            return nil
        }
    }

    func deliver(threadID: String, command: String, message: String) async -> (runID: String, result: LiveDelivery)? {
        await deliver(thread: ThreadInstanceKey(path: threadID), command: command, message: message)
    }

    /// Holds the live process across a complete runtime query/mutation, so a settle event cannot
    /// stop Pi between `set_model` and the authoritative state/options refresh that follows it.
    func withRuntime<T: Sendable>(
        thread: ThreadInstanceKey,
        operation: @Sendable (RuntimeRequesting) async throws -> T
    ) async throws -> T? {
        guard let entry = reserveRuntime(thread: thread) else { return nil }
        do {
            let result = try await operation(entry.handle)
            releaseRuntime(entry)
            return result
        } catch {
            releaseRuntime(entry)
            throw error
        }
    }

    func withRuntime<T: Sendable>(
        threadID: String,
        operation: @Sendable (RuntimeRequesting) async throws -> T
    ) async throws -> T? {
        try await withRuntime(thread: ThreadInstanceKey(path: threadID), operation: operation)
    }

    /// How long a run ending on a timeout or an abort may wait for deliveries already mid-write.
    /// A healthy Pi acknowledges in milliseconds and a wedged one will not answer however long
    /// this is, so the bound is kept small: it must stay well inside the shutdown budget the app
    /// allows the daemon (docs/daemon-api.md, "Shutdown").
    static let drainSeconds: TimeInterval = 3

    /// The shutdown counterpart to `closeAdmission`: this is not a settle boundary the run may
    /// continue past, it is the run ending. Admission closes unconditionally and any outstanding
    /// credits are dropped, then in-flight deliveries are given until `deadline` to finish.
    ///
    /// `pump` runs between polls so the caller can keep reading Pi's output: an in-flight
    /// delivery is waiting on an acknowledgement that only arrives if somebody is still consuming
    /// the pipe, and its caller must not be told "outcome unknown" for a reply that was sitting
    /// unread when the process was killed. It returns false when waiting has become pointless
    /// (the process is gone), which ends the drain early.
    ///
    /// Returns true when nothing is in flight any more.
    @discardableResult
    func drainForShutdown(thread: ThreadInstanceKey, runID: String, deadline: Date, pump: () async -> Bool) async -> Bool {
        while true {
            guard closeForShutdown(thread: thread, runID: runID) > 0 else { return true }
            guard Date() < deadline, await pump() else { return false }
        }
    }

    func drainForShutdown(threadID: String, runID: String, deadline: Date, pump: () async -> Bool) async -> Bool {
        await drainForShutdown(
            thread: ThreadInstanceKey(path: threadID), runID: runID, deadline: deadline, pump: pump
        )
    }

    /// Closes admission for good and reports how many deliveries are still mid-write.
    private func closeForShutdown(thread: ThreadInstanceKey, runID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[thread], entry.runID == runID else { return 0 }
        entry.admitting = false
        entry.boundaryPending = false
        entry.turnCredits = 0
        return entry.inFlight
    }

    // Plain synchronous helpers rather than `lock()`/`unlock()` written inside `deliver`'s async
    // body: `NSLock` is unavailable there, since an async function can resume on a different
    // thread than the one that suspended it.
    private func reserve(thread: ThreadInstanceKey, command: String) -> Reservation? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[thread], entry.admitting else { return nil }
        // A follow-up runs as its own later turn, so its capacity is taken here, under the lock
        // that admits it, not when it lands. Refuse rather than extend a run indefinitely: past
        // the bound the caller queues a fresh run, which is bounded by its own timeout like any
        // other. A steer joins the turn already running and reserves nothing.
        let needsCredit = command == Self.followUpCommand
        if needsCredit {
            guard entry.committedCredits < Self.maxTurnCredits else { return nil }
            entry.committedCredits += 1
        }
        entry.inFlight += 1
        return Reservation(entry: entry, holdsCredit: needsCredit)
    }

    private func reserveRuntime(thread: ThreadInstanceKey) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[thread], entry.admitting else { return nil }
        entry.inFlight += 1
        return entry
    }

    private func releaseRuntime(_ entry: Entry) {
        lock.lock(); entry.inFlight -= 1; lock.unlock()
    }

    /// Decides, under the lock, whether this delivery owes the run another turn.
    ///
    /// - a rejected or unwritten message never ran, so it owes nothing and refunds the capacity
    ///   it reserved;
    /// - a `follow_up` runs as its own later turn, so it spends the credit it reserved;
    /// - a `steer` is folded into the turn already running, so it owes nothing — unless it was
    ///   still in flight when the settle boundary arrived, in which case it may have missed that
    ///   turn, and one extra turn is the conservative reading. One turn covers *every* steer that
    ///   crossed the same boundary: they all raced the same settle, and crediting each of them
    ///   would extend the run once per concurrent write.
    private func release(_ reservation: Reservation, result: LiveDelivery?) {
        lock.lock()
        defer { lock.unlock() }
        let entry = reservation.entry
        entry.inFlight -= 1
        let mayHaveApplied: Bool
        switch result {
        case .acknowledged, .unacknowledged: mayHaveApplied = true
        case .rejected, nil: mayHaveApplied = false
        }
        if reservation.holdsCredit {
            if mayHaveApplied { entry.turnCredits += 1 } else { entry.committedCredits -= 1 }
            return
        }
        guard mayHaveApplied, entry.boundaryPending, entry.committedCredits < Self.maxTurnCredits else { return }
        entry.committedCredits += 1
        entry.turnCredits += 1
        entry.boundaryPending = false
    }

    /// Pi's own verb for a message that runs after the current turn, as opposed to `steer`, which
    /// joins it.
    static let followUpCommand = "follow_up"
}

/// Every `extension_ui_request` a daemon run is currently blocked on, plus the way to answer it.
///
/// The daemon never answers on a user's behalf. The only automatic action is an *expiry*, which
/// sends Pi an explicit cancellation so a run whose dialog nobody ever saw unwinds in bounded
/// time instead of holding a session open until the run's own timeout.
final class InteractionRegistry: @unchecked Sendable {
    /// Throwing, so a write that never reached Pi is visible to the caller instead of being
    /// reported as an answered dialog.
    typealias Responder = @Sendable ([String: PiJSONValue]) throws -> Void

    /// Matches the app's own `dialogQueueLimit` intent: past this, a further request is answered
    /// with an immediate cancellation rather than silently swallowed.
    static let maxPending = 16
    static let defaultTimeout: TimeInterval = 600
    static let maxTimeout: TimeInterval = 1_800

    private struct Entry {
        let token: UUID
        var interaction: PendingInteraction
        let responder: Responder
        var isResolving = false
        var retireOnFailure = false
        var cancelOnFailure = false
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let logger: DaemonLogger?
    private let timerQueue = DispatchQueue(label: "dev.pi.desktop.daemon.interactions")
    private var bus: EventBus?

    init(logger: DaemonLogger? = nil) {
        self.logger = logger
    }

    /// Wired once at startup. The bus is built inside `DaemonCore`, which is constructed after
    /// the executor that owns this registry, so the two are joined here rather than in an
    /// initialiser.
    func attach(bus: EventBus) {
        lock.lock(); self.bus = bus; lock.unlock()
    }

    /// `false` means the registry is full and the caller must cancel the request itself — Pi is
    /// blocked, so dropping it on the floor is never an option.
    func register(_ interaction: PendingInteraction, responder: @escaping Responder) -> Bool {
        lock.lock()
        guard entries.count < Self.maxPending, entries[interaction.id] == nil else {
            lock.unlock()
            return false
        }
        let token = UUID()
        entries[interaction.id] = Entry(
            token: token, interaction: interaction, responder: responder
        )
        bus?.publish(.interaction(interaction))
        lock.unlock()

        let delay = max(1, interaction.expiresAt.timeIntervalSince(Date()))
        timerQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.expire(id: interaction.id, token: token)
        }
        return true
    }

    func pending(threadID: String? = nil) -> [PendingInteraction] {
        lock.lock(); defer { lock.unlock() }
        return entries.values
            .map(\.interaction)
            .filter { threadID == nil || $0.threadPath == threadID || $0.threadId == threadID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func interaction(id: String) -> PendingInteraction? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.interaction
    }

    enum RespondResult: Equatable {
        case answered
        /// No such dialog: already answered, expired, or its run ended.
        case notFound
        /// Another caller is currently delivering this answer. The dialog remains pending until
        /// that write succeeds or fails.
        case inFlight
        /// The write to Pi failed. A normal answer stays pending for retry; expiry or run shutdown
        /// may retire it after making their own final cancellation decision.
        case writeFailed(String)
    }

    /// Answers a pending dialog. Exactly one of `value`/`confirmed` may be set, or `cancelled`;
    /// the caller validates that against the dialog's method before getting here.
    @discardableResult
    func respond(id: String, value: String?, confirmed: Bool?, cancelled: Bool) -> RespondResult {
        var response: [String: PiJSONValue] = ["type": .string("extension_ui_response"), "id": .string(id)]
        if cancelled { response["cancelled"] = .bool(true) }
        else if let confirmed { response["confirmed"] = .bool(confirmed) }
        else if let value { response["value"] = .string(value) }
        else { response["cancelled"] = .bool(true) }
        return resolve(id: id, response: response)
    }

    /// Cancels everything still pending for a run that is ending, so a finished run never leaves
    /// a dialog on a phone that can no longer be answered. A write failure here is expected (the
    /// session may already be gone), so the entry is dropped regardless.
    func cancelAll(runID: String) {
        lock.lock()
        let targets = entries.values.filter { $0.interaction.runId == runID }.map {
            (id: $0.interaction.id, token: $0.token)
        }
        lock.unlock()
        for target in targets {
            let result = cancel(
                id: target.id, token: target.token, cancelAfterFailedAnswer: false
            )
            if case let .writeFailed(reason) = result {
                logger?.warn("Could not cancel interaction \(target.id) on its run ending: \(reason)")
            }
        }
    }

    private func expire(id: String, token: UUID) {
        logger?.info("Interaction \(id) expired without an answer; cancelling so the run can continue.")
        let result = cancel(id: id, token: token, cancelAfterFailedAnswer: true)
        if case let .writeFailed(reason) = result {
            logger?.warn("Could not cancel expired interaction \(id): \(reason)")
        }
    }

    private func cancel(
        id: String, token: UUID, cancelAfterFailedAnswer: Bool
    ) -> RespondResult {
        lock.lock()
        guard var entry = entries[id], entry.token == token else {
            lock.unlock()
            return .notFound
        }
        if entry.isResolving {
            if cancelAfterFailedAnswer, !entry.retireOnFailure {
                entry.cancelOnFailure = true
            } else {
                entry.retireOnFailure = true
                entry.cancelOnFailure = false
            }
            entries[id] = entry
            lock.unlock()
            return .inFlight
        }
        entry.isResolving = true
        // This call is itself the final cancellation attempt. If its write fails, the session is
        // no longer answerable and the stale UI card must still retire.
        entry.retireOnFailure = true
        entries[id] = entry
        lock.unlock()
        return deliver(
            id: id, token: token, entry: entry,
            response: Self.cancellationResponse(id: id)
        )
    }

    /// The entry remains authoritative while the write is in flight. This keeps list responses,
    /// duplicate registration, and concurrent answer attempts consistent with the actual pipe.
    private func resolve(id: String, response: [String: PiJSONValue]) -> RespondResult {
        lock.lock()
        guard var entry = entries[id] else {
            lock.unlock()
            return .notFound
        }
        guard !entry.isResolving else {
            lock.unlock()
            return .inFlight
        }
        entry.isResolving = true
        entries[id] = entry
        lock.unlock()

        return deliver(id: id, token: entry.token, entry: entry, response: response)
    }

    private func deliver(
        id: String, token: UUID, entry: Entry, response: [String: PiJSONValue]
    ) -> RespondResult {
        do {
            try entry.responder(response)
        } catch {
            lock.lock()
            guard var current = entries[id], current.token == token, current.isResolving else {
                lock.unlock()
                return .writeFailed("\(error)")
            }
            if current.cancelOnFailure, !current.retireOnFailure {
                current.cancelOnFailure = false
                current.retireOnFailure = true
                entries[id] = current
                let responder = current.responder
                lock.unlock()
                do {
                    try responder(Self.cancellationResponse(id: id))
                } catch {
                    logger?.warn("Could not cancel interaction \(id) after its answer failed: \(error)")
                }
                retire(id: id, token: token)
            } else {
                if current.retireOnFailure {
                    entries.removeValue(forKey: id)
                    current.interaction.resolvedAt = Date()
                    bus?.publish(.interaction(current.interaction))
                } else {
                    current.isResolving = false
                    entries[id] = current
                }
                lock.unlock()
            }
            return .writeFailed("\(error)")
        }

        retire(id: id, token: token)
        return .answered
    }

    private func retire(id: String, token: UUID) {
        lock.lock()
        guard var resolved = entries[id], resolved.token == token else {
            lock.unlock()
            return
        }
        entries.removeValue(forKey: id)
        resolved.interaction.resolvedAt = Date()
        bus?.publish(.interaction(resolved.interaction))
        lock.unlock()
    }

    private static func cancellationResponse(id: String) -> [String: PiJSONValue] {
        [
            "type": .string("extension_ui_response"),
            "id": .string(id),
            "cancelled": .bool(true)
        ]
    }
}

/// De-duplicates `POST /v1/threads/{id}/messages` by the caller's own submission id.
///
/// A phone loses the response to a send far more often than it loses the request: the tunnel drops
/// while the daemon is already enqueueing. Without this, the reader sees a failed message, taps
/// Retry, and Pi is prompted twice. Repeating a `(thread, clientId)` pair therefore replays the
/// original `SendMessageResponse` rather than delivering or enqueueing anything a second time.
///
/// This is independent of, and does not weaken, the hosted relay's own mutation counter: that
/// rejects a *replayed ciphertext frame* outright, while this replays a response to a legitimately
/// re-sent request.
actor SubmissionRegistry {
    static let maxEntries = 256
    static let entryTTL: TimeInterval = 1_800
    static let maxWaitersPerEntry = 16

    struct Ownership: Equatable, Sendable {
        fileprivate let id: UUID
    }

    enum Claim: Equatable, Sendable {
        /// First time this submission has been seen; the caller owns it.
        case proceed(Ownership)
        /// Already completed: return this exact response again.
        case replay(SendMessageResponse)
        /// An identical submission is being processed right now. The caller must not start a
        /// second one; it reports a conflict and the client retries.
        case inFlight
        /// A previous daemon stopped after durably claiming this id but before persisting its
        /// answer. Automatic replay is unsafe because the prompt may already have been accepted.
        case outcomeUnknown
        /// The caller reused an id for a different message or delivery mode.
        case conflict
        /// Every slot holds a submission that has not finished yet. Evicting one to make room
        /// would un-protect a send that is still running, so the *new* one is refused instead:
        /// a `503` the client can retry, rather than a duplicate prompt it cannot take back.
        case overloaded
        /// Replay protection could not be made durable, so the message is refused before any
        /// delivery attempt.
        case unavailable(String)

        var ownership: Ownership? {
            guard case let .proceed(value) = self else { return nil }
            return value
        }
    }

    struct MessageLookup: Equatable, Sendable {
        let thread: ThreadInstanceKey
        let claim: Claim
    }

    enum CreationClaim: Equatable, Sendable {
        case proceed(Ownership)
        case replay(CreateThreadResponse)
        case inFlight
        case outcomeUnknown
        case conflict
        case overloaded
        case unavailable(String)
    }

    enum ScheduleRunClaim: Equatable, Sendable {
        case proceed(Ownership)
        case replay(ScheduleRunResponse)
        case inFlight
        case outcomeUnknown
        case conflict
        case overloaded
        case unavailable(String)
    }

    private enum RawClaim {
        case proceed(Ownership)
        case replay(Payload)
        case inFlight
        case outcomeUnknown
        case conflict
        case overloaded
        case unavailable(String)
    }

    private enum Payload: Codable, Equatable, Sendable {
        case message(SendMessageResponse)
        case creation(CreateThreadResponse)
        case scheduleRun(ScheduleRunResponse)
    }

    private enum State {
        case inFlight(since: Date, owner: Ownership, fingerprint: String)
        case outcomeUnknown(since: Date, fingerprint: String?)
        case done(Payload, at: Date, fingerprint: String)
    }

    private struct Key: Hashable {
        let scope: String
        let clientID: String
    }

    private struct PersistedEnvelope: Codable {
        let version: Int
        let entries: [PersistedEntry]
    }

    private struct PersistedEntry: Codable {
        /// Version 2 identity. Version 1 used only `threadPath` for message submissions.
        let scope: String?
        let threadPath: String?
        let clientID: String
        let requestFingerprint: String?
        let state: String
        let payload: Payload?
        /// Non-path identifiers used to reach a message entry before mutable thread resolution.
        let messageAliases: [String]?
        /// Version 1 response shape, retained only for safe migration.
        let response: SendMessageResponse?
        let timestamp: Date
    }

    private var states: [Key: State] = [:]
    private var order: [Key] = []
    private var waiters: [Key: [UUID: CheckedContinuation<Payload?, Never>]] = [:]
    private var messageAliases: [Key: [String]] = [:]
    private let fileURL: URL?
    private let logger: DaemonLogger?
    private var persistenceHealthy = true
    private static let persistedVersion = 2
    private static let maximumPersistedBytes = 2 * 1_024 * 1_024
    private static let maxMessageAliases = 2
    private static let maxMessageAliasBytes = 512

    init(fileURL: URL? = nil, logger: DaemonLogger? = nil) {
        self.fileURL = fileURL
        self.logger = logger
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= Self.maximumPersistedBytes,
              let data = FileManager.default.contents(atPath: fileURL.path),
              let envelope = try? PiDeskJSON.decoder.decode(PersistedEnvelope.self, from: data),
              (1...Self.persistedVersion).contains(envelope.version),
              envelope.entries.count <= Self.maxEntries else {
            persistenceHealthy = false
            logger?.error(Self.corruptPersistenceMessage)
            return
        }

        var loaded: [Key: State] = [:]
        var loadedOrder: [Key] = []
        var loadedAliases: [Key: [String]] = [:]
        for entry in envelope.entries {
            let scope: String
            if let value = entry.scope {
                scope = value
            } else if let path = entry.threadPath {
                scope = Self.messageScope(ThreadInstanceKey(path: path))
            } else {
                persistenceHealthy = false
                logger?.error(Self.corruptPersistenceMessage)
                return
            }
            guard Self.isValidScope(scope), Self.isValidClientID(entry.clientID),
                  entry.timestamp.timeIntervalSinceReferenceDate.isFinite else {
                persistenceHealthy = false
                logger?.error(Self.corruptPersistenceMessage)
                return
            }
            let key = Key(scope: scope, clientID: entry.clientID)
            guard loaded[key] == nil else {
                persistenceHealthy = false
                logger?.error(Self.corruptPersistenceMessage)
                return
            }
            guard let aliases = Self.validatedPersistedAliases(
                entry.messageAliases ?? [], scope: scope
            ) else {
                persistenceHealthy = false
                logger?.error(Self.corruptPersistenceMessage)
                return
            }

            let storedPayload = entry.payload ?? entry.response.map(Payload.message)
            let fingerprint = entry.requestFingerprint
            switch entry.state {
            case "done":
                guard let storedPayload, entry.payload == nil || entry.response == nil else {
                    persistenceHealthy = false
                    logger?.error(Self.corruptPersistenceMessage)
                    return
                }
                if let fingerprint, Self.isValidFingerprint(fingerprint) {
                    loaded[key] = .done(storedPayload, at: entry.timestamp, fingerprint: fingerprint)
                } else if envelope.version == 1 {
                    // An old answer has no request hash. Replaying it for arbitrary text is not
                    // safe, so retain the id as an explicit ambiguous outcome.
                    loaded[key] = .outcomeUnknown(since: entry.timestamp, fingerprint: nil)
                } else {
                    persistenceHealthy = false
                    logger?.error(Self.corruptPersistenceMessage)
                    return
                }
            case "inFlight", "outcomeUnknown":
                guard storedPayload == nil,
                      fingerprint.map(Self.isValidFingerprint) ?? true else {
                    persistenceHealthy = false
                    logger?.error(Self.corruptPersistenceMessage)
                    return
                }
                // No handler from the prior process exists to finish this claim.
                loaded[key] = .outcomeUnknown(since: entry.timestamp, fingerprint: fingerprint)
            default:
                persistenceHealthy = false
                logger?.error(Self.corruptPersistenceMessage)
                return
            }
            loadedOrder.append(key)
            if !aliases.isEmpty { loadedAliases[key] = aliases }
        }
        states = loaded
        order = loadedOrder
        messageAliases = loadedAliases
    }

    /// Finds a retained message claim without creating one. Exact paths work for every ledger
    /// version; bounded aliases let an id or prefix replay after the transcript disappears.
    func lookupMessage(
        reference: String,
        clientID: String,
        requestFingerprint: String,
        now: Date = Date()
    ) -> MessageLookup? {
        prune(now: now)
        guard Self.isValidClientID(clientID),
              Self.isValidFingerprint(requestFingerprint) else { return nil }

        var candidates = Set<Key>()
        if reference.contains("/") {
            let thread = ThreadInstanceKey(path: reference)
            let key = Key(scope: Self.messageScope(thread), clientID: clientID)
            if states[key] != nil { candidates.insert(key) }
        } else if let alias = Self.normalizedMessageAlias(reference) {
            for (key, aliases) in messageAliases
            where key.clientID == clientID && aliases.contains(alias) {
                candidates.insert(key)
            }
        }
        guard candidates.count == 1, let key = candidates.first,
              let thread = Self.messageThread(from: key.scope),
              let raw = existingRawClaim(
                key: key, requestFingerprint: requestFingerprint
              ) else { return nil }
        return MessageLookup(thread: thread, claim: Self.messageClaim(from: raw))
    }

    func claim(
        thread: ThreadInstanceKey,
        clientID: String,
        requestFingerprint: String = SubmissionRegistry.fingerprint(parts: ["unspecified"]),
        messageAliases aliases: [String] = [],
        now: Date = Date()
    ) -> Claim {
        Self.messageClaim(from: claimRaw(
            scope: Self.messageScope(thread), clientID: clientID,
            requestFingerprint: requestFingerprint,
            messageAliases: Self.boundedMessageAliases(aliases), now: now
        ))
    }

    private static func messageClaim(from raw: RawClaim) -> Claim {
        switch raw {
        case let .proceed(owner): return .proceed(owner)
        case let .replay(.message(response)): return .replay(response)
        case .replay: return .conflict
        case .inFlight: return .inFlight
        case .outcomeUnknown: return .outcomeUnknown
        case .conflict: return .conflict
        case .overloaded: return .overloaded
        case let .unavailable(message): return .unavailable(message)
        }
    }

    func claimCreation(
        clientID: String,
        requestFingerprint: String,
        now: Date = Date()
    ) -> CreationClaim {
        switch claimRaw(
            scope: Self.creationScope, clientID: clientID,
            requestFingerprint: requestFingerprint, now: now
        ) {
        case let .proceed(owner): return .proceed(owner)
        case let .replay(.creation(response)): return .replay(response)
        case .replay: return .conflict
        case .inFlight: return .inFlight
        case .outcomeUnknown: return .outcomeUnknown
        case .conflict: return .conflict
        case .overloaded: return .overloaded
        case let .unavailable(message): return .unavailable(message)
        }
    }

    func claimScheduleRun(
        scheduleID: String,
        clientID: String,
        now: Date = Date()
    ) -> ScheduleRunClaim {
        let fingerprint = Self.fingerprint(parts: ["schedule-run", scheduleID])
        switch claimRaw(
            scope: Self.scheduleRunScope(scheduleID), clientID: clientID,
            requestFingerprint: fingerprint, now: now
        ) {
        case let .proceed(owner): return .proceed(owner)
        case let .replay(.scheduleRun(response)): return .replay(response)
        case .replay: return .conflict
        case .inFlight: return .inFlight
        case .outcomeUnknown: return .outcomeUnknown
        case .conflict: return .conflict
        case .overloaded: return .overloaded
        case let .unavailable(message): return .unavailable(message)
        }
    }

    private func claimRaw(
        scope: String,
        clientID: String,
        requestFingerprint: String,
        messageAliases aliases: [String] = [],
        now: Date
    ) -> RawClaim {
        prune(now: now)
        guard Self.isValidScope(scope), Self.isValidClientID(clientID),
              Self.isValidFingerprint(requestFingerprint) else {
            return .conflict
        }
        let key = Key(scope: scope, clientID: clientID)
        if let existing = existingRawClaim(
            key: key, requestFingerprint: requestFingerprint
        ) { return existing }
        guard persistenceHealthy else {
            return .unavailable("Message replay protection is unavailable.")
        }
        // A completed handler does not prove the caller received its HTTP response. Evicting
        // any unexpired answer would let a response-loss retry through as a second prompt.
        // Keep the replay window honest and refuse new work until an entry expires or an
        // actually failed claim is abandoned.
        guard states.count < Self.maxEntries else { return .overloaded }
        let owner = Ownership(id: UUID())
        states[key] = .inFlight(
            since: now, owner: owner, fingerprint: requestFingerprint
        )
        order.append(key)
        if !aliases.isEmpty { messageAliases[key] = aliases }
        guard persist() else {
            states.removeValue(forKey: key)
            order.removeAll { $0 == key }
            messageAliases.removeValue(forKey: key)
            persistenceHealthy = false
            return .unavailable("Message replay protection could not be saved.")
        }
        return .proceed(owner)
    }

    private func existingRawClaim(
        key: Key,
        requestFingerprint: String
    ) -> RawClaim? {
        switch states[key] {
        case let .done(payload, _, fingerprint):
            return fingerprint == requestFingerprint ? .replay(payload) : .conflict
        case let .inFlight(_, _, fingerprint):
            return fingerprint == requestFingerprint ? .inFlight : .conflict
        case let .outcomeUnknown(_, fingerprint):
            guard let fingerprint else { return .outcomeUnknown }
            return fingerprint == requestFingerprint ? .outcomeUnknown : .conflict
        case nil: return nil
        }
    }

    func claim(
        threadID: String,
        clientID: String,
        requestFingerprint: String = SubmissionRegistry.fingerprint(parts: ["unspecified"]),
        now: Date = Date()
    ) -> Claim {
        claim(
            thread: ThreadInstanceKey(path: threadID), clientID: clientID,
            requestFingerprint: requestFingerprint, now: now
        )
    }

    /// Only a claim this registry still owns as in-flight becomes replayable. A late `complete`
    /// — one whose claim was abandoned or aged out from under it — must not resurrect an entry
    /// nothing is tracking any more.
    func complete(
        thread: ThreadInstanceKey,
        clientID: String,
        ownership: Ownership,
        response: SendMessageResponse,
        now: Date = Date()
    ) {
        completeRaw(
            key: Key(scope: Self.messageScope(thread), clientID: clientID),
            ownership: ownership, payload: .message(response), now: now
        )
    }

    func completeCreation(
        clientID: String,
        ownership: Ownership,
        response: CreateThreadResponse,
        now: Date = Date()
    ) {
        completeRaw(
            key: Key(scope: Self.creationScope, clientID: clientID),
            ownership: ownership, payload: .creation(response), now: now
        )
    }

    func completeScheduleRun(
        scheduleID: String,
        clientID: String,
        ownership: Ownership,
        response: ScheduleRunResponse,
        now: Date = Date()
    ) {
        completeRaw(
            key: Key(scope: Self.scheduleRunScope(scheduleID), clientID: clientID),
            ownership: ownership, payload: .scheduleRun(response), now: now
        )
    }

    private func completeRaw(
        key: Key,
        ownership: Ownership,
        payload: Payload,
        now: Date
    ) {
        guard case let .inFlight(_, currentOwner, fingerprint) = states[key],
              currentOwner == ownership else { return }
        states[key] = .done(payload, at: now, fingerprint: fingerprint)
        if !persist() { persistenceHealthy = false }
        let pending = waiters.removeValue(forKey: key).map { Array($0.values) } ?? []
        for continuation in pending { continuation.resume(returning: payload) }
    }

    func complete(
        threadID: String,
        clientID: String,
        ownership: Ownership,
        response: SendMessageResponse,
        now: Date = Date()
    ) {
        complete(
            thread: ThreadInstanceKey(path: threadID), clientID: clientID,
            ownership: ownership, response: response, now: now
        )
    }

    /// A retry that arrives while the original handler is still finishing waits for that exact
    /// result instead of returning a conflict that may tempt a caller to create a new client id.
    /// The wait is bounded, as is the waiter count, so a stalled handler cannot retain clients.
    func waitForCompletion(
        thread: ThreadInstanceKey,
        clientID: String,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async -> SendMessageResponse? {
        let payload = await waitForCompletionRaw(
            key: Key(scope: Self.messageScope(thread), clientID: clientID),
            timeoutNanoseconds: timeoutNanoseconds
        )
        guard let payload, case let .message(response) = payload else { return nil }
        return response
    }

    func waitForCreation(
        clientID: String,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async -> CreateThreadResponse? {
        let payload = await waitForCompletionRaw(
            key: Key(scope: Self.creationScope, clientID: clientID),
            timeoutNanoseconds: timeoutNanoseconds
        )
        guard let payload, case let .creation(response) = payload else { return nil }
        return response
    }

    func creationOutcomeIsUnknown(
        clientID: String, requestFingerprint: String, now: Date = Date()
    ) -> Bool {
        prune(now: now)
        let key = Key(scope: Self.creationScope, clientID: clientID)
        guard case let .outcomeUnknown(_, fingerprint) = states[key] else { return false }
        return fingerprint == nil || fingerprint == requestFingerprint
    }

    func waitForScheduleRun(
        scheduleID: String,
        clientID: String,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async -> ScheduleRunResponse? {
        let payload = await waitForCompletionRaw(
            key: Key(scope: Self.scheduleRunScope(scheduleID), clientID: clientID),
            timeoutNanoseconds: timeoutNanoseconds
        )
        guard let payload, case let .scheduleRun(response) = payload else { return nil }
        return response
    }

    private func waitForCompletionRaw(
        key: Key,
        timeoutNanoseconds: UInt64
    ) async -> Payload? {
        switch states[key] {
        case let .done(payload, _, _):
            return payload
        case .inFlight:
            break
        case .outcomeUnknown:
            return nil
        case nil:
            return nil
        }
        guard (waiters[key]?.count ?? 0) < Self.maxWaitersPerEntry else { return nil }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            waiters[key, default: [:]][waiterID] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await self?.expireWaiter(key: key, id: waiterID)
            }
        }
    }

    func waitForCompletion(
        threadID: String,
        clientID: String,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async -> SendMessageResponse? {
        await waitForCompletion(
            thread: ThreadInstanceKey(path: threadID), clientID: clientID,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    /// Releases a claim whose work failed, so an honest retry is not locked out forever.
    func abandon(thread: ThreadInstanceKey, clientID: String, ownership: Ownership) {
        abandonRaw(
            key: Key(scope: Self.messageScope(thread), clientID: clientID),
            ownership: ownership
        )
    }

    func abandonCreation(clientID: String, ownership: Ownership) {
        abandonRaw(
            key: Key(scope: Self.creationScope, clientID: clientID), ownership: ownership
        )
    }

    /// Retains a creation claim when prompt delivery crossed the ambiguous boundary but no real
    /// thread response could be persisted. A retry must review the catalog instead of starting a
    /// second session whose side effects could duplicate the first.
    func markCreationOutcomeUnknown(
        clientID: String, ownership: Ownership, now: Date = Date()
    ) {
        let key = Key(scope: Self.creationScope, clientID: clientID)
        guard case let .inFlight(_, currentOwner, fingerprint) = states[key],
              currentOwner == ownership else { return }
        states[key] = .outcomeUnknown(since: now, fingerprint: fingerprint)
        if !persist() { persistenceHealthy = false }
        resolveWaiters(key: key, response: nil)
    }

    func abandonScheduleRun(
        scheduleID: String,
        clientID: String,
        ownership: Ownership
    ) {
        abandonRaw(
            key: Key(scope: Self.scheduleRunScope(scheduleID), clientID: clientID),
            ownership: ownership
        )
    }

    private func abandonRaw(key: Key, ownership: Ownership) {
        guard case let .inFlight(_, currentOwner, _) = states[key],
              currentOwner == ownership else { return }
        states.removeValue(forKey: key)
        order.removeAll { $0 == key }
        messageAliases.removeValue(forKey: key)
        if !persist() { persistenceHealthy = false }
        resolveWaiters(key: key, response: nil)
    }

    func abandon(threadID: String, clientID: String, ownership: Ownership) {
        abandon(
            thread: ThreadInstanceKey(path: threadID), clientID: clientID,
            ownership: ownership
        )
    }

    private func prune(now: Date) {
        // A live in-process owner is the only code allowed to complete or abandon its claim. It
        // must never age out underneath a slow agent launch: doing so would admit a replacement
        // owner while the first create or prompt can still finish. Persisted in-flight entries
        // are converted to outcome-unknown during initialization because their handler did crash.
        let expired = states.filter { _, state in
            switch state {
            case .inFlight: false
            case let .outcomeUnknown(since, _): now.timeIntervalSince(since) > Self.entryTTL
            case let .done(_, at, _): now.timeIntervalSince(at) > Self.entryTTL
            }
        }.map(\.key)
        guard !expired.isEmpty else { return }
        for key in expired {
            states.removeValue(forKey: key)
            messageAliases.removeValue(forKey: key)
            resolveWaiters(key: key, response: nil)
        }
        order.removeAll { expired.contains($0) }
        if !persist() { persistenceHealthy = false }
    }

    @discardableResult
    private func persist() -> Bool {
        guard let fileURL else { return true }
        let entries = order.compactMap { key -> PersistedEntry? in
            guard let state = states[key] else { return nil }
            switch state {
            case let .inFlight(since, _, fingerprint):
                return PersistedEntry(
                    scope: key.scope, threadPath: nil, clientID: key.clientID,
                    requestFingerprint: fingerprint, state: "inFlight",
                    payload: nil, messageAliases: messageAliases[key],
                    response: nil, timestamp: since
                )
            case let .outcomeUnknown(since, fingerprint):
                return PersistedEntry(
                    scope: key.scope, threadPath: nil, clientID: key.clientID,
                    requestFingerprint: fingerprint, state: "outcomeUnknown",
                    payload: nil, messageAliases: messageAliases[key],
                    response: nil, timestamp: since
                )
            case let .done(payload, at, fingerprint):
                return PersistedEntry(
                    scope: key.scope, threadPath: nil, clientID: key.clientID,
                    requestFingerprint: fingerprint, state: "done",
                    payload: payload, messageAliases: messageAliases[key],
                    response: nil, timestamp: at
                )
            }
        }
        do {
            let envelope = PersistedEnvelope(version: Self.persistedVersion, entries: entries)
            let data = try PiDeskJSON.encoder.encode(envelope)
            guard data.count <= Self.maximumPersistedBytes else {
                logger?.error("Submission replay state exceeded its persisted size limit.")
                return false
            }
            try PiDeskFile.writeAtomic(data, to: fileURL)
            return true
        } catch {
            logger?.error("Could not persist submission replay state: \(error)")
            return false
        }
    }

    private func expireWaiter(key: Key, id: UUID) {
        guard let continuation = waiters[key]?.removeValue(forKey: id) else { return }
        if waiters[key]?.isEmpty == true { waiters.removeValue(forKey: key) }
        continuation.resume(returning: nil)
    }

    private func resolveWaiters(key: Key, response: Payload?) {
        let pending = waiters.removeValue(forKey: key).map { Array($0.values) } ?? []
        for continuation in pending { continuation.resume(returning: response) }
    }

    private static let corruptPersistenceMessage =
        "Submission replay state is corrupt or oversized; new sends are blocked until it is repaired."
    private static let creationScope = "creation"

    private static func messageScope(_ thread: ThreadInstanceKey) -> String {
        "message:\(thread.path)"
    }

    private static func messageThread(from scope: String) -> ThreadInstanceKey? {
        let prefix = "message:"
        guard scope.hasPrefix(prefix) else { return nil }
        let path = String(scope.dropFirst(prefix.count))
        guard path.hasPrefix("/"), messageScope(ThreadInstanceKey(path: path)) == scope else {
            return nil
        }
        return ThreadInstanceKey(path: path)
    }

    private static func normalizedMessageAlias(_ raw: String) -> String? {
        guard !raw.isEmpty, !raw.contains("/"), raw.utf8.count <= maxMessageAliasBytes,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return raw
    }

    private static func boundedMessageAliases(_ raw: [String]) -> [String] {
        var aliases: [String] = []
        var retainedBytes = 0
        for value in raw {
            guard aliases.count < maxMessageAliases,
                  let alias = normalizedMessageAlias(value),
                  !aliases.contains(alias),
                  retainedBytes + alias.utf8.count <= maxMessageAliasBytes else { continue }
            aliases.append(alias)
            retainedBytes += alias.utf8.count
        }
        return aliases
    }

    private static func validatedPersistedAliases(
        _ raw: [String], scope: String
    ) -> [String]? {
        guard messageThread(from: scope) != nil else { return raw.isEmpty ? [] : nil }
        guard raw.count <= maxMessageAliases else { return nil }
        var aliases: [String] = []
        var retainedBytes = 0
        for value in raw {
            guard let alias = normalizedMessageAlias(value), alias == value,
                  !aliases.contains(alias),
                  retainedBytes + alias.utf8.count <= maxMessageAliasBytes else { return nil }
            aliases.append(alias)
            retainedBytes += alias.utf8.count
        }
        return aliases
    }

    private static func scheduleRunScope(_ scheduleID: String) -> String {
        "schedule-run:\(scheduleID)"
    }

    private static func isValidScope(_ scope: String) -> Bool {
        guard !scope.isEmpty, scope.utf8.count <= 8_192 else { return false }
        if scope == creationScope { return true }
        if scope.hasPrefix("schedule-run:") {
            let id = String(scope.dropFirst("schedule-run:".count))
            return !id.isEmpty && !id.contains("/") && scheduleRunScope(id) == scope
        }
        return messageThread(from: scope) != nil
    }

    private static func isValidClientID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard (1...128).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) ||
                (97...122).contains(byte) || byte == 45 || byte == 95
        }
    }

    private static func isValidFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func fingerprint(parts: [String]) -> String {
        var input = Data()
        for part in parts {
            let bytes = Data(part.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(bytes)
        }
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}
