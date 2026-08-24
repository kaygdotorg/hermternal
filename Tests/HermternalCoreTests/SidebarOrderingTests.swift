import Foundation
import HermternalCore
import Testing

@Test("Pinned filed sessions appear only in their folder and empty folders remain visible")
func sidebarRowsKeepPinnedAndFolderRows() {
    let pinned = testSession(id: "pinned", title: "Pinned", startedAt: 100, lastActive: 300, pinned: true)
    let filed = testSession(id: "filed", title: "Filed", startedAt: 200, lastActive: 200)
    let unfiled = testSession(id: "unfiled", title: "Unfiled", startedAt: 100, lastActive: 100)
    let folder = Folder(id: "work", name: "Work", order: 0)
    let empty = Folder(id: "empty", name: "Empty", order: 1)

    let sections = sidebarRows(
        sessions: [pinned, filed, unfiled],
        folders: [folder, empty],
        membership: ["pinned": "work", "filed": "work"],
        sortMode: .lastActivity,
        groupByDate: false,
        calendar: Calendar(identifier: .gregorian),
        now: Date(timeIntervalSince1970: 400)
    )

    let workKind = SidebarSectionKind.folder(id: "work", name: "Work")
    let emptyKind = SidebarSectionKind.folder(id: "empty", name: "Empty")
    #expect(sections.map(\.kind) == [workKind, emptyKind, .ungrouped])
    #expect(sections[0].rows.map(\.sessionID) == ["pinned", "filed"])
    #expect(sections[0].rows[0].session.pinned)
    #expect(sections[1].rows.isEmpty)
    #expect(sections[2].rows.map(\.sessionID) == ["unfiled"])
}

@Test("Every session has one unique selection identity across sidebar buckets")
func sidebarRowsKeepSelectionIdentitiesUnique() {
    let folder = Folder(id: "work", name: "Work", order: 0)
    let sessions = [
        testSession(id: "cron", title: "Cron", startedAt: 400, lastActive: 400, pinned: true, source: "cron"),
        testSession(id: "pinned", title: "Pinned", startedAt: 300, lastActive: 300, pinned: true),
        testSession(id: "filed", title: "Filed", startedAt: 200, lastActive: 200),
        testSession(id: "plain", title: "Plain", startedAt: 100, lastActive: 100)
    ]

    let sections = sidebarRows(
        sessions: sessions,
        folders: [folder],
        membership: ["cron": "work", "filed": "work"],
        sortMode: .lastActivity,
        groupByDate: true,
        calendar: Calendar(identifier: .gregorian),
        now: Date(timeIntervalSince1970: 500)
    )

    let selectionIDs = sections.flatMap { $0.rows }.map { SidebarSelectionID.chat($0.sessionID) }
    #expect(selectionIDs.count == sessions.count)
    #expect(Set(selectionIDs).count == selectionIDs.count)
    #expect(Set(selectionIDs) == Set(sessions.map { SidebarSelectionID.chat($0.id) }))
}

@Test("Cron sessions appear in Schedules and not in date buckets")
func sidebarRowsPartitionCronSessionsFromDateBuckets() {
    let cron = testSession(
        id: "cron",
        title: "Scheduled",
        startedAt: 900,
        lastActive: 900,
        source: "cron"
    )
    let chat = testSession(id: "chat", title: "Chat", startedAt: 800, lastActive: 800)

    let sections = sidebarRows(
        sessions: [cron, chat],
        folders: [],
        membership: [:],
        sortMode: .lastActivity,
        groupByDate: true,
        calendar: Calendar(identifier: .gregorian),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(sections.map(\.kind) == [.schedules, .bucket(.today)])
    #expect(sections[0].rows.map(\.sessionID) == ["cron"])
    #expect(sections[1].rows.map(\.sessionID) == ["chat"])
}

@Test("Schedules is first and absent when no cron sessions exist")
func sidebarRowsScheduleSectionPresence() {
    let withoutCron = sidebarRows(
        sessions: [testSession(id: "chat", title: "Chat", startedAt: 100, lastActive: 100)],
        folders: [],
        membership: [:],
        sortMode: .lastActivity,
        groupByDate: false,
        calendar: Calendar(identifier: .gregorian),
        now: Date(timeIntervalSince1970: 200)
    )
    #expect(withoutCron.map(\.kind) == [.ungrouped])

    let withCron = sidebarRows(
        sessions: [
            testSession(id: "chat", title: "Chat", startedAt: 100, lastActive: 100),
            testSession(id: "cron", title: "Cron", startedAt: 100, lastActive: 100, source: "cron")
        ],
        folders: [],
        membership: [:],
        sortMode: .lastActivity,
        groupByDate: false,
        calendar: Calendar(identifier: .gregorian),
        now: Date(timeIntervalSince1970: 200)
    )
    #expect(withCron.map(\.kind) == [.schedules, .ungrouped])
}

@Test("Section order is Schedules, Pinned, folders, then date buckets")
func sidebarRowsOrderAllSectionKinds() {
    let folder = Folder(id: "work", name: "Work", order: 0)
    let sections = sidebarRows(
        sessions: [
            testSession(id: "cron", title: "Cron", startedAt: 100, lastActive: 100, source: "cron"),
            testSession(id: "pinned", title: "Pinned", startedAt: 100, lastActive: 100, pinned: true),
            testSession(id: "filed", title: "Filed", startedAt: 100, lastActive: 100),
            testSession(id: "chat", title: "Chat", startedAt: 100, lastActive: 100)
        ],
        folders: [folder],
        membership: ["filed": "work"],
        sortMode: .lastActivity,
        groupByDate: true,
        calendar: Calendar(identifier: .gregorian),
        now: Date(timeIntervalSince1970: 200)
    )

    #expect(sections.map(\.kind) == [
        .schedules,
        .pinned,
        .folder(id: "work", name: "Work"),
        .bucket(.today)
    ])
}

@Test("A pinned cron session belongs only to Schedules")
func sidebarRowsPinnedCronSessionUsesSchedules() {
    let sections = sidebarRows(
        sessions: [
            testSession(
                id: "cron",
                title: "Cron",
                startedAt: 100,
                lastActive: 100,
                pinned: true,
                source: "cron"
            )
        ],
        folders: [],
        membership: [:],
        sortMode: .lastActivity,
        groupByDate: true,
        calendar: Calendar(identifier: .gregorian),
        now: Date(timeIntervalSince1970: 200)
    )

    #expect(sections.map(\.kind) == [.schedules])
    #expect(sections[0].rows.map(\.sessionID) == ["cron"])
}

@Test("Schedules honors every sort mode")
func sidebarRowsSchedulesSortModes() {
    let sessions = [
        testSession(id: "last", title: "Bravo", startedAt: 100, lastActive: 300, source: "cron"),
        testSession(id: "created", title: "Charlie", startedAt: 300, lastActive: 100, source: "cron"),
        testSession(id: "title", title: "Alpha", startedAt: 200, lastActive: 200, source: "cron")
    ]
    let calendar = Calendar(identifier: .gregorian)
    let expected: [(SortMode, [String])] = [
        (.lastActivity, ["last", "title", "created"]),
        (.created, ["created", "title", "last"]),
        (.title, ["title", "last", "created"])
    ]

    for (sortMode, ids) in expected {
        let sections = sidebarRows(
            sessions: sessions,
            folders: [],
            membership: [:],
            sortMode: sortMode,
            groupByDate: false,
            calendar: calendar,
            now: Date(timeIntervalSince1970: 400)
        )
        #expect(sections.map(\.kind) == [.schedules])
        #expect(sections[0].rows.map(\.sessionID) == ids)
    }
}

@Test("Ungrouped mode keeps pinned and folders before one ungrouped section")
func sidebarRowsCollapseDateBuckets() {
    let pinned = testSession(id: "pinned", title: "Pinned", startedAt: 10, lastActive: 30, pinned: true)
    let filed = testSession(id: "filed", title: "Filed", startedAt: 20, lastActive: 20)
    let first = testSession(id: "first", title: "First", startedAt: 15, lastActive: 15)
    let second = testSession(id: "second", title: "Second", startedAt: 10, lastActive: 10)
    let folder = Folder(id: "folder", name: "Folder", order: 0)

    let sections = sidebarRows(
        sessions: [second, pinned, first, filed],
        folders: [folder],
        membership: ["filed": "folder"],
        sortMode: .lastActivity,
        groupByDate: false,
        calendar: Calendar(identifier: .gregorian),
        now: Date(timeIntervalSince1970: 100)
    )

    #expect(sections.map(\.kind) == [.pinned, .folder(id: "folder", name: "Folder"), .ungrouped])
    #expect(sections[0].rows.map(\.id) == [rowID(.pinned, "pinned")])
    #expect(sections[1].rows.map(\.id) == [rowID(.folder(id: "folder", name: "Folder"), "filed")])
    #expect(sections[2].rows.map(\.id) == [rowID(.ungrouped, "first"), rowID(.ungrouped, "second")])
}

@Test("Every sort mode orders rows by its primary key")
func sidebarRowsSortModes() {
    let sessions = [
        testSession(id: "zulu", title: "Zulu", startedAt: 100, lastActive: 300),
        testSession(id: "bravo", title: "alpha", startedAt: 300, lastActive: 100),
        testSession(id: "alpha", title: "Alpha", startedAt: 200, lastActive: 200)
    ]
    let calendar = Calendar(identifier: .gregorian)

    let lastActivity = sidebarRows(
        sessions: sessions,
        folders: [],
        membership: [:],
        sortMode: .lastActivity,
        groupByDate: false,
        calendar: calendar,
        now: Date(timeIntervalSince1970: 400)
    )
    let created = sidebarRows(
        sessions: sessions,
        folders: [],
        membership: [:],
        sortMode: .created,
        groupByDate: false,
        calendar: calendar,
        now: Date(timeIntervalSince1970: 400)
    )
    let title = sidebarRows(
        sessions: sessions,
        folders: [],
        membership: [:],
        sortMode: .title,
        groupByDate: false,
        calendar: calendar,
        now: Date(timeIntervalSince1970: 400)
    )

    #expect(lastActivity[0].rows.map(\.id) == [rowID(.ungrouped, "zulu"), rowID(.ungrouped, "alpha"), rowID(.ungrouped, "bravo")])
    #expect(created[0].rows.map(\.id) == [rowID(.ungrouped, "bravo"), rowID(.ungrouped, "alpha"), rowID(.ungrouped, "zulu")])
    #expect(title[0].rows.map(\.id) == [rowID(.ungrouped, "alpha"), rowID(.ungrouped, "bravo"), rowID(.ungrouped, "zulu")])
}

@Test("Missing last activity falls back to started date and missing dates are older")
func sidebarRowsUseStartedDateFallback() {
    let fallback = testSession(id: "fallback", title: "Fallback", startedAt: 1_000)
    let noDate = testSession(id: "no-date", title: "No Date")
    let calendar = Calendar(identifier: .gregorian)

    let sections = sidebarRows(
        sessions: [noDate, fallback],
        folders: [],
        membership: [:],
        sortMode: .lastActivity,
        groupByDate: true,
        calendar: calendar,
        now: Date(timeIntervalSince1970: 1_500)
    )

    #expect(sections.map(\.kind) == [.bucket(.today), .bucket(.older)])
    #expect(sections[0].rows.map(\.id) == [rowID(.bucket(.today), "fallback")])
    #expect(sections[1].rows.map(\.id) == [rowID(.bucket(.older), "no-date")])
}

@Test("Identical dates use the durable id as the final tie-break")
func sidebarRowsUseIDTieBreak() {
    let date = 1_000.0
    let zulu = testSession(id: "zulu", title: "Same", startedAt: date, lastActive: date)
    let alpha = testSession(id: "alpha", title: "Same", startedAt: date, lastActive: date)

    let sections = sidebarRows(
        sessions: [zulu, alpha],
        folders: [],
        membership: [:],
        sortMode: .lastActivity,
        groupByDate: false,
        calendar: Calendar(identifier: .gregorian),
        now: Date(timeIntervalSince1970: 2_000)
    )

    #expect(sections.map(\.kind) == [.ungrouped])
    #expect(sections[0].rows.map(\.id) == [rowID(.ungrouped, "alpha"), rowID(.ungrouped, "zulu")])
}

@Test("Date buckets use calendar days across daylight-saving transitions")
func sidebarRowsUseCalendarDayBoundaries() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    let now = calendar.date(from: DateComponents(year: 2024, month: 4, day: 1, hour: 0, minute: 30))!
    let beforeTransition = calendar.date(from: DateComponents(year: 2024, month: 3, day: 30, hour: 23, minute: 45))!
    let session = testSession(
        id: "dst",
        title: "DST",
        startedAt: beforeTransition.timeIntervalSince1970,
        lastActive: beforeTransition.timeIntervalSince1970
    )

    let sections = sidebarRows(
        sessions: [session],
        folders: [],
        membership: [:],
        sortMode: .lastActivity,
        groupByDate: true,
        calendar: calendar,
        now: now
    )

    #expect(sections.map(\.kind) == [.bucket(.previousSevenDays)])
    #expect(sections[0].rows.map(\.id) == [rowID(.bucket(.previousSevenDays), "dst")])
}

@Test("Performance contract records rebuild cost at three sidebar sizes")
func sidebarRowsPerformanceContract() {
    var measurements = [String]()
    let calendar = Calendar(identifier: .gregorian)
    let now = Date(timeIntervalSince1970: 2_000_000)

    for count in [200, 1_000, 5_000] {
        let cronCount = (count + 19) / 20
        let sessions = (0..<count).map { index in
            testSession(
                id: "session-\(index)",
                title: "Synthetic \(index)",
                startedAt: Double(index),
                lastActive: Double(index + count),
                source: index % 20 == 0 ? "cron" : nil
            )
        }
        let start = ContinuousClock.now
        let sections = sidebarRows(
            sessions: sessions,
            folders: [],
            membership: [:],
            sortMode: .lastActivity,
            groupByDate: true,
            calendar: calendar,
            now: now
        )
        let elapsed = start.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        // A performance contract measures cost. It asserts only invariants that
        // hold for any `now`, because pinning an exact bucket would make the
        // measurement fail whenever a boundary rule changes. The dedicated
        // ordering tests own exact section sequences.
        #expect(sections.first?.kind == .schedules)
        #expect(sections[0].rows.count == cronCount)
        let placed = sections.reduce(into: Set<String>()) { ids, section in
            for row in section.rows { ids.insert(row.sessionID) }
        }
        #expect(placed.count == count)
        #expect(sections.dropFirst().reduce(0) { $0 + $1.rows.count } == count - cronCount)
        measurements.append("\(count)=\(String(format: "%.3f", milliseconds))ms")
    }

    print("PERF|sidebar rebuild|" + measurements.joined(separator: " "))
}

@Test("Ordering memo ignores selection-only passes and refreshes on ordering inputs")
func sidebarOrderingMemoInvalidation() {
    let calendar = Calendar(identifier: .gregorian)
    let now = Date(timeIntervalSince1970: 2_000_000)
    let baseSession = testSession(
        id: "memo",
        title: "Memo",
        startedAt: 1,
        lastActive: 2
    )
    let baseFolder = Folder(id: "folder", name: "Folder", order: 0)
    let baseInput = SidebarOrderingInputs(
        sessions: [baseSession],
        folders: [baseFolder],
        membership: [:],
        sortMode: .lastActivity,
        groupByDate: true,
        calendar: calendar,
        now: now
    )

    var memo = SidebarOrderingMemo()
    let first = memo.resolve(baseInput)
    let selectionOnlyPass = memo.resolve(baseInput)
    #expect(first == selectionOnlyPass)
    #expect(memo.rebuildCount == 1)

    let equivalentInput = SidebarOrderingInputs(
        sessions: baseInput.sessions.map { $0 },
        folders: baseInput.folders.map { $0 },
        membership: Dictionary(
            baseInput.membership.map { ($0.key, $0.value) },
            uniquingKeysWith: { first, _ in first }
        ),
        sortMode: baseInput.sortMode,
        groupByDate: baseInput.groupByDate,
        calendar: baseInput.calendar,
        now: baseInput.now
    )
    let equivalentProjection = memo.resolve(equivalentInput)
    #expect(equivalentProjection == first)
    #expect(memo.rebuildCount == 1)

    let sessionRefresh = SidebarOrderingInputs(
        sessions: [baseSession.withTitle("Renamed")],
        folders: baseInput.folders,
        membership: baseInput.membership,
        sortMode: baseInput.sortMode,
        groupByDate: baseInput.groupByDate,
        calendar: baseInput.calendar,
        now: baseInput.now
    )
    _ = memo.resolve(sessionRefresh)
    #expect(memo.rebuildCount == 2)
    _ = memo.resolve(sessionRefresh)
    #expect(memo.rebuildCount == 2)

    let membershipRefresh = SidebarOrderingInputs(
        sessions: sessionRefresh.sessions,
        folders: sessionRefresh.folders,
        membership: ["memo": "folder"],
        sortMode: sessionRefresh.sortMode,
        groupByDate: sessionRefresh.groupByDate,
        calendar: sessionRefresh.calendar,
        now: sessionRefresh.now
    )
    let moved = memo.resolve(membershipRefresh)
    #expect(memo.rebuildCount == 3)
    _ = memo.resolve(membershipRefresh)
    #expect(memo.rebuildCount == 3)
    #expect(
        moved.sections.contains {
            if case .folder(id: "folder", name: "Folder") = $0.kind {
                return $0.rows.map(\.sessionID) == ["memo"]
            }
            return false
        }
    )

    let membershipValueRefresh = SidebarOrderingInputs(
        sessions: membershipRefresh.sessions,
        folders: membershipRefresh.folders,
        membership: ["memo": "other"],
        sortMode: membershipRefresh.sortMode,
        groupByDate: membershipRefresh.groupByDate,
        calendar: membershipRefresh.calendar,
        now: membershipRefresh.now
    )
    _ = memo.resolve(membershipValueRefresh)
    #expect(memo.rebuildCount == 4)
    _ = memo.resolve(membershipValueRefresh)
    #expect(memo.rebuildCount == 4)

    let folderRefresh = SidebarOrderingInputs(
        sessions: membershipValueRefresh.sessions,
        folders: [Folder(id: "folder", name: "Renamed Folder", order: 0)],
        membership: membershipValueRefresh.membership,
        sortMode: membershipValueRefresh.sortMode,
        groupByDate: membershipValueRefresh.groupByDate,
        calendar: membershipValueRefresh.calendar,
        now: membershipValueRefresh.now
    )
    let renamed = memo.resolve(folderRefresh)
    #expect(memo.rebuildCount == 5)
    _ = memo.resolve(folderRefresh)
    #expect(memo.rebuildCount == 5)
    #expect(
        renamed.sections.contains {
            if case .folder(id: "folder", name: "Renamed Folder") = $0.kind {
                return true
            }
            return false
        }
    )

    let sortRefresh = SidebarOrderingInputs(
        sessions: folderRefresh.sessions,
        folders: folderRefresh.folders,
        membership: folderRefresh.membership,
        sortMode: .title,
        groupByDate: folderRefresh.groupByDate,
        calendar: folderRefresh.calendar,
        now: folderRefresh.now
    )
    _ = memo.resolve(sortRefresh)
    #expect(memo.rebuildCount == 6)

    let groupingRefresh = SidebarOrderingInputs(
        sessions: sortRefresh.sessions,
        folders: sortRefresh.folders,
        membership: sortRefresh.membership,
        sortMode: sortRefresh.sortMode,
        groupByDate: false,
        calendar: sortRefresh.calendar,
        now: sortRefresh.now
    )
    _ = memo.resolve(groupingRefresh)
    #expect(memo.rebuildCount == 7)

    var timeZoneRefreshCalendar = groupingRefresh.calendar
    timeZoneRefreshCalendar.timeZone = TimeZone(secondsFromGMT: 3_600)!
    let calendarRefresh = SidebarOrderingInputs(
        sessions: groupingRefresh.sessions,
        folders: groupingRefresh.folders,
        membership: groupingRefresh.membership,
        sortMode: groupingRefresh.sortMode,
        groupByDate: groupingRefresh.groupByDate,
        calendar: timeZoneRefreshCalendar,
        now: groupingRefresh.now
    )
    _ = memo.resolve(calendarRefresh)
    #expect(memo.rebuildCount == 8)

    let nowRefresh = SidebarOrderingInputs(
        sessions: calendarRefresh.sessions,
        folders: calendarRefresh.folders,
        membership: calendarRefresh.membership,
        sortMode: calendarRefresh.sortMode,
        groupByDate: calendarRefresh.groupByDate,
        calendar: calendarRefresh.calendar,
        now: calendarRefresh.now.addingTimeInterval(86_400)
    )
    _ = memo.resolve(nowRefresh)
    #expect(memo.rebuildCount == 9)
    _ = memo.resolve(nowRefresh)
    #expect(memo.rebuildCount == 9)
}

private func rowID(_ section: SidebarSectionKind, _ sessionID: String) -> SidebarRowID {
    SidebarRowID(section: section, sessionID: sessionID)
}

private func testSession(
    id: String,
    title: String,
    startedAt: TimeInterval? = nil,
    lastActive: TimeInterval? = nil,
    pinned: Bool = false,
    source: String? = nil
) -> ChatSession {
    var value: [String: JSONValue] = [
        "id": .string(id),
        "title": .string(title),
        "pinned": .bool(pinned)
    ]
    if let startedAt { value["started_at"] = .number(startedAt) }
    if let source { value["source"] = .string(source) }
    if let lastActive { value["last_active"] = .number(lastActive) }
    return ChatSession(from: .object(value))
}
