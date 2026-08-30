import XCTest
@testable import HermternalCore

final class TranscriptMemoryBudgetTests: XCTestCase {
    func testWeightedAdmissionUsesExactChargedBytes() async {
        let profile = TranscriptMemoryProfile(name: "test", byteLimit: 10, categoryWeights: [.index: 3])
        let budget = TranscriptMemoryBudget(profile: profile)
        let admission = await budget.admit(category: .index, bytes: 3)
        XCTAssertEqual(admission?.chargedBytes, 9)
        let rejected = await budget.admit(category: .index, bytes: 1)
        XCTAssertNil(rejected)
        let metrics = await budget.metrics()
        XCTAssertEqual(metrics.usedBytes, 9)
        XCTAssertEqual(metrics.admittedBytes, 9)
        XCTAssertEqual(metrics.rejectedBytes, 3)
        if let admission { await budget.release(admission) }
        let releasedMetrics = await budget.metrics()
        XCTAssertEqual(releasedMetrics.usedBytes, 0)
    }

    func testProfileEnvelopesAndCounters() async {
        XCTAssertEqual(TranscriptMemoryProfile.active4MiB.byteLimit, 4 * 1024 * 1024)
        XCTAssertEqual(TranscriptMemoryProfile.active8MiB.byteLimit, 8 * 1024 * 1024)
        XCTAssertEqual(TranscriptMemoryProfile.active16MiB.byteLimit, 16 * 1024 * 1024)
        let budget = TranscriptMemoryBudget(profile: .active4MiB)
        let admission = await budget.admit(category: .pagePayload, bytes: 1_024)
        XCTAssertNotNil(admission)
        let metrics = await budget.metrics()
        XCTAssertEqual(metrics.admissions[.pagePayload], 1_024)
    }
}
