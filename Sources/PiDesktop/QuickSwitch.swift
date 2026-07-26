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

    static func rank(
        _ sessions: [SessionSummary],
        query: String,
        limit: Int,
        folderName: (SessionSummary) -> String
    ) -> [SessionSummary] {
        let scored = sessions.enumerated().compactMap { index, session -> (Int, Int, SessionSummary)? in
            let folder = folderName(session)
            let key = session.searchKey + "\n" + folder.lowercased()
            guard let value = score(
                query: query,
                title: session.displayName,
                folder: folder,
                searchKey: key
            ) else { return nil }
            return (value, index, session)
        }
        return scored
            .sorted { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 > rhs.0 }
            .prefix(limit)
            .map(\.2)
    }
}
