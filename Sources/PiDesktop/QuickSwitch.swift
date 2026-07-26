import Foundation

/// Deterministic scoring for the ⌘K palette. Operates on the bounded search key that summary
/// projection already folded once, so hundreds of sessions rank without extra allocation.
enum QuickSwitchScoring {
    /// Score buckets, highest first. Ties fall back to the caller's recent-first ordering.
    static let titlePrefix = 1_000
    static let titleWordPrefix = 900
    static let titleSubstring = 800
    static let folderPrefix = 620
    static let keySubstring = 600
    static let titleSubsequence = 400
    static let keySubsequence = 200

    /// `nil` means "no match". An empty query matches everything with score 0 so the caller's
    /// own ordering (most recent first) survives untouched.
    static func score(query: String, title: String, folder: String, searchKey: String) -> Int? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return 0 }

        let loweredTitle = title.lowercased()
        let loweredFolder = folder.lowercased()

        if loweredTitle.hasPrefix(needle) { return titlePrefix + lengthBonus(loweredTitle) }
        if hasWordPrefix(loweredTitle, needle: needle) { return titleWordPrefix + lengthBonus(loweredTitle) }
        if loweredTitle.contains(needle) { return titleSubstring + lengthBonus(loweredTitle) }
        if loweredFolder.hasPrefix(needle) { return folderPrefix + lengthBonus(loweredTitle) }
        if searchKey.contains(needle) { return keySubstring + lengthBonus(loweredTitle) }
        if let gaps = subsequenceGaps(loweredTitle, needle: needle) {
            return titleSubsequence + max(0, 120 - gaps)
        }
        if subsequenceGaps(searchKey, needle: needle) != nil { return keySubsequence }
        return nil
    }

    /// Shorter titles win a tie: a 12-character exact prefix beats a 90-character one.
    private static func lengthBonus(_ title: String) -> Int {
        max(0, 60 - min(60, title.count / 2))
    }

    private static func hasWordPrefix(_ haystack: String, needle: String) -> Bool {
        var isBoundary = false
        var index = haystack.startIndex
        while index < haystack.endIndex {
            let character = haystack[index]
            if isBoundary, haystack[index...].hasPrefix(needle) { return true }
            isBoundary = !character.isLetter && !character.isNumber
            index = haystack.index(after: index)
        }
        return false
    }

    /// Greedy in-order match. Returns the number of skipped characters, or `nil` when the
    /// needle is not a subsequence of the haystack.
    static func subsequenceGaps(_ haystack: String, needle: String) -> Int? {
        var needleIndex = needle.startIndex
        var gaps = 0
        var matching = false
        for character in haystack {
            if needleIndex == needle.endIndex { break }
            if character == needle[needleIndex] {
                needleIndex = needle.index(after: needleIndex)
                matching = true
            } else if matching {
                gaps += 1
            }
        }
        return needleIndex == needle.endIndex ? gaps : nil
    }

    /// Ranks summaries, keeping the input's recent-first order for equal scores.
    static func rank(_ sessions: [SessionSummary], query: String, limit: Int) -> [SessionSummary] {
        rank(sessions, query: query, limit: limit, folderName: { $0.folderName })
    }

    /// Scores every candidate, then keeps only the best-scoring instance per session file path.
    /// `AppStore.sessions` can legitimately hand this the same conversation twice — a
    /// provisional entry inserted before a rescan folds in the parsed file, or (since
    /// `SessionSummary.id` is read from the JSONL's own `session` event) two distinct files
    /// whose content id collides. The file path is the one identity Pi guarantees is unique, so
    /// it is what ⌘K de-duplicates on rather than the session's own id. Ties keep the earlier
    /// (more recent, since callers pass recency-sorted input) instance.
    static func rank(
        _ sessions: [SessionSummary],
        query: String,
        limit: Int,
        folderName: (SessionSummary) -> String
    ) -> [SessionSummary] {
        var bestByPath: [String: (score: Int, index: Int, session: SessionSummary)] = [:]
        for (index, session) in sessions.enumerated() {
            let folder = folderName(session)
            let key = session.searchKey + "\n" + folder.lowercased()
            guard let value = score(
                query: query,
                title: session.displayName,
                folder: folder,
                searchKey: key
            ) else { continue }
            let path = session.fileURL.standardizedFileURL.path
            if let existing = bestByPath[path], existing.score >= value { continue }
            bestByPath[path] = (value, index, session)
        }
        return bestByPath.values
            .sorted { lhs, rhs in lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score }
            .prefix(limit)
            .map(\.session)
    }
}

/// Pure selection-index math for the ⌘K list, kept apart from the AppKit field wiring in
/// `QuickSwitcherView` so arrow-key movement is unit-testable without a window.
enum QuickSwitchNavigation {
    /// Clamps `current + delta` into `0..<count`, so Up/Down never selects past either end of
    /// the (possibly just-filtered) result list and an empty list always resolves to 0.
    static func move(_ current: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, current + delta), count - 1)
    }
}
