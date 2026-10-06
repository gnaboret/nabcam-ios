import XCTest
@testable import NabcamCore

final class MicrophoneGainLimiterTests: XCTestCase {
    func testNeutralAndStereoBalance() {
        var limiter = MicrophoneGainLimiter()
        var samples: [Float] = [0.1, -0.2, 0, 0.3]
        let original = samples
        let result = limiter.process(&samples, gainDB: 0)
        XCTAssertEqual(samples, original)
        XCTAssertEqual(result.appliedGain, 1)
        XCTAssertFalse(result.limited)
    }

    func testBoostAndImmediatePeakLimitUseUniformGain() {
        var limiter = MicrophoneGainLimiter()
        var samples: [Float] = [0.1, -0.05]
        let boosted = limiter.process(&samples, gainDB: 6)
        XCTAssertEqual(samples[0], 0.199526, accuracy: 0.00001)
        XCTAssertFalse(boosted.limited)
        samples = [0.9, -0.45]
        let limited = limiter.process(&samples, gainDB: 24)
        XCTAssertTrue(limited.limited)
        XCTAssertEqual(samples[0], Float(pow(10.0, -1.0 / 20)), accuracy: 0.00001)
        XCTAssertEqual(samples[1], -samples[0] / 2, accuracy: 0.00001)
    }

    func testRecoveryAndReset() {
        var limiter = MicrophoneGainLimiter()
        var samples: [Float] = [1]
        let reduced = limiter.process(&samples, gainDB: 12)
        samples = [0.01]
        let recovering = limiter.process(&samples, gainDB: 12)
        XCTAssertGreaterThan(recovering.appliedGain, reduced.appliedGain)
        XCTAssertLessThan(recovering.appliedGain, recovering.requestedGain)
        limiter.reset()
        samples = [0.01]
        let reset = limiter.process(&samples, gainDB: 12)
        XCTAssertEqual(reset.appliedGain, reset.requestedGain)
    }

    func testInvalidValuesAndDisabledLimiterStayFinite() {
        var limiter = MicrophoneGainLimiter()
        var samples: [Float] = [.nan, .infinity, -.infinity, 0.5, -0.5]
        _ = limiter.process(&samples, gainDB: .nan, ceilingDB: .infinity)
        XCTAssertEqual(samples, [0, 0, 0, 0.5, -0.5])
        limiter.reset()
        samples = [0.9, -0.9]
        _ = limiter.process(&samples, gainDB: 24, limiterEnabled: false)
        XCTAssertEqual(samples, [1, -1])
        samples = []
        XCTAssertFalse(limiter.process(&samples, gainDB: 0).limited)
    }
}
