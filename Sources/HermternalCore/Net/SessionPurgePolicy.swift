import Foundation

public enum SessionPurgeActionMode: String, Equatable, Codable, Sendable {
    case chatsOnly
    case foldersOnly
    case foldersAndChats
}

public struct SessionPurgeProfileGroup: Equatable, Sendable {
    public let profile: String?
    public let chatIDs: [String]

    public init(profile: String?, chatIDs: [String]) {
        self.profile = profile
        self.chatIDs = chatIDs
    }
}

public struct SessionPurgePlan: Equatable, Sendable {
    public let chatIDs: [String]
    public let sessions: [ChatSession]
    public let profileGroups: [SessionPurgeProfileGroup]
    public let folderIDs: [String]
    public let folderMembership: [String: String]
    public let mode: SessionPurgeActionMode
    public let confirmationCount: Int
    public let blockedByActiveStream: Bool

    public var chatCount: Int { chatIDs.count }
    public var folderCount: Int { folderIDs.count }
    public var isEmpty: Bool { chatIDs.isEmpty && folderIDs.isEmpty }

    public init(
        chatIDs: [String],
        sessions: [ChatSession] = [],
        profileGroups: [SessionPurgeProfileGroup] = [],
        folderIDs: [String],
        folderMembership: [String: String] = [:],
        mode: SessionPurgeActionMode = .foldersAndChats,
        confirmationCount: Int? = nil,
        blockedByActiveStream: Bool
    ) {
        self.chatIDs = chatIDs
        self.sessions = sessions
        self.profileGroups = profileGroups
        self.folderIDs = folderIDs
        self.folderMembership = folderMembership
        self.mode = mode
        self.confirmationCount = confirmationCount ?? chatIDs.count
        self.blockedByActiveStream = blockedByActiveStream
    }
}

public struct SessionPurgeReconciliation: Equatable, Sendable {
    public let successfulIDs: Set<String>
    public let failedIDs: Set<String>
    public let removableFolderIDs: Set<String>

    public init(
        successfulIDs: Set<String>,
        failedIDs: Set<String>,
        removableFolderIDs: Set<String>
    ) {
        self.successfulIDs = successfulIDs
        self.failedIDs = failedIDs
        self.removableFolderIDs = removableFolderIDs
    }
}
public enum SessionPurgePolicy {
    public static func plan(
        selectedChatIDs: [String],
        selectedFolderIDs: [String],
        mode: SessionPurgeActionMode,
        membership: [String: String],
        visibleChatIDs: [String],
        activeSessionID: String?,
        isStreaming: Bool,
        authoritativeSessions: [ChatSession] = []
    ) -> SessionPurgePlan {
        let visibleSet = Set(visibleChatIDs)
        let folderIDs = mode == .chatsOnly ? [] : unique(selectedFolderIDs)
        let explicitChats = mode == .foldersOnly ? [] : unique(selectedChatIDs)
        var chats = explicitChats.filter { visibleSet.contains($0) }
        if !folderIDs.isEmpty {
            for chatID in visibleChatIDs {
                guard let folderID = membership[chatID],
                      folderIDs.contains(folderID),
                      !chats.contains(chatID)
                else { continue }
                chats.append(chatID)
            }
        }
        chats = unique(chats)
        let sessionsByID = Dictionary(
            authoritativeSessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let selectedSessions = chats.compactMap { sessionsByID[$0] }
        var grouped: [String: [String]] = [:]
        for session in selectedSessions {
            grouped[session.profile ?? "", default: []].append(session.id)
        }
        let profileGroups = grouped.keys.sorted().map {
            SessionPurgeProfileGroup(
                profile: $0.isEmpty ? nil : $0,
                chatIDs: grouped[$0] ?? []
            )
        }
        let blocked = isStreaming && activeSessionID.map(chats.contains) == true
        return SessionPurgePlan(
            chatIDs: chats,
            sessions: selectedSessions,
            profileGroups: profileGroups,
            folderIDs: folderIDs,
            folderMembership: membership,
            mode: mode,
            blockedByActiveStream: blocked
        )
    }

    public static func reconcile(
        requestedIDs: [String],
        result: SessionPurgeResult,
        folderIDs: Set<String>,
        membership: [String: String]
    ) -> SessionPurgeReconciliation {
        let requested = Set(requestedIDs)
        let successful = Set(result.purged).intersection(requested)
        let failed = requested.subtracting(successful)
        var removable = Set<String>()
        for folderID in folderIDs {
            let contained = Set(membership.compactMap { chatID, assignedFolder in
                assignedFolder == folderID && requested.contains(chatID) ? chatID : nil
            })
            if contained.isEmpty {
                removable.insert(folderID)
                continue
            }
            guard contained.isSubset(of: successful) else { continue }
            removable.insert(folderID)
        }
        return SessionPurgeReconciliation(
            successfulIDs: successful,
            failedIDs: failed,
            removableFolderIDs: removable
        )
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
