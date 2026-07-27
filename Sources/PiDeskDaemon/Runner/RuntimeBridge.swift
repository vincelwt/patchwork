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
/// 2. **A message accepted and then killed.** Pi acknowledges a `steer`/`follow_up`, then the
///    `agent_settled` for the turn already in progress arrives and the executor would stop the
///    session — discarding the message it just accepted. Every accepted delivery therefore banks a
///    *turn credit*, and the executor must spend those credits (keep consuming through the turns
///    they own) before admission can close.
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
        var grantedCredits = 0

        init(runID: String, handle: LiveRuntimeHandle) {
            self.runID = runID
            self.handle = handle
        }
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
    func closeAdmission(threadID: String, runID: String) -> CloseOutcome {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[threadID], entry.runID == runID else { return .closed }
        if entry.inFlight > 0 { return .busy }
        if entry.turnCredits > 0 {
            entry.turnCredits -= 1
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
        guard let entry = reserve(threadID: threadID) else { return nil }
        do {
            let result = try await entry.handle.deliver(command: command, message: message)
            // A rejected message never ran, so it owes no turn. The other two may already have
            // been applied and must keep the run consuming through the turn they bought.
            let ownsATurn: Bool
            switch result {
            case .acknowledged, .unacknowledged: ownsATurn = true
            case .rejected: ownsATurn = false
            }
            release(entry, bankTurn: ownsATurn)
            return (entry.runID, result)
        } catch {
            // The write failed (the process exited between reservation and send), so nothing
            // reached Pi and sending it again cannot duplicate anything.
            release(entry, bankTurn: false)
            return nil
        }
    }

    // Plain synchronous helpers rather than `lock()`/`unlock()` written inside `deliver`'s async
    // body: `NSLock` is unavailable there, since an async function can resume on a different
    // thread than the one that suspended it.
    private func reserve(threadID: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[threadID], entry.admitting else { return nil }
        // Refuse rather than extend a run indefinitely: past the bound the caller queues a fresh
        // run, which is bounded by its own timeout like any other.
        guard entry.grantedCredits < Self.maxTurnCredits else { return nil }
        entry.inFlight += 1
        return entry
    }

    private func release(_ entry: Entry, bankTurn: Bool) {
        lock.lock()
        entry.inFlight -= 1
        if bankTurn {
            entry.turnCredits += 1
            entry.grantedCredits += 1
        }
        lock.unlock()
    }
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
            states[key] = .inFlight(since: now)
            order.append(key)
            evictIfNeeded()
            return .proceed
        }
    }

    func complete(threadID: String, clientID: String, response: SendMessageResponse, now: Date = Date()) {
        states[key(threadID: threadID, clientID: clientID)] = .done(response, at: now)
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

    private func evictIfNeeded() {
        while order.count > Self.maxEntries {
            let oldest = order.removeFirst()
            states.removeValue(forKey: oldest)
        }
    }
}
