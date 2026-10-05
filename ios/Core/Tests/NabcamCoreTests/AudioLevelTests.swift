import XCTest
@testable import NabcamCore

final class AudioLevelTests: XCTestCase {
    func testSilenceMissingAndReset() {
        var meter = AudioLevelAccumulator()
        XCTAssertNil(meter.take())
        meter.add(0)
        let level = meter.take()
        XCTAssertEqual(level?.rmsDBFS, -90)
        XCTAssertEqual(level?.fraction, 0)
        XCTAssertEqual(level?.clipped, false)
        XCTAssertNil(meter.take())
    }
    func testRMSPeakAndClipping() throws {
        var meter = AudioLevelAccumulator()
        meter.add(0.5); meter.add(-0.5)
        let half = try XCTUnwrap(meter.take())
        XCTAssertEqual(half.rmsDBFS, -6.0206, accuracy: 0.001)
        XCTAssertEqual(half.peakDBFS, half.rmsDBFS)
        XCTAssertFalse(half.clipped)
        meter.add(0); meter.add(-1)
        let clipped = try XCTUnwrap(meter.take())
        XCTAssertEqual(clipped.rmsDBFS, -3.0103, accuracy: 0.001)
        XCTAssertEqual(clipped.peakDBFS, 0)
        XCTAssertTrue(clipped.clipped)
    }
    func testInvalidSamplesDoNotPoisonWindow() {
        var meter = AudioLevelAccumulator()
        meter.add(.nan); meter.add(.infinity)
        XCTAssertNil(meter.take())
        meter.add(Double.greatestFiniteMagnitude)
        XCTAssertEqual(meter.take()?.peakDBFS, 0)
    }
}
