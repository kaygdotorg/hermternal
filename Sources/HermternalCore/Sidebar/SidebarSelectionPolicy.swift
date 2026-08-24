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
    /// The ordered session identifiers determine the result order, so a
    /// heterogeneous selection remains deterministic even though `Set` has no
    /// ordering. A session is included at most once. Scheduled rows are direct
    /// targets when explicitly selected, but never become folder contents.
    ///
    /// Let `K` be the selection size, `S` the ordered-session count, and `M`
    /// the folder-membership count. This implementation does expected `O(K +
    /// M + S)` work and uses `O(C + F + R)` temporary storage, where `C` and
    /// `F` are the selected chat and folder counts and `R <= M` is the number
    /// of matching membership entries. It scans membership once when folders
    /// are selected, then scans ordered identifiers once; it does not probe
    /// membership once per session or copy `ChatSession` values. The former
    /// session-based implementation did expected `O(K + S)` work but performed
    /// several hash probes and copied one whole `ChatSession` per ordered
    /// element.
    public static func expandedChatIDs(
        selection: Set<SidebarSelectionID>,
        orderedSessionIDs: [String],
        scheduledSessionIDs: Set<String>,
        folderMembership: [String: String]
    ) -> [String] {
        expandedChatIDsWithWork(
            selection: selection,
            orderedSessionIDs: orderedSessionIDs,
            scheduledSessionIDs: scheduledSessionIDs,
            folderMembership: folderMembership
        ).chatIDs
    }

    struct ExpansionWork: Equatable, Sendable {
        fileprivate(set) var selectionItemsVisited = 0
        fileprivate(set) var membershipEntriesVisited = 0
        fileprivate(set) var orderedSessionIDsVisited = 0

        var total: Int {
            selectionItemsVisited + membershipEntriesVisited + orderedSessionIDsVisited
        }
    }

    // Kept internal so the deterministic performance contract can assert the
    // algorithm's bounded scans without adding instrumentation to the public
    // API.
    static func expandedChatIDsWithWork(
        selection: Set<SidebarSelectionID>,
        orderedSessionIDs: [String],
        scheduledSessionIDs: Set<String>,
        folderMembership: [String: String]
    ) -> (chatIDs: [String], work: ExpansionWork) {
        var work = ExpansionWork()
        var selectedChatIDs = Set<String>()
        var selectedFolderIDs = Set<String>()
        selectedChatIDs.reserveCapacity(selection.count)
        selectedFolderIDs.reserveCapacity(selection.count)
        for item in selection {
            work.selectionItemsVisited += 1
            switch item {
            case let .chat(id) where !id.isEmpty:
                selectedChatIDs.insert(id)
            case let .folder(id) where !id.isEmpty:
                selectedFolderIDs.insert(id)
            case .chat(_), .folder(_):
                continue
            }
        }

        // Make one target set before walking the authoritative order. This
        // replaces one membership dictionary lookup for every session with a
        // single membership scan when folder expansion is actually needed.
        var targetIDs = selectedChatIDs
        if !selectedFolderIDs.isEmpty {
            for (chatID, folderID) in folderMembership {
                work.membershipEntriesVisited += 1
                guard !chatID.isEmpty, selectedFolderIDs.contains(folderID) else {
                    continue
                }
                targetIDs.insert(chatID)
            }
        }

        var result: [String] = []
        result.reserveCapacity(targetIDs.count)
        for sessionID in orderedSessionIDs {
            work.orderedSessionIDsVisited += 1
            guard !sessionID.isEmpty, targetIDs.contains(sessionID) else {
                continue
            }
            let explicitlySelected = selectedChatIDs.contains(sessionID)
            guard explicitlySelected || !scheduledSessionIDs.contains(sessionID) else {
                continue
            }
            // Removing accepted IDs makes de-duplication part of the target
            // resolution pass, without a second `seen` set.
            targetIDs.remove(sessionID)
            result.append(sessionID)
        }
        return (result, work)
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
