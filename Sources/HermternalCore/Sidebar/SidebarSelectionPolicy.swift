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
    /// Resolves selected chat rows and the contents of selected folders.
    ///
    /// The authoritative session order is the result order, so a heterogeneous
    /// selection remains deterministic even though `Set` has no ordering. A
    /// session is included at most once. Scheduled rows are direct targets when
    /// explicitly selected, but never become folder contents.
    public static func expandedChatIDs(
        selection: Set<SidebarSelectionID>,
        authoritativeSessions: [ChatSession],
        folderMembership: [String: String]
    ) -> [String] {
        let selectedChatIDs = Set(selection.compactMap { item -> String? in
            guard case let .chat(id) = item else { return nil }
            return id.isEmpty ? nil : id
        })
        let selectedFolderIDs = Set(selection.compactMap { item -> String? in
            guard case let .folder(id) = item else { return nil }
            return id.isEmpty ? nil : id
        })

        var result: [String] = []
        result.reserveCapacity(selectedChatIDs.count)
        var seen = Set<String>()
        for session in authoritativeSessions {
            let explicitlySelected = selectedChatIDs.contains(session.id)
            let isFolderContent = folderMembership[session.id].map { selectedFolderIDs.contains($0) } ?? false
            guard explicitlySelected || (isFolderContent && !SidebarOrderingConstants.isScheduled(session)),
                  !session.id.isEmpty,
                  seen.insert(session.id).inserted
            else { continue }
            result.append(session.id)
        }
        return result
    }

    /// Filters a drag to the dragged item's type when that item is selected.
    /// The result follows the unique visible order.
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

        return visibleOrder.filter { selected.contains($0) && sameType($0) }
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
