import XCTest
@testable import NabcamCore

final class UploadByteCounterTests: XCTestCase {
    func testRepeatedSnapshotsAreNotAddedAndOlderReportsDoNotLowerUsage() {
        var counter = UploadByteCounter()
        counter.observe(total: 1_000)
        counter.observe(total: 1_000)
        counter.observe(total: 500)
        XCTAssertEqual(counter.bytes, 1_000)
        counter.observe(total: 2_500)
        XCTAssertEqual(counter.bytes, 2_500)
        XCTAssertEqual(UploadByteCounter().bytes, 0)
    }

    func testDatagramTotalsIgnoreInvalidCountsAndSaturate() {
        var counter = UploadByteCounter()
        counter.add(1_316); counter.add(1_316)
        counter.add(0); counter.add(-1)
        XCTAssertEqual(counter.bytes, 2_632)
        counter.observe(total: .max - 1)
        counter.add(10)
        XCTAssertEqual(counter.bytes, .max)
    }

    func testDisplayUsesDecimalUploadUnits() {
        XCTAssertEqual(UploadByteCounter.label(bytes: 0), "UP 0.0 MB")
        XCTAssertEqual(UploadByteCounter.label(bytes: 8_600_000), "UP 8.6 MB")
        XCTAssertEqual(UploadByteCounter.label(bytes: 1_200_000_000), "UP 1.2 GB")
    }
}
