import Foundation

/// A message the user queued while Pi was working, held by the app instead of handed straight
/// to Pi.
///
/// Pi's RPC can queue a steering or follow-up message but has no command to edit or withdraw
/// one, so anything sent immediately is final. Holding it here keeps it editable and removable
/// right up to the moment it actually matters, and it is flushed at the same boundary Pi would
/// have delivered it: steering at the end of the current turn, follow-ups once the run settles.
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
    }

    func removeOutbox(id: UUID) {
        outbox.removeAll { $0.id == id }
    }

    /// Hands every entry due at this boundary to Pi, oldest first. Anything the runtime rejects
    /// stays visible as an error rather than disappearing silently.
    func flushOutbox(_ boundary: OutboxEntry.Delivery) {
        let due = OutboxPolicy.due(outbox, at: boundary)
        guard !due.isEmpty, runtime.isRunning else { return }
        outbox = OutboxPolicy.removing(boundary, from: outbox)
        for entry in due {
            dispatchOutboxEntry(entry)
        }
    }

    private func dispatchOutboxEntry(_ entry: OutboxEntry) {
        let command = entry.delivery == .steer ? "steer" : "follow_up"
        runtime.send(type: command, payload: ["message": JSONValue.string(entry.text)]) { [weak self] result in
            guard let self, case let .failure(error) = result else { return }
            runtimeState.lastError = "Queued message could not be delivered: \(error.localizedDescription)"
        }
    }
}
