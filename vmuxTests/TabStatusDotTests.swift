import XCTest
@testable import vmux

final class TabStatusDotTests: XCTestCase {

    func testRunningProducesAmberState() {
        let now = Date()
        let state = TabStatusState(
            isRunning: true,
            lastActivityAt: now,
            now: now
        )
        XCTAssertEqual(state, .running)
    }

    func testRunningTakesPrecedenceOverElapsedTime() {
        // Even if the last byte was a long time ago, an explicit isRunning=true
        // (e.g. fresh activity) must still render amber.
        let now = Date()
        let state = TabStatusState(
            isRunning: true,
            lastActivityAt: now.addingTimeInterval(-120),
            now: now
        )
        XCTAssertEqual(state, .running)
    }

    func testIdleNotYetFiveSecondsShowsJustFinished() {
        let now = Date()
        let state = TabStatusState(
            isRunning: false,
            lastActivityAt: now.addingTimeInterval(-2),
            now: now
        )
        XCTAssertEqual(state, .justFinished)
    }

    func testIdlePastFiveSecondsShowsIdle() {
        let now = Date()
        let state = TabStatusState(
            isRunning: false,
            lastActivityAt: now.addingTimeInterval(-6),
            now: now
        )
        XCTAssertEqual(state, .idle)
    }

    func testFiveSecondBoundaryIsStillJustFinished() {
        // Spec: gray when `now - lastActivityAt > 5s` — so exactly 5s should
        // still be the green pulse, not gray.
        let now = Date()
        let state = TabStatusState(
            isRunning: false,
            lastActivityAt: now.addingTimeInterval(-5),
            now: now
        )
        XCTAssertEqual(state, .justFinished)
    }
}
