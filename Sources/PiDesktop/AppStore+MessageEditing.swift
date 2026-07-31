import Combine
import Foundation

/// Edit-and-resubmit state for one `AppStore` instance, held alongside it instead of as a stored
/// property (an extension in another file cannot add one, and `AppStore.swift` itself is out of
/// this change's ownership). Keyed weakly so an `AppStore` that deallocates drops its entry with
/// it instead of leaking across the app's lifetime or across test instances.
@MainActor
private final class MessageEditState {
    var targetMessageID: String?
    var targetSessionKey: String?
    var isResubmitting = false
    var routeCancellable: AnyCancellable?
}

@MainActor
private let editStates = NSMapTable<AppStore, MessageEditState>.weakToStrongObjects()

extension AppStore {
    private var editState: MessageEditState {
        if let existing = editStates.object(forKey: self) { return existing }
        let created = MessageEditState()
        // Any route change invalidates an armed edit: switching conversations mid-edit must
        // never let a later Send resubmit into a session the edit was never meant for.
        created.routeCancellable = $route.dropFirst().sink { [weak self, weak created] _ in
            guard let created, created.targetMessageID != nil else { return }
            created.targetMessageID = nil
            created.targetSessionKey = nil
            self?.objectWillChange.send()
        }
        editStates.setObject(created, forKey: self)
        return created
    }

    /// The route's own draft key, mirrored from `AppStore`'s private `currentDraftKey` logic so
    /// resubmission can verify it still targets the conversation the edit was armed for.
    private var editSessionKey: String {
        selectedSession?.fileURL.standardizedFileURL.path ?? "new-chat"
    }

    /// The most recent user turn on the active branch, whether or not Pi has answered it yet.
    var lastUserMessage: ChatMessage? { messages.last(where: { $0.role == .user }) }

    /// True while an edit is armed for the conversation currently on screen. `false` again once
    /// resubmitted, cancelled, or the route changes out from under it.
    var isEditingLastMessage: Bool {
        let state = editState
        return state.targetMessageID != nil && state.targetSessionKey == editSessionKey
    }

    /// Loads the conversation's last user message back into the composer and arms resubmission.
    /// Only ever wired to that exact message's hover action, but re-validated at resubmit time
    /// regardless, so a stale click can never apply to the wrong turn.
    func beginEditingLastMessage() {
        let state = editState
        // Editing branches the transcript, which only an agent with a fork/branch model can do.
        // Gated on the agent alone, never on whether a runtime happens to be attached: arming an
        // edit is a composer action and has always worked before the runtime warms up.
        guard activeAgent.capabilities.canFork else {
            showToast("\(activeAgent.displayName) cannot branch a conversation.", style: .warning)
            return
        }
        guard !isBrowsingEarlierHistory, !state.isResubmitting, let target = lastUserMessage else { return }
        draft = Self.editableText(from: target)
        attachments = target.images.compactMap(ImageImportService.attachment)
        state.targetMessageID = target.id
        state.targetSessionKey = editSessionKey
        objectWillChange.send()
    }

    /// Disarms an edit without touching the composer, so a resubmit that turns out to be invalid
    /// (stale target, empty content) never contaminates a draft the user has since moved on to.
    func cancelEditingLastMessage() {
        let state = editState
        guard state.targetMessageID != nil else { return }
        state.targetMessageID = nil
        state.targetSessionKey = nil
        objectWillChange.send()
    }

    /// Replaces the armed user turn by branching immediately before it in the same session, then
    /// submitting the edited composer. The abandoned answer remains in Pi's append-only tree.
    func resubmitEditedMessage() {
        let state = editState
        guard !state.isResubmitting else { return }
        guard let targetID = state.targetMessageID, state.targetSessionKey == editSessionKey,
              let targetIndex = messages.firstIndex(where: { $0.id == targetID }) else {
            cancelEditingLastMessage()
            return
        }
        let hasContent = !AppStore.sanitizedMessage(draft).isEmpty || !attachments.isEmpty
        guard hasContent else {
            cancelEditingLastMessage()
            return
        }

        let target = messages[targetIndex]
        let messagesBeforeTarget = Array(messages[..<targetIndex])
        state.isResubmitting = true
        state.targetMessageID = nil
        state.targetSessionKey = nil
        objectWillChange.send()

        Task { @MainActor [weak self] in
            guard let self else { return }
            if isSelectedRuntime, runtimeState.isStreaming { abort() }
            await Self.waitUntilIdle(self)
            branchAndSubmitEditedMessage(
                targetID: target.id,
                targetText: Self.editableText(from: target),
                messagesBeforeTarget: messagesBeforeTarget
            ) { [weak self] in
                self?.editState.isResubmitting = false
            }
        }
    }

    /// Waits for the selected runtime to leave the streaming state (bounded, so a runtime that
    /// never confirms the abort cannot hang the resubmit forever) before handing control back.
    /// `submitDraft`'s `.automatic` delivery sends a fresh `prompt` only while idle; resubmitting
    /// while still marked streaming would steer the very run being replaced instead.
    private static func waitUntilIdle(_ store: AppStore, timeout: TimeInterval = 6) async {
        guard store.isSelectedRuntime, store.runtimeState.isStreaming else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            var cancellable: AnyCancellable?
            let finish = {
                guard !resumed else { return }
                resumed = true
                cancellable?.cancel()
                continuation.resume()
            }
            cancellable = store.$runtimeState
                .filter { !$0.isStreaming }
                .prefix(1)
                .sink { _ in finish() }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish()
            }
        }
    }

    private static func editableText(from message: ChatMessage) -> String {
        message.blocks.compactMap { block -> String? in
            guard case let .text(text) = block.kind else { return nil }
            return text
        }.joined(separator: "\n\n")
    }
}
