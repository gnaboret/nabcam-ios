import Foundation
import XCTest
@testable import NabcamCore

final class SrtlaWireTests: XCTestCase {
    func testRegistrationNetworkByteOrderAndGroupSize() {
        let group = Data((0..<256).map { UInt8($0) })
        let packet = SrtlaWire.control(SrtlaWire.reg1, payload: group)
        XCTAssertEqual(packet.prefix(2), Data([0x92, 0x00]))
        XCTAssertEqual(packet.count, SrtlaWire.groupIDSize + 2)
        XCTAssertEqual(packet.dropFirst(2), group)
        XCTAssertEqual(SrtlaWire.type(packet), SrtlaWire.reg1)
        XCTAssertNil(SrtlaWire.type(Data([0x92])))
    }

    func testDataSequenceAndNonZeroSliceIndex() {
        var packet = Data([0x7f, 0xff, 0xff, 0xfe])
        packet.append(Data(repeating: 0, count: 12))
        XCTAssertEqual(SrtlaWire.sequence(packet), 0x7ffffffe)
        let prefixed = Data([1, 2, 3]) + packet
        XCTAssertEqual(SrtlaWire.sequence(prefixed.dropFirst(3)), 0x7ffffffe)
        packet[0] = 0x80
        XCTAssertNil(SrtlaWire.sequence(packet))
        XCTAssertNil(SrtlaWire.sequence(Data(repeating: 0, count: 15)))
    }

    func testACKPaddingAndMalformedLengths() {
        let packet = Data([0x91, 0, 0, 0, 0, 0, 0, 1, 0x7f, 0xff, 0xff, 0xff])
        XCTAssertEqual(SrtlaWire.acknowledgements(packet), [1, 0x7fffffff])
        XCTAssertTrue(SrtlaWire.acknowledgements(packet.dropLast()).isEmpty)
        XCTAssertTrue(SrtlaWire.acknowledgements(Data([0x91, 0, 0, 0])).isEmpty)
        XCTAssertTrue(SrtlaWire.acknowledgements(Data([0x90, 0, 0, 0, 0, 0, 0, 1])).isEmpty)
    }

    func testCumulativeACKWrapAndAmbiguousHalfRange() {
        XCTAssertTrue(SrtlaWire.isBefore(0x7fffffff, nextExpected: 0))
        XCTAssertTrue(SrtlaWire.isBefore(0x7ffffffe, nextExpected: 1))
        XCTAssertFalse(SrtlaWire.isBefore(1, nextExpected: 1))
        XCTAssertFalse(SrtlaWire.isBefore(2, nextExpected: 1))
        XCTAssertFalse(SrtlaWire.isBefore(0, nextExpected: 0x40000000))
        XCTAssertFalse(SrtlaWire.isBefore(0x80000000, nextExpected: 1))
    }

    func testNAKSinglesRangesWrapAndMalformedTail() {
        let packet = nak([12, 0xfffffffe, 1, 0x80000014, 24])
        for sequence in [UInt32(12), 0x7ffffffe, 0x7fffffff, 0, 1, 20, 24] {
            XCTAssertTrue(SrtlaWire.isLost(sequence, in: packet))
        }
        for sequence in [UInt32(2), 11, 19, 25] {
            XCTAssertFalse(SrtlaWire.isLost(sequence, in: packet))
        }
        XCTAssertFalse(SrtlaWire.isLost(12, in: nak([12, 0x80000014])))
        XCTAssertFalse(SrtlaWire.isLost(0, in: nak([0x80000000, 0x40000000])))
        XCTAssertFalse(SrtlaWire.isLost(12, in: packet.dropLast()))
        XCTAssertFalse(SrtlaWire.isLost(12, in: Data([0x80, 3]) + Data(repeating: 0, count: 65538)))
    }

    private func nak(_ values: [UInt32]) -> Data {
        var packet = Data([0x80, 3]) + Data(repeating: 0, count: 14)
        for value in values {
            packet.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 255),
                UInt8((value >> 8) & 255), UInt8(value & 255)])
        }
        return packet
    }
}
