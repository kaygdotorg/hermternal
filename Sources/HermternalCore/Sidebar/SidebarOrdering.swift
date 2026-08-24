import Foundation

public enum SortMode: String, Sendable, CaseIterable {
    case lastActivity
    case created
    case title
}

public struct Folder: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let order: Int

    public init(id: String, name: String, order: Int) {
        self.id = id
        self.name = name
        self.order = order
    }
}

public enum SidebarSectionKind: Hashable, Sendable {
    case schedules
    case pinned
    case folder(id: String, name: String)
    case bucket(DateBucket)
    case ungrouped
}

public enum DateBucket: Hashable, Sendable, CaseIterable {
    case today
    case yesterday
    case previousSevenDays
    case previousThirtyDays
    case older
}

public struct SidebarRowID: Hashable, Sendable {
    public let section: SidebarSectionKind
    public let sessionID: String

    public init(section: SidebarSectionKind, sessionID: String) {
        self.section = section
        self.sessionID = sessionID
    }
}

public struct SidebarRow: Identifiable, Hashable, Sendable {
    public let id: SidebarRowID
    public let sessionID: String
    public let session: ChatSession

    public init(id: SidebarRowID, sessionID: String, session: ChatSession) {
        self.id = id
        self.sessionID = sessionID
        self.session = session
    }
}

public struct SidebarSection: Identifiable, Hashable, Sendable {
    public let id: SidebarSectionKind
    public let kind: SidebarSectionKind
    public let rows: [SidebarRow]

    public init(id: SidebarSectionKind, kind: SidebarSectionKind, rows: [SidebarRow]) {
        self.id = id
        self.kind = kind
        self.rows = rows
    }
}
/// The ordering and identity-independent rows used by every sidebar surface.
///
/// Selection is intentionally absent from this projection. A selection change
/// can therefore reuse the resident ordering without walking sessions, folders,
/// or membership again.
public struct SidebarOrderingProjection: Equatable, Sendable {
    public let sections: [SidebarSection]
    public let visibleOrder: [SidebarSelectionID]
    public let folderVisibleOrder: [SidebarSelectionID]

    public init(sections: [SidebarSection]) {
        self.sections = sections
        visibleOrder = sections.flatMap { section in
            section.rows.map { SidebarSelectionID.chat($0.sessionID) }
        }
        folderVisibleOrder = sections.compactMap { section in
            if case let .folder(id, _) = section.kind {
                return SidebarSelectionID.folder(id)
            }
            return nil
        }
    }
}

/// Inputs that can change sidebar ordering.
///
/// This is a value seam rather than an incidental SwiftUI cache key, so its
/// invalidation rules are explicit and directly testable.
public struct SidebarOrderingInputs: Equatable {
    public let sessions: [ChatSession]
    public let folders: [Folder]
    public let membership: [String: String]
    public let sortMode: SortMode
    public let groupByDate: Bool
    public let calendar: Calendar
    public let now: Date

    /// The identity of each collection's copy-on-write storage, plus scalars.
    ///
    /// A repeated body pass copies the same storage. The memo retains the
    /// previous input strongly, so its storage cannot be deallocated while
    /// this token is compared. Allocator reuse therefore cannot make a new
    /// collection appear unchanged. A representation change only causes the
    /// equality fallback and cannot return stale data.
    ///
    /// A mutation must copy storage while the memo retains the previous input,
    /// so this check cannot return a stale projection. The equality fallback
    /// handles equal values that use separate storage.
    fileprivate let storageValidity: SidebarOrderingStorageValidity

    public init(
        sessions: [ChatSession],
        folders: [Folder],
        membership: [String: String],
        sortMode: SortMode,
        groupByDate: Bool,
        calendar: Calendar,
        now: Date
    ) {
        self.sessions = sessions
        self.folders = folders
        self.membership = membership
        self.sortMode = sortMode
        self.groupByDate = groupByDate
        self.calendar = calendar
        self.now = now
        storageValidity = SidebarOrderingStorageValidity(
            sessions: sessions,
            folders: folders,
            membership: membership,
            sortMode: sortMode,
            groupByDate: groupByDate,
            calendar: calendar,
            now: now
        )
    }

    public static func == (lhs: SidebarOrderingInputs, rhs: SidebarOrderingInputs) -> Bool {
        lhs.sessions == rhs.sessions
            && lhs.folders == rhs.folders
            && lhs.membership == rhs.membership
            && lhs.sortMode == rhs.sortMode
            && lhs.groupByDate == rhs.groupByDate
            && lhs.calendar == rhs.calendar
            && lhs.now == rhs.now
    }
}

fileprivate struct SidebarOrderingStorageValidity: Equatable {
    private let sessionsStorage: UInt
    private let sessionsCount: Int
    private let foldersStorage: UInt
    private let foldersCount: Int
    private let membershipStorage: UInt64
    private let membershipCount: Int
    private let sortMode: SortMode
    private let groupByDate: Bool
    private let calendar: Calendar
    private let now: Date

    init(
        sessions: [ChatSession],
        folders: [Folder],
        membership: [String: String],
        sortMode: SortMode,
        groupByDate: Bool,
        calendar: Calendar,
        now: Date
    ) {
        sessionsStorage = arrayStorageIdentity(sessions)
        sessionsCount = sessions.count
        foldersStorage = arrayStorageIdentity(folders)
        foldersCount = folders.count
        membershipStorage = dictionaryStorageIdentity(membership)
        membershipCount = membership.count
        self.sortMode = sortMode
        self.groupByDate = groupByDate
        self.calendar = calendar
        self.now = now
    }
}

private func arrayStorageIdentity<Element>(_ values: [Element]) -> UInt {
    values.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return 0 }
        return UInt(bitPattern: UnsafeRawPointer(baseAddress))
    }
}

private func dictionaryStorageIdentity(_ values: [String: String]) -> UInt64 {
    // Dictionary has no public storage-address API. Its value representation
    // is a fixed-size COW handle, so reading those bytes is an O(1) identity
    // token. SidebarOrderingMemo retains the prior input, which keeps the
    // storage alive and prevents allocator reuse from making this token stale.
    // A future representation change can only force the equality fallback.
    withUnsafeBytes(of: values) { bytes in
        var token = UInt64(0)
        for (index, byte) in bytes.prefix(MemoryLayout<UInt64>.size).enumerated() {
            token |= UInt64(byte) << UInt64(index * 8)
        }
        return token
    }
}

/// Memoizes the pure sidebar ordering projection until an ordering input
/// changes. The owner is the main-actor sidebar view; this value type keeps the
/// cache's behavior easy to exercise without SwiftUI.
public struct SidebarOrderingMemo {
    // Retain the collections while their storage tokens are resident.
    private var input: SidebarOrderingInputs?
    private var projection: SidebarOrderingProjection?
    public private(set) var rebuildCount = 0

    public init() {}

    public mutating func resolve(_ input: SidebarOrderingInputs) -> SidebarOrderingProjection {
        if let cachedInput = self.input, let projection {
            if cachedInput.storageValidity == input.storageValidity {
                return projection
            }
            // Different storage can still contain equal values. Keep this
            // fallback because storage identity is only a fast-path proof.
            if cachedInput == input {
                self.input = input
                return projection
            }
        }
        let next = SidebarOrderingProjection(
            sections: sidebarRows(
                sessions: input.sessions,
                folders: input.folders,
                membership: input.membership,
                sortMode: input.sortMode,
                groupByDate: input.groupByDate,
                calendar: input.calendar,
                now: input.now
            )
        )
        self.input = input
        projection = next
        rebuildCount += 1
        return next
    }
}


/// Rebuilds the complete sidebar ordering from immutable inputs.
public func sidebarRows(
    sessions: [ChatSession],
    folders: [Folder],
    membership: [String: String],
    sortMode: SortMode,
    groupByDate: Bool,
    calendar: Calendar,
    now: Date
) -> [SidebarSection] {
    var prepared = [PreparedSidebarSession]()
    prepared.reserveCapacity(sessions.count)

    var scheduledIndexes = [Int]()
    scheduledIndexes.reserveCapacity(sessions.count)
    var pinnedIndexes = [Int]()
    pinnedIndexes.reserveCapacity(sessions.count)
    var unfiledIndexes = [Int]()
    unfiledIndexes.reserveCapacity(sessions.count)

    var folderIndexByID = Dictionary<String, Int>(minimumCapacity: folders.count)
    for (index, folder) in folders.enumerated() {
        folderIndexByID[folder.id] = index
    }

    var folderIndexes = [[Int]]()
    folderIndexes.reserveCapacity(folders.count)
    for _ in folders {
        folderIndexes.append([])
    }

    for session in sessions {
        let index = prepared.count
        prepared.append(PreparedSidebarSession(session: session))
        let isScheduled = SidebarOrderingConstants.isScheduled(session)

        // Every session belongs to exactly one bucket. Schedules take
        // precedence over filing and pinning; a valid folder takes
        // precedence over the pinned section while retaining the row's
        // pinned state for its indicator.
        if isScheduled {
            scheduledIndexes.append(index)
        } else if let folderID = membership[session.id],
                  let folderIndex = folderIndexByID[folderID] {
            folderIndexes[folderIndex].append(index)
        } else if session.pinned {
            pinnedIndexes.append(index)
        } else {
            unfiledIndexes.append(index)
        }
    }

    let orderedFolderIndexes = folders.indices.sorted { lhs, rhs in
        let left = folders[lhs]
        let right = folders[rhs]
        if left.order != right.order { return left.order < right.order }
        if left.name != right.name { return left.name < right.name }
        return left.id < right.id || (left.id == right.id && lhs < rhs)
    }

    var sections = [SidebarSection]()
    sections.reserveCapacity(2 + folders.count + DateBucket.allCases.count)

    if !scheduledIndexes.isEmpty {
        let kind = SidebarSectionKind.schedules
        sections.append(SidebarSection(
            id: kind,
            kind: kind,
            rows: makeRows(
                indexes: sortedIndexes(scheduledIndexes, prepared: prepared, sortMode: sortMode),
                kind: kind,
                prepared: prepared
            )
        ))
    }

    if !pinnedIndexes.isEmpty {
        let kind = SidebarSectionKind.pinned
        sections.append(SidebarSection(
            id: kind,
            kind: kind,
            rows: makeRows(
                indexes: sortedIndexes(pinnedIndexes, prepared: prepared, sortMode: sortMode),
                kind: kind,
                prepared: prepared
            )
        ))
    }

    for folderIndex in orderedFolderIndexes {
        let folder = folders[folderIndex]
        let kind = SidebarSectionKind.folder(id: folder.id, name: folder.name)
        let indexes = sortedIndexes(folderIndexes[folderIndex], prepared: prepared, sortMode: sortMode)
        sections.append(SidebarSection(
            id: kind,
            kind: kind,
            rows: makeRows(indexes: indexes, kind: kind, prepared: prepared)
        ))
    }

    if groupByDate {
        var bucketIndexes = [DateBucket: [Int]]()
        bucketIndexes.reserveCapacity(DateBucket.allCases.count)
        for bucket in DateBucket.allCases {
            bucketIndexes[bucket] = []
        }
        for index in unfiledIndexes {
            let bucket = dateBucket(for: prepared[index].activeDate, calendar: calendar, now: now)
            bucketIndexes[bucket, default: []].append(index)
        }

        for bucket in DateBucket.allCases {
            guard let indexes = bucketIndexes[bucket], !indexes.isEmpty else { continue }
            let kind = SidebarSectionKind.bucket(bucket)
            sections.append(SidebarSection(
                id: kind,
                kind: kind,
                rows: makeRows(
                    indexes: sortedIndexes(indexes, prepared: prepared, sortMode: sortMode),
                    kind: kind,
                    prepared: prepared
                )
            ))
        }
    } else if !unfiledIndexes.isEmpty {
        let kind = SidebarSectionKind.ungrouped
        sections.append(SidebarSection(
            id: kind,
            kind: kind,
            rows: makeRows(
                indexes: sortedIndexes(unfiledIndexes, prepared: prepared, sortMode: sortMode),
                kind: kind,
                prepared: prepared
            )
        ))
    }

    return sections
}

enum SidebarOrderingConstants {
    static let titleLocale = Locale(identifier: "en_US_POSIX")
    private static let cronSource = "cron"

    static func isScheduled(_ session: ChatSession) -> Bool {
        session.source == cronSource
    }
}

private struct PreparedSidebarSession {
    let session: ChatSession
    let titleKey: String
    let activeDate: Date?

    init(session: ChatSession) {
        self.session = session
        titleKey = session.displayTitle.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: SidebarOrderingConstants.titleLocale
        )
        activeDate = session.lastActive ?? session.startedAt
    }
}

private func sortedIndexes(
    _ indexes: [Int],
    prepared: [PreparedSidebarSession],
    sortMode: SortMode
) -> [Int] {
    indexes.sorted { lhs, rhs in
        let left = prepared[lhs]
        let right = prepared[rhs]

        switch sortMode {
        case .lastActivity:
            if let result = compareDescending(left.activeDate, right.activeDate), result != 0 {
                return result < 0
            }
        case .created:
            if let result = compareDescending(left.session.startedAt, right.session.startedAt), result != 0 {
                return result < 0
            }
        case .title:
            if left.titleKey != right.titleKey {
                return left.titleKey < right.titleKey
            }
        }

        if let result = compareDescending(left.session.lastActive, right.session.lastActive), result != 0 {
            return result < 0
        }
        if let result = compareDescending(left.session.startedAt, right.session.startedAt), result != 0 {
            return result < 0
        }
        return left.session.id < right.session.id
    }
}

private func compareDescending(_ lhs: Date?, _ rhs: Date?) -> Int? {
    if lhs == rhs { return 0 }
    guard let lhs else { return 1 }
    guard let rhs else { return -1 }
    return lhs > rhs ? -1 : 1
}

private func makeRows(
    indexes: [Int],
    kind: SidebarSectionKind,
    prepared: [PreparedSidebarSession]
) -> [SidebarRow] {
    var rows = [SidebarRow]()
    rows.reserveCapacity(indexes.count)
    for index in indexes {
        let session = prepared[index].session
        rows.append(SidebarRow(
            id: SidebarRowID(section: kind, sessionID: session.id),
            sessionID: session.id,
            session: session
        ))
    }
    return rows
}

private func dateBucket(for date: Date?, calendar: Calendar, now: Date) -> DateBucket {
    guard let date else { return .older }
    let today = calendar.startOfDay(for: now)
    let dateStart = calendar.startOfDay(for: date)
    let dayDifference = calendar.dateComponents([.day], from: dateStart, to: today).day ?? Int.max

    switch dayDifference {
    case ...0:
        return .today
    case 1:
        return .yesterday
    case 2...7:
        return .previousSevenDays
    case 8...30:
        return .previousThirtyDays
    default:
        return .older
    }
}
