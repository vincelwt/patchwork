import Combine
import Foundation

/// Whether `candidate` is honestly recognizable as the session Pi just created to fulfil a
/// pending "new chat inside this virtual folder" intent. Pure so the rule is directly testable
/// without a runtime, a route, or a Pi process.
enum NewChatFolderResolution {
    struct Intent: Equatable {
        let folderID: String
        let cwd: URL
        let armedAt: Date
    }

    /// `candidate` matches when: nothing has organized it yet (an explicit user move always
    /// wins over this best-effort guess), its displayed project matches the cwd the intent was
    /// armed with (even when Pi runs in a worktree), and it was created no earlier than the
    /// intent. That last check is what actually tells
    /// apart "the fresh session Pi just assigned" from an unrelated, pre-existing conversation
    /// that happens to share the same folder: `AppStore.ensureProvisionalSession` stamps a new
    /// session's `createdAt` with `Date()` at the moment it learns the session's real id/path,
    /// so a genuine match's timestamp always lands at or after the moment the intent was armed.
    static func matches(
        _ candidate: SessionSummary,
        intent: Intent,
        existingAssignment: String?,
        projectFolder: URL? = nil
    ) -> Bool {
        guard existingAssignment == nil else { return false }
        let folder = projectFolder ?? candidate.cwd
        guard folder.standardizedFileURL.path == intent.cwd.standardizedFileURL.path else { return false }
        return candidate.createdAt >= intent.armedAt
    }
}

/// Bridges the gap between "the user asked for a new chat inside virtual folder X" and "Pi has
/// assigned that chat a real session id/path" — which, per `AppStore.openNewChat` /
/// `ensureProvisionalSession`, only becomes true after an attach round-trip, and the underlying
/// JSONL file itself may not even be written to disk yet. The assignment itself does not care:
/// `AppStore.moveSession` just records `path -> folderID` in persisted state, so writing it the
/// moment the path is known is already correct — a later disk scan will match the same
/// standardized path once Pi actually flushes the file.
///
/// Subscribing directly to the store's own `$route` (rather than hooking a View's lifecycle)
/// means an intervening sidebar re-layout — auto-collapse, a window resize — can never drop the
/// pending intent before it resolves.
@MainActor
final class NewChatFolderIntent {
    static let shared = NewChatFolderIntent()

    private(set) var pending: NewChatFolderResolution.Intent?
    private var subscription: AnyCancellable?

    /// Arms the intent and starts listening for the next route change. Call this only after the
    /// route has already settled on `.newChat` with `cwd` selected (see
    /// `SidebarView.newChatHere`), so the first change this subscription observes is a genuine
    /// transition rather than today's already-current value replaying through it.
    func arm(folderID: String, cwd: URL, store: AppStore, now: Date = Date()) {
        pending = NewChatFolderResolution.Intent(folderID: folderID, cwd: cwd, armedAt: now)
        subscription = store.$route
            .dropFirst()
            .sink { [weak self] newRoute in self?.resolve(newRoute, store: store) }
    }

    /// Consumes the pending intent on the very next route change, whatever it turns out to be: a
    /// genuine match applies the assignment; anything else (an existing conversation picked, a
    /// second unrelated new chat) just lets the stale guess expire instead of risking a later
    /// misfire against some future, unrelated session.
    ///
    /// Takes `route` as the value `$route` just emitted rather than re-reading `store.route`:
    /// `@Published` notifies subscribers from `willSet`, before its own backing storage is
    /// updated, so `store.route` (and anything derived from it, like `selectedSession`) would
    /// still read the *previous* route at this exact point in the call stack. `store.sessions`
    /// is not in that lag window — `ensureProvisionalSession` finishes inserting the provisional
    /// session before it ever assigns `route` — so looking the path up there directly is safe.
    private func resolve(_ route: AppRoute, store: AppStore) {
        subscription = nil
        guard let intent = pending else { return }
        pending = nil
        guard case let .session(path) = route,
              let session = store.sessions.first(where: { $0.fileURL.standardizedFileURL.path == path })
        else { return }
        guard NewChatFolderResolution.matches(
            session,
            intent: intent,
            existingAssignment: store.virtualFolderID(for: session),
            projectFolder: store.projectFolder(for: session)
        ) else { return }
        store.moveSession(session, toVirtualFolder: intent.folderID)
    }
}
