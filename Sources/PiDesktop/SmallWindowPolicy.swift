import CoreGraphics

/// Pure state machine for responsive sidebar behavior. Only a sidebar hidden by this policy is
/// restored on widening; a user-hidden sidebar is left alone. A user who reopens it while the
/// window is narrow is also respected until the next wide/narrow cycle.
struct SidebarAutoCollapseState: Equatable {
    enum Action: Equatable { case collapse, expand }

    private(set) var autoCollapsed = false
    private(set) var userOverrideWhileNarrow = false

    mutating func action(width: CGFloat, sidebarVisible: Bool, threshold: CGFloat) -> Action? {
        if width < threshold {
            guard !userOverrideWhileNarrow else { return nil }
            guard sidebarVisible, !autoCollapsed else { return nil }
            autoCollapsed = true
            return .collapse
        }

        userOverrideWhileNarrow = false
        guard autoCollapsed else { return nil }
        autoCollapsed = false
        return sidebarVisible ? nil : .expand
    }

    mutating func userChangedVisibility(width: CGFloat, threshold: CGFloat) {
        autoCollapsed = false
        if width < threshold { userOverrideWhileNarrow = true }
    }
}
