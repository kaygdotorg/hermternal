import XCTest
@testable import HermternalCore

final class TranscriptRouteContractTests: XCTestCase {
    func testRouteCarriesSessionGenerationAndEpoch() {
        let route = TranscriptRoute(sessionID: "chat-1", generation: 7, epoch: 11)
        XCTAssertEqual(route.sessionID, "chat-1")
        XCTAssertEqual(route.generation, 7)
        XCTAssertEqual(route.epoch, 11)
    }

    func testSummaryDistinguishesExactAndProvisionalCounts() {
        let exact = TranscriptSummary(rowCount: 3, messageCount: 2)
        XCTAssertTrue(exact.isExact)
        XCTAssertEqual(exact.exactRowCount, 3)

        let provisional = TranscriptSummary(
            rowCount: 3,
            messageCount: 2,
            countKind: .provisional,
            generation: 2,
            epoch: 4
        )
        XCTAssertTrue(provisional.isProvisional)
        XCTAssertNil(provisional.exactRowCount)
        XCTAssertEqual(provisional.generation, 2)
        XCTAssertEqual(provisional.epoch, 4)
    }
}
