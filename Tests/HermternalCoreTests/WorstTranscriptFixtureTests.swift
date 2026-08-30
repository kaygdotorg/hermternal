import XCTest
@testable import HermternalCore

final class WorstTranscriptFixtureTests: XCTestCase {
    func testProfilesHaveFiniteNamedEnvelopes() {
        XCTAssertEqual(AppMemoryProfile.iPhone100.totalBytes, 100 * 1_048_576)
        XCTAssertEqual(AppMemoryProfile.iPad216.totalBytes, 216 * 1_048_576)
        XCTAssertEqual(AppMemoryProfile.mac440MiB.totalBytes, 440 * 1_048_576)

        for profile in [AppMemoryProfile.iPhone100, .iPad216, .mac440MiB] {
            XCTAssertTrue(profile.categoryLimits.values.allSatisfy { $0 >= 0 })
            XCTAssertLessThanOrEqual(
                profile.categoryLimits.values.reduce(0, +),
                profile.totalBytes
            )
        }
    }

    func testRegistryRejectsCategoryAndGlobalOverflowWithCounters() {
        let profile = AppMemoryProfile(
            name: "test",
            totalBytes: 10,
            categoryLimits: [.sidebar: 6, .search: 10]
        )
        let registry = AppMemoryRegistry(profile: profile)
        let admitted = registry.admit(category: .sidebar, bytes: 6)
        XCTAssertNotNil(admitted)
        XCTAssertNil(registry.admit(category: .sidebar, bytes: 1))
        XCTAssertNil(registry.admit(category: .search, bytes: 5))

        if let admitted {
            registry.evict(admitted)
        }
        let metrics = registry.metrics()
        XCTAssertEqual(metrics.residentBytes, 0)
        XCTAssertEqual(metrics.categories[.sidebar]?.admittedBytes, 6)
        XCTAssertEqual(metrics.categories[.sidebar]?.rejectedBytes, 1)
        XCTAssertEqual(metrics.categories[.sidebar]?.evictedBytes, 6)
        XCTAssertEqual(metrics.categories[.sidebar]?.evictionCount, 1)
        XCTAssertEqual(metrics.categories[.search]?.rejectedBytes, 5)
    }

    func testWorstV1FixtureCoversEveryWorkloadAndSettles() {
        let profiles = [
            AppMemoryProfile.iPhone100,
            AppMemoryProfile.iPad216,
            AppMemoryProfile.mac440MiB
        ]
        for profile in profiles {
            let report = WorstTranscriptFixture.run(profile: profile)
            XCTAssertEqual(report.fixtureVersion, WorstTranscriptFixture.version)
            XCTAssertEqual(report.sessionCount, 10_000)
            XCTAssertEqual(report.folderCount, 1_000)
            XCTAssertEqual(report.attachmentCount, 8)
            XCTAssertTrue(report.attachmentsAreFileBacked)
            XCTAssertEqual(report.thumbnailBytes, 2 * 1_048_576)
            XCTAssertEqual(report.audioPCMBytes, 1 * 1_048_576)
            XCTAssertEqual(report.residentAttachmentDataCount, 0)
            XCTAssertEqual(report.headVisits, 1)
            XCTAssertEqual(report.tailVisits, 1)
            XCTAssertEqual(report.searchQueries, 1)
            XCTAssertEqual(report.findQueries, 1)
            XCTAssertEqual(report.switchCount, 20)
            XCTAssertEqual(report.streamChunks, 20)
            XCTAssertEqual(report.stalePublications, 0)
            XCTAssertTrue(report.everyCategoryWithinEnvelope)
            XCTAssertTrue(report.withinProfileEnvelope)
            XCTAssertEqual(report.settledResidentBytes, 0)
            XCTAssertLessThanOrEqual(report.settledGrowthBytes, report.settledGrowthLimitBytes)
            let expectedSettledLimit: Int
            switch profile.totalBytes {
            case 100 * 1_048_576:
                expectedSettledLimit = 16 * 1_048_576
            case 216 * 1_048_576:
                expectedSettledLimit = 24 * 1_048_576
            default:
                expectedSettledLimit = 32 * 1_048_576
            }
            XCTAssertEqual(report.settledGrowthLimitBytes, expectedSettledLimit)

            let categories = report.metrics.categories
            for category in AppMemoryCategory.allCases {
                XCTAssertNotNil(categories[category])
                XCTAssertLessThanOrEqual(
                    categories[category]?.peakBytes ?? Int.max,
                    profile.limit(for: category)
                )
            }
            for category in [
                AppMemoryCategory.activeTranscript,
                .preparedContent,
                .find,
                .search,
                .sidebar,
                .prefetch
            ] {
                XCTAssertEqual(
                    categories[category]?.peakBytes,
                    profile.limit(for: category)
                )
            }
        }
    }

    func testSidebarMemoDropsOversizedGeneration() {
        let session = ChatSession(from: .object([
            "id": .string("oversized"),
            "title": .string("Oversized"),
            "preview": .string("Sidebar input"),
            "started_at": .number(1),
            "last_active": .number(1)
        ]))
        let input = SidebarOrderingInputs(
            sessions: [session],
            folders: [],
            membership: [:],
            sortMode: .lastActivity,
            groupByDate: false,
            calendar: Calendar(identifier: .gregorian),
            now: Date(timeIntervalSince1970: 1)
        )
        var memo = SidebarOrderingMemo(maxRetainedBytes: 1)
        _ = memo.resolve(input)
        _ = memo.resolve(input)
        XCTAssertEqual(memo.rebuildCount, 2)
    }
}
