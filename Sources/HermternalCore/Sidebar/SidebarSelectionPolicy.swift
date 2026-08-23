/// A stable identity for a selectable sidebar item.
///
/// Selection is view state. The value is intentionally not Codable.
public enum SidebarSelectionID: Hashable, Sendable {
    case chat(String)
    case folder(String)
}

public enum SidebarPinAction: Hashable, Sendable {
    case pin
    case unpin
}

/// Pure selection rules shared by platform adapters.
public enum SidebarSelectionPolicy {
    /// Returns the full selection when the clicked item is selected.
    /// Otherwise, returns only the clicked item.
    public static func contextTargets(
        clicked: SidebarSelectionID,
        selected: Set<SidebarSelectionID>
    ) -> Set<SidebarSelectionID> {
        selected.contains(clicked) ? selected : [clicked]
    }

    /// Filters a drag to the dragged item's type when that item is selected.
    /// The result follows visible order and contains each logical item once.
    public static func applicableDragTargets(
        dragged: SidebarSelectionID,
        selected: Set<SidebarSelectionID>,
        visibleOrder: [SidebarSelectionID]
    ) -> [SidebarSelectionID] {
        guard selected.contains(dragged) else { return [dragged] }

        let sameType: (SidebarSelectionID) -> Bool
        switch dragged {
        case .chat(_):
            sameType = { if case .chat(_) = $0 { true } else { false } }
        case .folder(_):
            sameType = { if case .folder(_) = $0 { true } else { false } }
        }

        var seen = Set<SidebarSelectionID>()
        var result: [SidebarSelectionID] = []
        result.reserveCapacity(selected.count)
        for item in visibleOrder where selected.contains(item) && sameType(item) {
            if seen.insert(item).inserted {
                result.append(item)
            }
        }
        return result
    }

    /// Returns selected chat IDs in visible order, without pinned duplicates.
    public static func visibleUniqueChatIDs(
        selected: Set<SidebarSelectionID>,
        visibleOrder: [SidebarSelectionID]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(selected.count)
        for item in visibleOrder {
            guard case let .chat(id) = item, selected.contains(item) else { continue }
            if seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    /// Pins when at least one selected chat is unpinned, and unpins only when all are pinned.
    public static func convergingPinAction(for pinnedStates: [Bool]) -> SidebarPinAction? {
        guard !pinnedStates.isEmpty else { return nil }
        return pinnedStates.allSatisfy { $0 } ? .unpin : .pin
    }

    /// Removes identities that no longer exist in the current chat or folder sets.
    public static func prunedSelection(
        _ selection: Set<SidebarSelectionID>,
        validChatIDs: Set<String>,
        validFolderIDs: Set<String>
    ) -> Set<SidebarSelectionID> {
        selection.filter { item in
            switch item {
            case let .chat(id):
                validChatIDs.contains(id)
            case let .folder(id):
                validFolderIDs.contains(id)
            }
        }
    }
}
