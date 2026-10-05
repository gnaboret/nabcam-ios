import Foundation
import XCTest
@testable import NabcamCore

final class SrtlaPacketPacerTests: XCTestCase {
    func testFailedWritesKeepFIFOAndDoNotSpendCredit() throws {
        var pacer = SrtlaPacketPacer()
        pacer.offer(packet(1), at: 0); pacer.offer(packet(2), at: 0)
        let first = try XCTUnwrap(pacer.take(at: 0, kbps: 1200))
        XCTAssertNil(pacer.take(at: 0, kbps: 1200), "Only one asynchronous write may own credit")
        XCTAssertEqual(pacer.queuedPackets, 2)
        XCTAssertTrue(pacer.finish(first.id, successful: false, at: 5))
        let retry = try XCTUnwrap(pacer.take(at: 5, kbps: 1200))
        XCTAssertEqual(retry.bytes, first.bytes)
        XCTAssertTrue(pacer.finish(retry.id, successful: true, at: 5))
        XCTAssertNil(pacer.take(at: 5, kbps: 1200))
        let second = try XCTUnwrap(pacer.take(at: 15, kbps: 1200))
        XCTAssertEqual(second.bytes, packet(2))
        XCTAssertTrue(pacer.finish(second.id, successful: true, at: 15))
        XCTAssertEqual(pacer.queuedBytes, 0)
    }

    func testIdleBurstIsCappedAndRateIncreaseDoesNotMintCredit() throws {
        var pacer = SrtlaPacketPacer()
        XCTAssertNil(pacer.take(at: 0, kbps: 1200))
        for sequence in UInt32(0)..<8 { pacer.offer(packet(sequence), at: 10_000) }
        for _ in 0..<2 { try send(&pacer, at: 10_000, kbps: 1200) }
        XCTAssertNil(pacer.take(at: 10_000, kbps: 1200))
        pacer.rebase(at: 10_000)
        XCTAssertNil(pacer.take(at: 10_000, kbps: 9000))
        XCTAssertGreaterThan(pacer.delayMilliseconds(at: 10_000, kbps: 9000), 0)
    }

    func testLargeFrameIsSmoothedAndPayloadsAreUnchanged() throws {
        var pacer = SrtlaPacketPacer()
        let packets = (UInt32(0)..<146).map { packet($0) }
        for bytes in packets { XCTAssertTrue(pacer.offer(bytes, at: 0)) }
        let rate = SrtlaPacketPacer.rate(videoKbps: 2000, audioKbps: 96, headroomPercent: 125)
        XCTAssertEqual(rate, 2620)
        var times: [Int] = []
        var output: [Data] = []
        for time in 0...750 {
            for _ in 0..<2 {
                if let submission = pacer.take(at: Int64(time), kbps: rate) {
                    times.append(time); output.append(submission.bytes)
                    XCTAssertTrue(pacer.finish(submission.id, successful: true, at: Int64(time)))
                }
            }
        }
        XCTAssertEqual(output, packets)
        XCTAssertEqual(pacer.overflowPackets, 0)
        XCTAssertTrue((550...700).contains(try XCTUnwrap(times.last)))
        let peak20 = times.map { end in times.filter { $0 > end - 20 && $0 <= end }.count }.max() ?? 0
        XCTAssertLessThan(peak20 * 1332 * 8 / 20, 4000)
    }

    func testBoundedQueueReservesRepairSpaceAndDoesNotExpireOldMedia() {
        var pacer = SrtlaPacketPacer()
        for sequence in UInt32(0)..<300 { pacer.offer(packet(sequence, size: 200), at: 0) }
        XCTAssertEqual(pacer.queuedPackets, 240)
        XCTAssertEqual(pacer.overflowPackets, 60)
        for sequence in UInt32(0)..<16 { XCTAssertTrue(pacer.offer(packet(sequence, retry: true, size: 200), at: 0)) }
        XCTAssertEqual(pacer.queuedPackets, 256)
        XCTAssertFalse(pacer.offer(packet(99, retry: true, size: 200), at: 0))
        XCTAssertEqual(pacer.acknowledgeBefore(300), 0, "Nothing was sent, so this cannot be a trusted ACK")
        XCTAssertNotNil(pacer.take(at: 10_000, kbps: 2000))
        XCTAssertEqual(pacer.queuedPackets, 256)
        XCTAssertEqual(pacer.oldestAge(at: 10_000), 10_000)
        XCTAssertLessThanOrEqual(pacer.queuedBytes, SrtlaPacketPacer.maximumBytes)
    }

    func testDuplicateRepairsPreserveAgeAndDelayedRepairsDoNotStarveNewMedia() throws {
        var pacer = SrtlaPacketPacer()
        for sequence in UInt32(100)..<106 { pacer.offer(packet(sequence, size: 200), at: 0) }
        for sequence in UInt32(0)..<3 { pacer.offer(packet(sequence, retry: true, size: 200), at: 0) }
        for _ in 0..<100 { XCTAssertTrue(pacer.offer(packet(0, retry: true, size: 200), at: 100)) }
        XCTAssertEqual(pacer.duplicateRetries, 100)
        XCTAssertEqual(pacer.oldestAge(at: 200), 200)
        var repairFlags: [Bool] = []
        for index in 0..<6 {
            let bytes = try send(&pacer, at: Int64(200 + index * 10), kbps: 2000)
            repairFlags.append(bytes[4] & 4 != 0)
        }
        XCTAssertEqual(repairFlags, [false, true, false, true, false, true])
    }

    func testACKBeforeCompletionAndFailureDoNotCorruptByteAccounting() throws {
        for success in [true, false] {
            var pacer = SrtlaPacketPacer()
            pacer.offer(packet(20, size: 200), at: 0)
            let pending = try XCTUnwrap(pacer.take(at: 0, kbps: 2000))
            pacer.offer(packet(20, retry: true, size: 200), at: 1)
            pacer.offer(packet(21, size: 200), at: 1)
            XCTAssertEqual(pacer.acknowledgeBefore(21), 1)
            XCTAssertEqual(pacer.queuedBytes, 400, "An issued write remains accounted until completion")
            XCTAssertTrue(pacer.finish(pending.id, successful: success, at: 2))
            XCTAssertFalse(pacer.finish(pending.id, successful: success, at: 2))
            XCTAssertEqual(pacer.queuedBytes, 200)
            XCTAssertEqual(try send(&pacer, at: 10, kbps: 2000), packet(21, size: 200))
            XCTAssertEqual(pacer.queuedPackets, 0)
        }
    }

    func testACKWrapFutureACKAndStaleCompletionAfterReset() throws {
        var pacer = SrtlaPacketPacer()
        pacer.offer(packet(0x7fffffff, size: 200), at: 0)
        try send(&pacer, at: 0, kbps: 2000)
        pacer.offer(packet(0x7fffffff, retry: true, size: 200), at: 1)
        pacer.offer(packet(0, size: 200), at: 1)
        XCTAssertEqual(pacer.acknowledgeBefore(10), 0)
        XCTAssertEqual(pacer.acknowledgeBefore(0), 1)
        let old = try XCTUnwrap(pacer.take(at: 10, kbps: 2000))
        pacer.reset()
        pacer.offer(packet(0, size: 200), at: 11)
        let new = try XCTUnwrap(pacer.take(at: 11, kbps: 2000))
        XCTAssertNotEqual(old.id, new.id)
        XCTAssertFalse(pacer.finish(old.id, successful: true, at: 12))
        XCTAssertEqual(pacer.queuedPackets, 1)
        XCTAssertTrue(pacer.finish(new.id, successful: true, at: 12))
    }

    func testMalformedInputsBackwardTimeAndExtremeRatesAreBounded() {
        var pacer = SrtlaPacketPacer()
        XCTAssertFalse(pacer.offer(Data(), at: 0))
        XCTAssertFalse(pacer.offer(packet(0, size: 1501), at: 0))
        XCTAssertFalse(pacer.offer(Data(repeating: 0x80, count: 16), at: 0))
        XCTAssertFalse(pacer.offer(packet(0), at: -1))
        XCTAssertTrue(pacer.offer(packet(0), at: 20))
        XCTAssertNil(pacer.take(at: 19, kbps: 1200))
        XCTAssertEqual(pacer.queuedPackets, 1)
        XCTAssertEqual(SrtlaPacketPacer.rate(videoKbps: Int.max, audioKbps: Int.max, headroomPercent: Int.max), 100_000)
        XCTAssertEqual(SrtlaPacketPacer.rate(videoKbps: Int.min, audioKbps: Int.min, headroomPercent: Int.min), 64)
    }

    @discardableResult
    private func send(_ pacer: inout SrtlaPacketPacer, at time: Int64, kbps: Int) throws -> Data {
        let submission = try XCTUnwrap(pacer.take(at: time, kbps: kbps))
        XCTAssertTrue(pacer.finish(submission.id, successful: true, at: time))
        return submission.bytes
    }
    private func packet(_ sequence: UInt32, retry: Bool = false, size: Int = 1332) -> Data {
        var bytes = Data(repeating: 0, count: size)
        bytes[0] = UInt8((sequence >> 24) & 0x7f)
        bytes[1] = UInt8((sequence >> 16) & 0xff)
        bytes[2] = UInt8((sequence >> 8) & 0xff)
        bytes[3] = UInt8(sequence & 0xff)
        bytes[4] = retry ? 4 : 0
        return bytes
    }
}
