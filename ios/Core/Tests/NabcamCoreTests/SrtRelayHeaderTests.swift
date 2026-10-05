import Foundation
import XCTest
@testable import NabcamCore

final class SrtRelayHeaderTests: XCTestCase {
    func testHandshakeSourceRequiresCompleteCIFAndKnownVersion() {
        var handshake = Data(repeating: 0, count: 64)
        handshake[0] = 0x80; handshake[19] = 5; handshake[43] = 42
        XCTAssertEqual(SrtRelayHeader.handshakeSourceID(handshake), 42)
        XCTAssertNil(SrtRelayHeader.handshakeSourceID(handshake.prefix(48)))
        let prefixed = Data([1, 2]) + handshake
        XCTAssertEqual(SrtRelayHeader.handshakeSourceID(prefixed.dropFirst(2)), 42)
        handshake[19] = 4
        XCTAssertEqual(SrtRelayHeader.handshakeSourceID(handshake), 42)
        handshake[19] = 99
        XCTAssertNil(SrtRelayHeader.handshakeSourceID(handshake))
        handshake[19] = 5; handshake[43] = 0
        XCTAssertNil(SrtRelayHeader.handshakeSourceID(handshake))
    }

    func testACKMustBelongToThisSRTSocket() {
        var ack = Data(repeating: 0, count: 20)
        ack[0] = 0x80; ack[1] = 2; ack[15] = 42; ack[19] = 9
        XCTAssertEqual(SrtRelayHeader.cumulativeACK(ack, for: 42), 9)
        XCTAssertNil(SrtRelayHeader.cumulativeACK(ack, for: 41))
        XCTAssertNil(SrtRelayHeader.cumulativeACK(ack.dropLast(), for: 42))
        ack[3] = 1
        XCTAssertNil(SrtRelayHeader.cumulativeACK(ack, for: 42))
    }

    func testSRTLAControlsAreNotForwardedButSRTExtensionsAre() {
        for type in [UInt16(0x9000), 0x9100, 0x9200, 0x9201, 0x9212] {
            let bytes = SrtlaWire.control(type, payload: Data(repeating: 0, count: 62))
            XCTAssertFalse(SrtRelayHeader.isTransportPacket(bytes))
        }
        XCTAssertTrue(SrtRelayHeader.isTransportPacket(Data(repeating: 0, count: 16)))
        XCTAssertTrue(SrtRelayHeader.isTransportPacket(SrtlaWire.control(0xffff, payload: Data(repeating: 0, count: 14))))
        XCTAssertFalse(SrtRelayHeader.isTransportPacket(Data(repeating: 0, count: 1501)))
        XCTAssertFalse(SrtRelayHeader.isTransportPacket(Data(repeating: 0, count: 15)))
    }
}
