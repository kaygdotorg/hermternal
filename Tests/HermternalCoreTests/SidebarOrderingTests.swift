import Foundation
import HermternalCore
import Testing

@Test("Pinned filed sessions have distinct row identities and empty folders remain visible")
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
    #expect(sections.map(\.kind) == [.pinned, workKind, emptyKind, .ungrouped])
    #expect(sections[0].rows.map(\.sessionID) == ["pinned"])
    #expect(sections[1].rows.map(\.sessionID) == ["pinned", "filed"])
    #expect(sections[2].rows.isEmpty)
    #expect(sections[3].rows.map(\.sessionID) == ["unfiled"])

    let pinnedRowID = sections[0].rows[0].id
    let filedRowID = sections[1].rows[0].id
    #expect(pinnedRowID != filedRowID)
    #expect(sections[0].rows[0].sessionID == sections[1].rows[0].sessionID)
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
        let sessions = (0..<count).map { index in
            testSession(
                id: "session-\(index)",
                title: "Synthetic \(index)",
                startedAt: Double(index),
                lastActive: Double(index + count)
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
        #expect(sections.count == 1)
        #expect(sections[0].rows.count == count)
        measurements.append("\(count)=\(String(format: "%.3f", milliseconds))ms")
    }

    print("PERF|sidebar rebuild|" + measurements.joined(separator: " "))
}

private func rowID(_ section: SidebarSectionKind, _ sessionID: String) -> SidebarRowID {
    SidebarRowID(section: section, sessionID: sessionID)
}

private func testSession(
    id: String,
    title: String,
    startedAt: TimeInterval? = nil,
    lastActive: TimeInterval? = nil,
    pinned: Bool = false
) -> ChatSession {
    var value: [String: JSONValue] = [
        "id": .string(id),
        "title": .string(title),
        "pinned": .bool(pinned)
    ]
    if let startedAt { value["started_at"] = .number(startedAt) }
    if let lastActive { value["last_active"] = .number(lastActive) }
    return ChatSession(from: .object(value))
}
