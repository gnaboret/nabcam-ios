import XCTest
@testable import NabcamCore

final class FrameRateTests: XCTestCase {
    func testCountsActualCallbacksAndElapsedTime() throws {
        var counter = FrameRateCounter()
        counter.reset(at: 0)
        for i in 0..<60 { counter.record(at: Double(i) / 60) }
        let first = try XCTUnwrap(counter.snapshot(at: 1))
        XCTAssertEqual(first.fps, 60, accuracy: 0.001)
        XCTAssertEqual(first.maximumGapMilliseconds, 1000 / 60, accuracy: 0.001)
        for i in 0..<40 { counter.record(at: 1 + Double(i) / 20) }
        XCTAssertEqual(try XCTUnwrap(counter.snapshot(at: 3)).fps, 20, accuracy: 0.001)
    }
    func testSilenceReportsZeroAndGapGrows() throws {
        var counter = FrameRateCounter()
        counter.reset(at: 0)
        let snapshot = try XCTUnwrap(counter.snapshot(at: 2))
        XCTAssertEqual(snapshot.fps, 0)
        XCTAssertEqual(snapshot.maximumGapMilliseconds, 2000)
        counter.record(at: 2.5)
        XCTAssertEqual(try XCTUnwrap(counter.snapshot(at: 3)).frames, 1)
    }
    func testResetAndInvalidTimestamps() throws {
        var counter = FrameRateCounter()
        XCTAssertNil(counter.snapshot(at: 1))
        counter.reset(at: 10)
        counter.record(at: .nan)
        counter.record(at: .infinity)
        XCTAssertEqual(try XCTUnwrap(counter.snapshot(at: 11)).frames, 0)
        XCTAssertNil(counter.snapshot(at: 9))
        counter.record(at: 9.5)
        XCTAssertEqual(try XCTUnwrap(counter.snapshot(at: 10)).fps, 1)
    }
}
