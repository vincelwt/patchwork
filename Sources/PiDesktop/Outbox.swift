import Foundation
import PiDeskKit

/// A follow-up the user queued while Pi was working, held by the app so it stays editable and
/// removable until the active turn settles. Steering normally bypasses this outbox and reaches Pi
/// immediately; changing a held follow-up to steering flushes it immediately too.
struct OutboxEntry: Identifiable, Hashable, Sendable {
    enum Delivery: String, Hashable, Sendable {
        case steer
        case followUp

        var label: String {
            switch self {
            case .steer: "Steering"
            case .followUp: "Follow-up"
            }
        }
    }

    let id: UUID
    var text: String
    var delivery: Delivery
    var attachments: [ImageAttachment]
    let queuedAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        delivery: Delivery,
        attachments: [ImageAttachment] = [],
        queuedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.delivery = delivery
        self.attachments = attachments
        self.queuedAt = queuedAt
    }
}

/// Pure queue rules, so ordering and flush timing are testable without a runtime.
enum OutboxPolicy {
    /// Never let a runaway loop stack an unbounded number of pending messages.
    static let limit = 20

    static func append(_ entry: OutboxEntry, to entries: [OutboxEntry]) -> [OutboxEntry] {
        Array((entries + [entry]).suffix(limit))
    }

    /// Entries due at a given moment in the run, in the order the user queued them.
    static func due(_ entries: [OutboxEntry], at boundary: OutboxEntry.Delivery) -> [OutboxEntry] {
        entries.filter { $0.delivery == boundary }
    }

    static func removing(_ delivery: OutboxEntry.Delivery, from entries: [OutboxEntry]) -> [OutboxEntry] {
        entries.filter { $0.delivery != delivery }
    }

    static func restoring(_ entry: OutboxEntry, to entries: [OutboxEntry]) -> [OutboxEntry] {
        Array((entries + [entry]).sorted { $0.queuedAt < $1.queuedAt }.suffix(limit))
    }
}

/// What the strip above the composer actually shows. Every entry the app is holding is listed
/// as editable (its text can change, its delivery kind can change, and it can be withdrawn);
/// whatever Pi itself already reports as queued (`queue_update`, possibly from another client)
/// is listed too, so nothing queued anywhere is hidden, but strictly read-only — Pi's RPC has no
/// command to change or cancel something it has already accepted.
enum OutboxPresentation {
    struct Row: Identifiable, Hashable {
        enum Source: Hashable {
            case app(OutboxEntry)
            case runtime(Int)
        }

        let source: Source
        let delivery: OutboxEntry.Delivery
        let text: String
        let attachmentCount: Int

        var id: String {
            switch source {
            case let .app(entry): "app-\(entry.id.uuidString)"
            case let .runtime(index): "runtime-\(delivery.rawValue)-\(index)"
            }
        }

        /// Only an app-held entry can be edited or withdrawn from the strip.
        var isEditable: Bool {
            if case .app = source { true } else { false }
        }

        /// The full entry backing an app-held row (attachments, exact text) — nil for anything
        /// reported by the runtime, which never carries attachments of its own here.
        var entry: OutboxEntry? {
            if case let .app(entry) = source { entry } else { nil }
        }
    }

    /// The strip must be entirely absent, not merely empty, when there is nothing queued
    /// anywhere — checked separately from `rows` so the view can skip building rows at all.
    ///
    /// `AppStore` publishes only the selected runtime's outbox and Pi queues; parked runtimes keep
    /// their own snapshots. `isSelectedRuntime` still prevents the brief route-switch interval
    /// from showing conversation A's queued messages in conversation B.
    static func isEmpty(
        outbox: [OutboxEntry],
        steeringQueue: [String],
        followUpQueue: [String],
        isSelectedRuntime: Bool
    ) -> Bool {
        guard isSelectedRuntime else { return true }
        return outbox.isEmpty && steeringQueue.isEmpty && followUpQueue.isEmpty
    }

    /// Pi's own queue first — it is already committed on Pi's side — then the app's outbox in
    /// the order it will flush (oldest queued first, matching `OutboxPolicy.due`).
    static func rows(
        outbox: [OutboxEntry],
        steeringQueue: [String],
        followUpQueue: [String],
        isSelectedRuntime: Bool
    ) -> [Row] {
        guard isSelectedRuntime else { return [] }
        var rows = steeringQueue.enumerated().map { Row(source: .runtime($0), delivery: .steer, text: $1, attachmentCount: 0) }
        rows += followUpQueue.enumerated().map { Row(source: .runtime($0), delivery: .followUp, text: $1, attachmentCount: 0) }
        rows += outbox.map { Row(source: .app($0), delivery: $0.delivery, text: $0.text, attachmentCount: $0.attachments.count) }
        return rows
    }
}

@MainActor
extension AppStore {
    /// Queues a message locally instead of handing it to Pi immediately.
    func enqueueOutbox(text: String, delivery: OutboxEntry.Delivery, attachments: [ImageAttachment] = []) {
        let clean = Self.sanitizedMessage(text)
        guard !clean.isEmpty || !attachments.isEmpty else { return }
        outbox = OutboxPolicy.append(
            OutboxEntry(text: clean, delivery: delivery, attachments: attachments),
            to: outbox
        )
    }

    func updateOutbox(id: UUID, text: String) {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        let clean = Self.sanitizedMessage(text)
        if clean.isEmpty, outbox[index].attachments.isEmpty { outbox.remove(at: index) }
        else { outbox[index].text = clean }
    }

    func setOutboxDelivery(id: UUID, delivery: OutboxEntry.Delivery) {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        outbox[index].delivery = delivery
        if delivery == .steer { flushOutbox(.steer) }
    }

    func removeOutbox(id: UUID) {
        outbox.removeAll { $0.id == id }
    }

    /// One Escape stops only the current turn and preserves every queued message as a follow-up.
    /// A second Escape is the explicit full-stop gesture.
    func stopFromEscape(fully: Bool) {
        if fully { abortFromEscapeSequence(); return }
        guard activateCurrentRouteRuntimeForEscape(),
              runtimeState.isBusy || currentRouteHasPendingStartupPrompt else { return }
        for index in outbox.indices { outbox[index].delivery = .followUp }
        abortCurrentTurnPreservingQueues()
    }

    /// Hands every entry due at this boundary to Pi, oldest first. Anything the runtime rejects
    /// stays visible as an error rather than disappearing silently.
    func flushOutbox(_ boundary: OutboxEntry.Delivery) {
        if boundary == .followUp {
            dispatchNextActiveFollowUp()
            return
        }
        let due = OutboxPolicy.due(outbox, at: boundary)
        guard !due.isEmpty, runtime.isRunning else { return }
        outbox = OutboxPolicy.removing(boundary, from: outbox)
        for entry in due { dispatchOutboxEntry(entry) }
    }

    private func dispatchOutboxEntry(_ entry: OutboxEntry) {
        let command = entry.delivery == .steer ? "steer" : "follow_up"
        let target = runtime
        let token = beginOutboxDispatch()
        var payload: [String: JSONValue] = [
            "message": .string(ImageAttachment.prompt(text: entry.text, attachments: entry.attachments))
        ]
        if !entry.attachments.isEmpty { payload["images"] = .array(entry.attachments.map(\.rpcValue)) }
        target.send(type: command, payload: payload) { [weak self] result in
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
}
