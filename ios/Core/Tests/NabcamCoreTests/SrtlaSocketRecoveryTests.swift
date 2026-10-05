import XCTest
@testable import NabcamCore

final class SrtlaSocketRecoveryTests: XCTestCase {
    func testOnlyTwoFastSilentReopensThenSlowerPolicy() {
        var history = SrtlaSocketRecovery()
        for attempt in 0..<3 {
            let start = Int64(attempt * 10_000)
            history.opened(at: start); history.ready(at: start)
            XCTAssertFalse(replace(history, at: start + 3999))
            XCTAssertEqual(replace(history, at: start + 4000), attempt < 2)
            XCTAssertTrue(replace(history, at: start + 12_000))
            // Keep the synthetic clock monotonic between replacements.
            if attempt < 2 { history.replacing(at: start + 4000) }
        }
        XCTAssertEqual(history.fastReopens, 2)
    }
    func testWaitingForNetworkDoesNotChurnSocketsOrConsumeReadyTimeout() {
        var history = SrtlaSocketRecovery()
        history.opened(at: 0)
        XCTAssertFalse(history.shouldReplace(at: 50_000, registered: false, socketReady: false, serverRetryAfter: 0))
        history.ready(at: 50_000)
        XCTAssertFalse(replace(history, at: 53_999))
        XCTAssertTrue(replace(history, at: 54_000))
        history.ready(at: 60_000) // A recovered network gets a fresh response window.
        XCTAssertFalse(replace(history, at: 63_999))
        XCTAssertTrue(replace(history, at: 64_000))
    }
    func testAnyReplyOrPreviousRegistrationUsesSlowPolicy() {
        for registered in [false, true] {
            var history = SrtlaSocketRecovery()
            history.opened(at: 0); history.ready(at: 0)
            history.received(at: 100, registered: registered)
            XCTAssertFalse(replace(history, at: 4000))
            XCTAssertTrue(replace(history, at: 12_000))
            XCTAssertFalse(history.shouldReplace(at: 12_000, registered: true, socketReady: true, serverRetryAfter: 0))
            if registered {
                history.replacing(at: 12_000); history.opened(at: 12_000); history.ready(at: 12_000)
                XCTAssertFalse(replace(history, at: 16_000))
                XCTAssertTrue(replace(history, at: 24_000))
            }
        }
    }
    func testExplicitRejectionDelaySurvivesTerminalSocketFailure() {
        var history = SrtlaSocketRecovery()
        history.opened(at: 0); history.ready(at: 0); history.failed(at: 100)
        XCTAssertFalse(history.shouldReplace(at: 60_099, registered: false, socketReady: false, serverRetryAfter: 60_100))
        XCTAssertTrue(history.shouldReplace(at: 60_100, registered: false, socketReady: false, serverRetryAfter: 60_100))
    }
    func testTerminalFailuresBackOffAndRegistrationResetsFailureCount() {
        var history = SrtlaSocketRecovery()
        history.opened(at: 0); history.failed(at: 10)
        XCTAssertFalse(replace(history, at: 2009)); XCTAssertTrue(replace(history, at: 2010))
        history.replacing(at: 2010); history.opened(at: 2010); history.failed(at: 2020)
        XCTAssertFalse(replace(history, at: 6019)); XCTAssertTrue(replace(history, at: 6020))
        history.replacing(at: 6020); history.opened(at: 6020); history.ready(at: 6030)
        history.received(at: 6040, registered: true); history.failed(at: 6050)
        XCTAssertFalse(replace(history, at: 8049)); XCTAssertTrue(replace(history, at: 8050))
        XCTAssertFalse(replace(history, at: 6049))
    }
    private func replace(_ history: SrtlaSocketRecovery, at time: Int64) -> Bool {
        history.shouldReplace(at: time, registered: false, socketReady: true, serverRetryAfter: 0)
    }
}
