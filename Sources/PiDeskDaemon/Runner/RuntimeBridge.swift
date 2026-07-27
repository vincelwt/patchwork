import Foundation
import PiDeskKit

/// What happened to a message handed to a *live* Pi session, as opposed to one queued behind it.
enum LiveDelivery: Sendable, Equatable {
    /// Pi answered `success: true`.
    case acknowledged
    /// Pi answered `success: false`; the message did not take effect.
    case rejected(String)
    /// Written to Pi's stdin, but no acknowledgement arrived before the wait elapsed (or the run
    /// settled first). Treated as delivered everywhere: re-queueing it could prompt Pi twice, and
    /// a duplicate prompt is a far worse failure than an unconfirmed one.
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
/// Registration lives exactly as long as the run's event loop: registered once the prompt has
/// been accepted, removed on every exit path. A steer that arrives outside that window finds
/// nothing and is sent as an ordinary prompt instead, which is the honest answer — there is no
/// live turn to interrupt.
///
/// Entries are keyed by thread but *generation-checked* by run id. Two runs on one thread cannot
/// overlap (`RunQueue` enforces per-thread mutual exclusion), but their registrations still can:
/// a run that settles a moment after its successor registered would otherwise unregister the
/// wrong session, silently disabling steering for a turn that is genuinely live.
final class LiveSessionRegistry: @unchecked Sendable {
    private struct Entry {
        let runID: String
        let handle: LiveRuntimeHandle
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

    func liveRunID(threadID: String) -> String? { entry(threadID: threadID)?.runID }

    // A plain synchronous helper rather than `lock()`/`unlock()` written inside `deliver`'s async
    // body: `NSLock` is unavailable there, since an async function can resume on a different
    // thread than the one that suspended it.
    private func entry(threadID: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[threadID]
    }

    var liveThreadIDs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.keys)
    }

    /// `nil` means "nothing reached Pi" — either no live turn, or the write itself failed — and
    /// is the *only* outcome a caller may safely re-send from. Every other case, including
    /// `.unacknowledged`, means the message may already have been applied: re-queueing it would
    /// risk prompting Pi twice, which is worse than an unconfirmed delivery.
    func deliver(threadID: String, command: String, message: String) async -> (runID: String, result: LiveDelivery)? {
        guard let entry = entry(threadID: threadID) else { return nil }
        do {
            return (entry.runID, try await entry.handle.deliver(command: command, message: message))
        } catch {
            // The write failed (the process exited between lookup and send), so nothing reached
            // Pi and sending it again cannot duplicate anything.
            return nil
        }
    }
}

/// Every `extension_ui_request` a daemon run is currently blocked on, plus the way to answer it.
///
/// The daemon never answers on a user's behalf. The only automatic action is an *expiry*, which
/// sends Pi an explicit cancellation so a run whose dialog nobody ever saw unwinds in bounded
/// time instead of holding a session open until the run's own timeout.
final class InteractionRegistry: @unchecked Sendable {
    typealias Responder = @Sendable ([String: PiJSONValue]) -> Void

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

    /// Answers a pending dialog. An empty request (no value, no confirmation) is a cancellation,
    /// never a blank answer — Pi must be able to tell "the user declined" from "the user typed
    /// nothing", and only the former is safe to invent.
    @discardableResult
    func respond(id: String, value: String?, confirmed: Bool?, cancelled: Bool) -> Bool {
        var response: [String: PiJSONValue] = ["type": .string("extension_ui_response"), "id": .string(id)]
        if cancelled { response["cancelled"] = .bool(true) }
        else if let confirmed { response["confirmed"] = .bool(confirmed) }
        else if let value { response["value"] = .string(value) }
        else { response["cancelled"] = .bool(true) }
        return resolve(id: id, response: response)
    }

    /// Cancels everything still pending for a run that is ending, so a finished run never leaves
    /// a dialog on a phone that can no longer be answered.
    func cancelAll(runID: String) {
        lock.lock()
        let ids = entries.values.filter { $0.interaction.runId == runID }.map(\.interaction.id)
        lock.unlock()
        for id in ids { respond(id: id, value: nil, confirmed: nil, cancelled: true) }
    }

    private func expire(id: String) {
        guard interaction(id: id) != nil else { return }
        logger?.info("Interaction \(id) expired without an answer; cancelling so the run can continue.")
        respond(id: id, value: nil, confirmed: nil, cancelled: true)
    }

    private func resolve(id: String, response: [String: PiJSONValue]) -> Bool {
        lock.lock()
        guard var entry = entries.removeValue(forKey: id) else {
            lock.unlock()
            return false
        }
        lock.unlock()

        entry.responder(response)
        entry.interaction.resolvedAt = Date()
        currentBus?.publish(.interaction(entry.interaction))
        return true
    }
}
