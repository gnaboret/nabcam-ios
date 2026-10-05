import Foundation
import NabcamCore
import XCTest
@testable import NabcamStorageHost

@MainActor
final class SrtLocalRelaySocketTests: XCTestCase {
    func testPinsOneCallerPreservesPacketsAndReturnsOnlyMatchingReplies() async throws {
        let handshakeReceived = expectation(description: "Handshake delivered unchanged")
        let mediaReceived = expectation(description: "Media delivered unchanged")
        let replyReceived = expectation(description: "SRT reply returned unchanged")
        let callerReady = expectation(description: "Caller ready")
        let otherReady = expectation(description: "Second caller ready")
        let handshake = handshake(id: 42)
        let media = Data([0, 0, 0, 1] + Array(repeating: UInt8(7), count: 28))
        let response = reply(id: 42)
        let packets = PacketRecorder()
        let relay = try SrtLocalRelaySocket { bytes in
            packets.append(bytes)
            if bytes == handshake { handshakeReceived.fulfill() }
            if bytes == media { mediaReceived.fulfill() }
        }
        defer { relay.close() }
        relay.start(); relay.start()
        for _ in 0..<100 {
            if relay.snapshot().port != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let port = try XCTUnwrap(relay.snapshot().port)
        XCTAssertFalse(relay.send(response), "No caller is pinned yet")
        let caller = try SrtlaDatagramPath(host: "127.0.0.1", port: port) { event in
            switch event {
            case .ready: callerReady.fulfill()
            case .datagram(let data): if data == response { replyReceived.fulfill() }
            default: break
            }
        }
        defer { caller.close() }
        caller.start()
        await fulfillment(of: [callerReady], timeout: 5)
        XCTAssertTrue(caller.send(handshake))
        await fulfillment(of: [handshakeReceived], timeout: 5)
        XCTAssertEqual(relay.snapshot().socketID, 42)
        XCTAssertTrue(caller.send(media))
        await fulfillment(of: [mediaReceived], timeout: 5)
        XCTAssertFalse(relay.send(reply(id: 99)))
        XCTAssertFalse(relay.send(SrtlaWire.control(SrtlaWire.reg3)))
        XCTAssertTrue(relay.send(response))
        await fulfillment(of: [replyReceived], timeout: 5)

        let other = try SrtlaDatagramPath(host: "127.0.0.1", port: port) { event in
            if case .ready = event { otherReady.fulfill() }
        }
        defer { other.close() }
        other.start()
        await fulfillment(of: [otherReady], timeout: 5)
        XCTAssertTrue(other.send(self.handshake(id: 99)))
        // A different source ID on the existing flow must not replace it either.
        XCTAssertTrue(caller.send(self.handshake(id: 99)))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(relay.snapshot().socketID, 42)
        XCTAssertEqual(packets.values, [handshake, media])
        relay.close(); relay.close(); relay.start()
        XCTAssertNil(relay.snapshot().port)
        XCTAssertFalse(relay.send(response))
    }

    func testNonHandshakeCannotClaimLocalReceiver() async throws {
        let received = expectation(description: "Valid handshake claims receiver")
        let firstReady = expectation(description: "Non-SRT caller ready")
        let secondReady = expectation(description: "Valid caller ready")
        let expected = handshake(id: 71)
        let packets = PacketRecorder()
        let relay = try SrtLocalRelaySocket { bytes in
            packets.append(bytes)
            if bytes == expected { received.fulfill() }
        }
        defer { relay.close() }
        relay.start()
        for _ in 0..<100 {
            if relay.snapshot().port != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let port = try XCTUnwrap(relay.snapshot().port)
        let first = try SrtlaDatagramPath(host: "127.0.0.1", port: port) { event in
            if case .ready = event { firstReady.fulfill() }
        }
        let second = try SrtlaDatagramPath(host: "127.0.0.1", port: port) { event in
            if case .ready = event { secondReady.fulfill() }
        }
        defer { first.close(); second.close() }
        first.start(); second.start()
        await fulfillment(of: [firstReady, secondReady], timeout: 5)
        XCTAssertTrue(first.send(Data(repeating: 0, count: 32)))
        XCTAssertTrue(second.send(expected))
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(relay.snapshot().socketID, 71)
        XCTAssertEqual(packets.values, [expected])
    }

    private func handshake(id: UInt8) -> Data {
        var data = Data(repeating: 0, count: 64)
        data[0] = 0x80; data[19] = 5; data[39] = 1; data[43] = id
        return data
    }
    private func reply(id: UInt8) -> Data {
        var data = Data(repeating: 0, count: 20)
        data[0] = 0x80; data[1] = 2; data[15] = id; data[19] = 2
        return data
    }
}

private final class PacketRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; if packets.count < 16 { packets.append(bytes) } }
    var values: [Data] { lock.lock(); defer { lock.unlock() }; return packets }
}
