import XCTest
@testable import NabcamCore

final class DatagramRateMeterTests: XCTestCase {
    func testShortBurstIsNotHiddenByOneSecondAverage() {
        var meter = DatagramRateMeter()
        for _ in 0..<40 { meter.record(bytes: 1500, retransmission: false, at: 1000) }
        let sample = meter.snapshot(at: 1000)
        XCTAssertEqual(sample.windows.map(\.kbps), [9600, 4800, 1920, 480])
        XCTAssertEqual(sample.totalBytes, 60_000)
        XCTAssertEqual(sample.totalPackets, 40)
    }
    func testWindowEdgesAndRetransmissions() {
        var meter = DatagramRateMeter()
        for time in [Int64(0), 750, 900, 950, 951, 1000] {
            meter.record(bytes: 100, retransmission: time >= 951, at: time)
        }
        let sample = meter.snapshot(at: 1000)
        XCTAssertEqual(sample.windows.map(\.bytes), [200, 300, 400, 500])
        XCTAssertEqual(sample.windows.map(\.retransmittedPackets), [2, 2, 2, 2])
        XCTAssertEqual(sample.totalBytes, 600)
        XCTAssertEqual(sample.totalRetransmittedBytes, 200)
    }
    func testIdleExpiresRatesWithoutLosingTotalsAndRingWrapIsBounded() {
        var meter = DatagramRateMeter()
        for time in Int64(0)..<10_000 { meter.record(bytes: 100, retransmission: true, at: time) }
        XCTAssertEqual(meter.snapshot(at: 9999).windows.map(\.packets), [50, 100, 250, 1000])
        let idle = meter.snapshot(at: 11_000)
        XCTAssertEqual(idle.windows.map(\.bytes), [0, 0, 0, 0])
        XCTAssertEqual(idle.totalBytes, 1_000_000)
        XCTAssertEqual(idle.totalRetransmittedPackets, 10_000)
    }
    func testInvalidSamplesDoNotInflateTotals() {
        var meter = DatagramRateMeter()
        XCTAssertFalse(meter.record(bytes: 1, retransmission: false, at: -1))
        XCTAssertTrue(meter.record(bytes: 1500, retransmission: false, at: 100))
        XCTAssertFalse(meter.record(bytes: 1500, retransmission: false, at: 99))
        for bytes in [-1, 0, 1501, Int.max] {
            XCTAssertFalse(meter.record(bytes: bytes, retransmission: true, at: 101))
        }
        XCTAssertEqual(meter.snapshot(at: 100).totalBytes, 1500)
        XCTAssertEqual(meter.snapshot(at: 100).totalRetransmittedPackets, 0)
        XCTAssertEqual(meter.snapshot(at: -1).windows.map(\.bytes), [0, 0, 0, 0])
    }
}
