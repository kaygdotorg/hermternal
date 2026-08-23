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
        let isScheduled = session.source == SidebarOrderingConstants.cronSource

        if isScheduled {
            scheduledIndexes.append(index)
        }

        // A scheduled session is more informative than its pin, so Schedules
        // wins and the session is not repeated in Pinned.
        if session.pinned && !isScheduled {
            pinnedIndexes.append(index)
        }

        if let folderID = membership[session.id],
           let folderIndex = folderIndexByID[folderID] {
            folderIndexes[folderIndex].append(index)
        } else if !session.pinned && !isScheduled {
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

private enum SidebarOrderingConstants {
    static let titleLocale = Locale(identifier: "en_US_POSIX")
    static let cronSource = "cron"
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
