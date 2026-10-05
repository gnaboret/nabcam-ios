import Foundation
import XCTest
@testable import NabcamCore

final class SrtlaFlightTrackerTests: XCTestCase {
    func testReceiptAndDuplicateACK() {
        var tracker = SrtlaFlightTracker()
        XCTAssertTrue(tracker.record(sequence: 9, bytes: 1300, at: 100))
        XCTAssertEqual(tracker.bytes, 1300)
        XCTAssertEqual(tracker.oldestAge(at: 130), 30)
        let receipt = tracker.acknowledge(sequence: 9, at: 140)
        XCTAssertEqual(receipt?.roundTripMilliseconds, 40)
        XCTAssertEqual(receipt?.bytes, 1300)
        XCTAssertNil(tracker.acknowledge(sequence: 9, at: 150))
        XCTAssertEqual(tracker.count, 0)
        XCTAssertNil(tracker.oldestAge(at: 150))
    }

    func testRetransmissionDoesNotInventRTTOrRefreshOldestAge() {
        var tracker = SrtlaFlightTracker()
        tracker.record(sequence: 2, bytes: 1200, at: 10)
        tracker.record(sequence: 2, bytes: 1200, at: 60)
        XCTAssertEqual(tracker.count, 1)
        XCTAssertEqual(tracker.oldestAge(at: 70), 60)
        let receipt = tracker.acknowledge(sequence: 2, at: 80)
        XCTAssertNotNil(receipt)
        XCTAssertNil(receipt?.roundTripMilliseconds)
    }

    func testBoundedCapacityAndExpiryBoundary() {
        var tracker = SrtlaFlightTracker()
        for sequence in UInt32(0)...256 { tracker.record(sequence: sequence, bytes: 1500, at: Int64(sequence)) }
        XCTAssertEqual(tracker.count, 256)
        XCTAssertEqual(tracker.bytes, 256 * 1500)
        XCTAssertEqual(tracker.capacityEvictions, 1)
        XCTAssertNil(tracker.acknowledge(sequence: 0, at: 256))
        XCTAssertEqual(tracker.expire(at: 1501), 0)
        XCTAssertEqual(tracker.expire(at: 1502), 1)
        XCTAssertEqual(tracker.expire(at: 1757), 255)
    }

    func testCumulativeACKWrapAndEquality() {
        var tracker = SrtlaFlightTracker()
        for sequence in [UInt32(0x7ffffffe), 0x7fffffff, 0, 1] {
            tracker.record(sequence: sequence, bytes: 100, at: 0)
        }
        XCTAssertEqual(tracker.acknowledgeBefore(1, at: 20), 3)
        XCTAssertEqual(tracker.count, 1)
        XCTAssertEqual(tracker.acknowledge(sequence: 1, at: 30)?.roundTripMilliseconds, 30)
    }

    func testNAKDoesNotRetryAndMalformedNAKDoesNotReleaseAnything() {
        var tracker = SrtlaFlightTracker()
        for sequence in [UInt32(1), 2, 3] { tracker.record(sequence: sequence, bytes: 100, at: 0) }
        var nak = Data([0x80, 3] + Array(repeating: UInt8(0), count: 14))
        nak.append(contentsOf: [0, 0, 0, 2])
        XCTAssertEqual(tracker.negativeAcknowledgement(nak + Data([0x80, 0, 0, 3]), at: 10), 0)
        XCTAssertEqual(tracker.negativeAcknowledgement(nak, at: 20), 1)
        XCTAssertEqual(tracker.count, 2)
    }

    func testInvalidInputAndBackwardClockPreserveOutstandingPackets() {
        var tracker = SrtlaFlightTracker()
        XCTAssertFalse(tracker.record(sequence: 0x80000000, bytes: 100, at: 0))
        XCTAssertFalse(tracker.record(sequence: 1, bytes: 1501, at: 0))
        XCTAssertFalse(tracker.record(sequence: 1, bytes: 0, at: 0))
        XCTAssertFalse(tracker.record(sequence: 1, bytes: 100, at: -1))
        tracker.record(sequence: 1, bytes: 100, at: 100)
        XCTAssertNil(tracker.acknowledge(sequence: 1, at: 99))
        XCTAssertEqual(tracker.expire(at: 99), 0)
        XCTAssertNil(tracker.oldestAge(at: 99))
        XCTAssertEqual(tracker.count, 1)
        XCTAssertEqual(tracker.expire(at: Int64.max), 1)
    }
}
