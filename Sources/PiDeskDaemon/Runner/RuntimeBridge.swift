import Foundation
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
protocol LiveRuntimeHandle: Sendable {
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
    private var entries: [String: Entry] = [:]

    init() {}

    func register(threadID: String, runID: String, handle: LiveRuntimeHandle) {
        lock.lock(); entries[threadID] = Entry(runID: runID, handle: handle); lock.unlock()
    }

    /// No-op unless `runID` still owns the slot, so a late unregister cannot retire its successor.
    func unregister(threadID: String, runID: String) {
        lock.lock()
        if entries[threadID]?.runID == runID { entries.removeValue(forKey: threadID) }
        lock.unlock()
    }

    func liveRunID(threadID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let entry = entries[threadID]
        return entry?.admitting == true ? entry?.runID : nil
    }

    var liveThreadIDs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.filter { $0.value.admitting }.keys)
    }

    /// Called by the executor when it sees `agent_settled`. See `CloseOutcome`.
    ///
    /// `.busy` closes admission too: a caller arriving during that window must fall back to a
    /// queued run rather than write into a session that is one instant from being stopped.
    /// Admission reopens only when the run genuinely continues into a credited turn.
    func closeAdmission(threadID: String, runID: String) -> CloseOutcome {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[threadID], entry.runID == runID else { return .closed }
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

    /// `nil` means "nothing reached Pi" — no live turn, admission already closed, the credit bound
    /// was reached, or the write itself failed — and is the *only* outcome a caller may safely
    /// re-send from. Every other case, including `.unacknowledged`, means the message may already
    /// have been applied: re-queueing it would risk prompting Pi twice.
    func deliver(threadID: String, command: String, message: String) async -> (runID: String, result: LiveDelivery)? {
        guard let reservation = reserve(threadID: threadID, command: command) else { return nil }
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
    func drainForShutdown(threadID: String, runID: String, deadline: Date, pump: () async -> Bool) async -> Bool {
        while true {
            guard closeForShutdown(threadID: threadID, runID: runID) > 0 else { return true }
            guard Date() < deadline, await pump() else { return false }
        }
    }

    /// Closes admission for good and reports how many deliveries are still mid-write.
    private func closeForShutdown(threadID: String, runID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[threadID], entry.runID == runID else { return 0 }
        entry.admitting = false
        entry.boundaryPending = false
        entry.turnCredits = 0
        return entry.inFlight
    }

    // Plain synchronous helpers rather than `lock()`/`unlock()` written inside `deliver`'s async
    // body: `NSLock` is unavailable there, since an async function can resume on a different
    // thread than the one that suspended it.
    private func reserve(threadID: String, command: String) -> Reservation? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[threadID], entry.admitting else { return nil }
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
        var interaction: PendingInteraction
        let responder: Responder
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

    private var currentBus: EventBus? {
        lock.lock(); defer { lock.unlock() }
        return bus
    }

    /// `false` means the registry is full and the caller must cancel the request itself — Pi is
    /// blocked, so dropping it on the floor is never an option.
    func register(_ interaction: PendingInteraction, responder: @escaping Responder) -> Bool {
        lock.lock()
        guard entries.count < Self.maxPending, entries[interaction.id] == nil else {
            lock.unlock()
            return false
        }
        entries[interaction.id] = Entry(interaction: interaction, responder: responder)
        lock.unlock()

        currentBus?.publish(.interaction(interaction))
        let delay = max(1, interaction.expiresAt.timeIntervalSince(Date()))
        timerQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.expire(id: interaction.id)
        }
        return true
    }

    func pending(threadID: String? = nil) -> [PendingInteraction] {
        lock.lock(); defer { lock.unlock() }
        return entries.values
            .map(\.interaction)
            .filter { threadID == nil || $0.threadId == threadID }
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
        /// The write to Pi failed. The dialog is left pending so it can be retried, because Pi is
        /// still blocked on it and reporting success here would strand the run.
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
        let ids = entries.values.filter { $0.interaction.runId == runID }.map(\.interaction.id)
        lock.unlock()
        for id in ids {
            if case let .writeFailed(reason) = respond(id: id, value: nil, confirmed: nil, cancelled: true) {
                logger?.warn("Could not cancel interaction \(id) on its run ending: \(reason)")
                forget(id: id)
            }
        }
    }

    private func expire(id: String) {
        guard interaction(id: id) != nil else { return }
        logger?.info("Interaction \(id) expired without an answer; cancelling so the run can continue.")
        if case let .writeFailed(reason) = respond(id: id, value: nil, confirmed: nil, cancelled: true) {
            logger?.warn("Could not cancel expired interaction \(id): \(reason)")
            forget(id: id)
        }
    }

    /// Drops a dialog without answering Pi, for the cases where answering is impossible anyway
    /// (the session is gone). Publishes the retirement so clients stop showing it.
    private func forget(id: String) {
        lock.lock()
        var entry = entries.removeValue(forKey: id)
        lock.unlock()
        guard entry != nil else { return }
        entry!.interaction.resolvedAt = Date()
        currentBus?.publish(.interaction(entry!.interaction))
    }

    /// The entry is removed *before* the write and restored if the write throws, so two concurrent
    /// answers can never both reach Pi, and a failed one still leaves the dialog answerable.
    private func resolve(id: String, response: [String: PiJSONValue]) -> RespondResult {
        lock.lock()
        guard var entry = entries.removeValue(forKey: id) else {
            lock.unlock()
            return .notFound
        }
        lock.unlock()

        do {
            try entry.responder(response)
        } catch {
            lock.lock()
            // Only restore if nothing else claimed the id meanwhile.
            if entries[id] == nil { entries[id] = entry }
            lock.unlock()
            return .writeFailed("\(error)")
        }

        entry.interaction.resolvedAt = Date()
        currentBus?.publish(.interaction(entry.interaction))
        return .answered
    }
}

/// De-duplicates `POST /v1/threads/{id}/messages` by the caller's own submission id.
///
/// A phone loses the response to a send far more often than it loses the request: the tunnel drops
/// while the daemon is already enqueueing. Without this, the reader sees a failed message, taps
/// Retry, and Pi is prompted twice. Repeating a `(thread, clientId)` pair therefore replays the
/// original `SendMessageResponse` rather than delivering or enqueueing anything a second time.
///
/// Bounded and in-memory. A daemon restart forgets these, so a retry across a restart can still
/// duplicate; `runs.jsonl` records no client id, so covering that would mean a new persisted store
/// for a window measured in seconds. Documented in docs/daemon-api.md rather than built.
///
/// This is independent of, and does not weaken, the hosted relay's own mutation counter: that
/// rejects a *replayed ciphertext frame* outright, while this replays a response to a legitimately
/// re-sent request.
actor SubmissionRegistry {
    static let maxEntries = 256
    static let entryTTL: TimeInterval = 1_800

    enum Claim: Equatable {
        /// First time this submission has been seen; the caller owns it.
        case proceed
        /// Already completed: return this exact response again.
        case replay(SendMessageResponse)
        /// An identical submission is being processed right now. The caller must not start a
        /// second one; it reports a conflict and the client retries.
        case inFlight
        /// Every slot holds a submission that has not finished yet. Evicting one to make room
        /// would un-protect a send that is still running, so the *new* one is refused instead:
        /// a `503` the client can retry, rather than a duplicate prompt it cannot take back.
        case overloaded
    }

    private enum State {
        case inFlight(since: Date)
        case done(SendMessageResponse, at: Date)
    }

    private var states: [String: State] = [:]
    private var order: [String] = []

    private func key(threadID: String, clientID: String) -> String { "\(threadID)\u{0}\(clientID)" }

    func claim(threadID: String, clientID: String, now: Date = Date()) -> Claim {
        prune(now: now)
        let key = key(threadID: threadID, clientID: clientID)
        switch states[key] {
        case let .done(response, _):
            return .replay(response)
        case .inFlight:
            return .inFlight
        case nil:
            guard states.count < Self.maxEntries || evictOldestCompleted() else { return .overloaded }
            states[key] = .inFlight(since: now)
            order.append(key)
            return .proceed
        }
    }

    /// Only a claim this registry still owns as in-flight becomes replayable. A late `complete`
    /// — one whose claim was abandoned or aged out from under it — must not resurrect an entry
    /// nothing is tracking any more.
    func complete(threadID: String, clientID: String, response: SendMessageResponse, now: Date = Date()) {
        let key = key(threadID: threadID, clientID: clientID)
        guard case .inFlight = states[key] else { return }
        states[key] = .done(response, at: now)
    }

    /// Releases a claim whose work failed, so an honest retry is not locked out forever.
    func abandon(threadID: String, clientID: String) {
        let key = key(threadID: threadID, clientID: clientID)
        states.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    private func prune(now: Date) {
        // An in-flight claim that outlived the TTL belonged to a request that never finished
        // (a crashed handler); releasing it is better than blocking that submission forever.
        let expired = states.filter { _, state in
            switch state {
            case let .inFlight(since): now.timeIntervalSince(since) > Self.entryTTL
            case let .done(_, at): now.timeIntervalSince(at) > Self.entryTTL
            }
        }.map(\.key)
        guard !expired.isEmpty else { return }
        for key in expired { states.removeValue(forKey: key) }
        order.removeAll { expired.contains($0) }
    }

    /// Drops the oldest *completed* entry, which costs a retry its replay but can never duplicate
    /// a prompt. An in-flight claim is never evicted: the submission it guards is still running,
    /// and forgetting it is exactly how a retry becomes a second turn.
    private func evictOldestCompleted() -> Bool {
        guard let index = order.firstIndex(where: { key in
            if case .done = states[key] { return true } else { return false }
        }) else { return false }
        states.removeValue(forKey: order.remove(at: index))
        return true
    }
}
