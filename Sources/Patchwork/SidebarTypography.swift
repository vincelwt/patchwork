import SwiftUI

/// The sidebar's entire type scale, named once so `SidebarView` and `QuickSwitcherView` (⌘K
/// draws from the same session list) can never drift onto their own ad-hoc `.system(size:)`
/// literals, or onto two different constants for what reads as the same role. Every case here
/// is a direct alias of a `Theme.swift` `PatchworkFont` constant — nothing new is invented, this only
/// names which shared step each sidebar role uses, so there is exactly one size for conversation
/// rows, one for folder/section headers, and one for metadata.
enum SidebarTypography {
    /// Conversation titles: the sidebar list and ⌘K's results share this exactly.
    static func conversationTitle(selected: Bool) -> Font { selected ? PatchworkFont.rowEmphasis : PatchworkFont.row }
    /// Folder and section headers ("Archived", a project or virtual folder's name).
    static let folderHeader = PatchworkFont.captionEmphasis
    /// Timestamps, folder tags, shortcut hints, result counts — secondary/disambiguating text.
    static let metadata = PatchworkFont.micro
    /// One-line status/empty-state copy ("Finding Pi sessions…", "No conversations match…").
    static let status = PatchworkFont.caption
}
