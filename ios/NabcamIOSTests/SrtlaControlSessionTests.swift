import Foundation
import Network
import NabcamCore
import XCTest
@testable import NabcamStorageHost

@MainActor
final class SrtlaControlSessionTests: XCTestCase {
    func testTwoSocketsJoinOneGroupAndKeepItAlive() async throws {
        let listening = expectation(description: "Control receiver ready")
        let receiver = try ControlReceiver { listening.fulfill() }
        defer { receiver.close() }
        receiver.start()
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(receiver.port)
        let endpoint = try SrtlaEndpoint("srtla://127.0.0.1:\(port)")
        // Two loopback sockets verify session coordination, NOT dual-radio bonding.
        let session = try SrtlaControlSession(endpoint: endpoint, interfaces: [.automatic, .automatic])
        defer { session.close() }
        session.start(); session.start()
        for _ in 0..<100 {
            if session.snapshot().filter({ $0.state == .registered }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(session.snapshot().filter { $0.state == .registered }.count, 2)
        XCTAssertEqual(receiver.stats.connections, 2)
        XCTAssertEqual(receiver.stats.groupRequests, 1)
        XCTAssertEqual(receiver.stats.joins, 2)
        XCTAssertEqual(receiver.stats.invalidJoins, 0)
        for _ in 0..<60 {
            if receiver.stats.keepalives >= 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(receiver.stats.keepalives, 2)
        XCTAssertEqual(session.snapshot().filter { $0.state == .registered }.count, 2)
        session.close(); session.close(); session.start()
        XCTAssertTrue(session.snapshot().isEmpty)
    }

    func testRejectedRegistrationIsNotReportedAsReadyForMedia() async throws {
        let listening = expectation(description: "Rejecting receiver ready")
        let receiver = try ControlReceiver(reject: true) { listening.fulfill() }
        defer { receiver.close() }
        receiver.start()
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(receiver.port)
        let session = try SrtlaControlSession(endpoint: SrtlaEndpoint("127.0.0.1:\(port)"), interfaces: [.automatic])
        defer { session.close() }
        session.start()
        for _ in 0..<100 {
            if session.snapshot().first?.state == .cooldown { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(session.snapshot().first?.state, .cooldown)
        XCTAssertGreaterThanOrEqual(receiver.stats.groupRequests, 1)
        // A busy runner may send a scheduled retry BEFORE the server's rejection
        // reaches the client. Count from processed rejection, not first request.
        let admittedAfterRejection = session.snapshot().first?.controlPacketsAdmitted
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(session.snapshot().contains { $0.state == .registered })
        XCTAssertEqual(session.snapshot().first?.state, .cooldown)
        XCTAssertEqual(session.snapshot().first?.controlPacketsAdmitted, admittedAfterRejection,
                       "Server rejection cooldown must not be bypassed")
    }

    func testCloseBeforeStartAndInvalidPathCounts() throws {
        let endpoint = try SrtlaEndpoint("127.0.0.1:9000")
        XCTAssertThrowsError(try SrtlaControlSession(endpoint: endpoint, interfaces: []))
        XCTAssertThrowsError(try SrtlaControlSession(endpoint: endpoint, interfaces: [.automatic, .automatic, .automatic]))
        let session = try SrtlaControlSession(endpoint: endpoint)
        session.close(); session.start()
        XCTAssertTrue(session.snapshot().isEmpty)
    }

    func testSilentInitialSocketIsReplacedAndNewSocketRegisters() async throws {
        let listening = expectation(description: "Receiver ignores first UDP flow")
        let receiver = try ControlReceiver(silentConnections: 1) { listening.fulfill() }
        defer { receiver.close() }
        receiver.start()
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(receiver.port)
        let session = try SrtlaControlSession(endpoint: SrtlaEndpoint("127.0.0.1:\(port)"), interfaces: [.automatic])
        defer { session.close() }
        session.start()
        for _ in 0..<300 {
            if session.snapshot().first?.state == .registered { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(session.snapshot().first?.state, .registered)
        XCTAssertEqual(session.relaySnapshot().socketReplacements, 1)
        XCTAssertEqual(receiver.stats.connections, 2)
        XCTAssertEqual(session.snapshot().first?.id, 2, "Old socket IDs must not be reused")
    }

    func testPublishingWaitCanTimeoutAndCancelWithoutReportingAConnection() async throws {
        let listening = expectation(description: "Receiver refuses media registration")
        let receiver = try ControlReceiver(reject: true) { listening.fulfill() }
        defer { receiver.close() }
        receiver.start()
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(receiver.port)
        let session = try SrtlaControlSession(endpoint: SrtlaEndpoint("127.0.0.1:\(port)"),
                                              interfaces: [.automatic], pacingKbps: 1200)
        defer { session.close() }
        session.start()
        do {
            _ = try await session.waitUntilReady(timeoutMilliseconds: 100)
            XCTFail("A local listening port alone must not indicate a registered receiver")
        } catch SrtlaControlSession.ConnectionWaitError.timedOut {} catch { XCTFail("Unexpected wait error") }
        let wait = Task { try await session.waitUntilReady() }
        wait.cancel()
        do { _ = try await wait.value; XCTFail("A cancelled publish must not continue registration") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation") }
        session.close()
        do { _ = try await session.waitUntilReady(); XCTFail("Closed session must not wait") }
        catch SrtlaControlSession.ConnectionWaitError.closed {} catch { XCTFail("Expected closed state") }
    }

    func testPublishingWaitStartsWithOneRegisteredPath() async throws {
        let listening = expectation(description: "Only the second UDP flow responds")
        let receiver = try ControlReceiver(responsiveConnection: 1) { listening.fulfill() }
        defer { receiver.close() }
        receiver.start()
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(receiver.port)
        let session = try SrtlaControlSession(endpoint: SrtlaEndpoint("127.0.0.1:\(port)?streamid=ready-test"),
                                              interfaces: [.automatic, .automatic], pacingKbps: 1200)
        defer { session.close() }
        session.start()
        let local = try await session.waitUntilReady(timeoutMilliseconds: 10_000)
        XCTAssertEqual(local.host, "127.0.0.1")
        XCTAssertEqual(local.query, "streamid=ready-test")
        XCTAssertEqual(session.snapshot().filter { $0.state == .registered }.count, 1)
    }

    func testPacedRelayForwardsUnchangedMediaAndOnlyMatchingSRTReplies() async throws {
        let listening = expectation(description: "Mock SRTLA receiver ready")
        let callerReady = expectation(description: "Local SRT caller ready")
        let handshakeReply = expectation(description: "Receiver handshake returned")
        let finalACK = expectation(description: "Final cumulative ACK returned")
        let wrongReply = expectation(description: "Wrong destination must never return")
        wrongReply.isInverted = true
        let receiver = try ControlReceiver { listening.fulfill() }
        defer { receiver.close() }
        receiver.start()
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(receiver.port)
        let endpoint = try SrtlaEndpoint("127.0.0.1:\(port)?latency=2500&streamid=local-test")
        let session = try SrtlaControlSession(endpoint: endpoint,
                                              interfaces: [.automatic, .automatic], pacingKbps: 1200)
        defer { session.close() }
        session.start()
        for _ in 0..<200 {
            if session.localSRTURL() != nil && session.snapshot().filter({ $0.state == .registered }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(session.snapshot().filter { $0.state == .registered }.count, 2)
        let local = try XCTUnwrap(session.localSRTURL())
        XCTAssertEqual(local.query, "latency=2500&streamid=local-test")
        let localPort = try XCTUnwrap(local.port)
        let caller = try SrtlaDatagramPath(host: "127.0.0.1", port: UInt16(localPort)) { event in
            switch event {
            case .ready: callerReady.fulfill()
            case .datagram(let data):
                if SrtRelayHeader.destinationID(data) == 99 { wrongReply.fulfill() }
                if SrtlaWire.type(data) == 0x8000 { handshakeReply.fulfill() }
                if SrtRelayHeader.cumulativeACK(data, for: 42) == 21 { finalACK.fulfill() }
            default: break
            }
        }
        defer { caller.close() }
        caller.start()
        await fulfillment(of: [callerReady], timeout: 5)
        var handshake = Data(repeating: 0, count: 64)
        handshake[0] = 0x80; handshake[19] = 5; handshake[39] = 1; handshake[43] = 42
        XCTAssertTrue(caller.send(handshake))
        await fulfillment(of: [handshakeReply], timeout: 10)
        let packets = (1...20).map { sequence -> Data in
            var packet = Data(repeating: UInt8(sequence), count: 1332)
            packet[0] = 0; packet[1] = 0; packet[2] = 0; packet[3] = UInt8(sequence)
            packet[4] = 0 // Original SRT media, not a retransmission.
            return packet
        }
        for packet in packets { XCTAssertTrue(caller.send(packet)) }
        await fulfillment(of: [finalACK], timeout: 10)
        await fulfillment(of: [wrongReply], timeout: 0.2)
        XCTAssertEqual(receiver.stats.handshake, handshake)
        // Independent UDP paths may reorder arrivals; SRT, not the relay, owns
        // reconstruction. Verify exact datagram contents without requiring order.
        let delivered = receiver.stats.media.sorted { (SrtlaWire.sequence($0) ?? 0) < (SrtlaWire.sequence($1) ?? 0) }
        XCTAssertEqual(delivered, packets)
        XCTAssertEqual(receiver.stats.mediaConnections.count, 2)
        XCTAssertTrue(session.snapshot().allSatisfy { $0.acknowledgedPackets > 0 })
        XCTAssertEqual(session.relaySnapshot().queuedPackets, 0)
        XCTAssertEqual(session.relaySnapshot().overflowPackets, 0)
        XCTAssertEqual(session.relaySnapshot().localReplyDrops, 0)
        XCTAssertGreaterThanOrEqual(session.relaySnapshot().rejectedReplies, 1)
    }
}

private final class ControlReceiver: @unchecked Sendable {
    struct Stats {
        var connections = 0; var groupRequests = 0; var joins = 0; var invalidJoins = 0; var keepalives = 0
        var handshake: Data?
        var media: [Data] = []
        var mediaConnections: Set<ObjectIdentifier> = []
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.gnabcamirl.tests.control-receiver")
    private let lock = NSLock()
    private let reject: Bool
    private let silentConnections: Int
    private let responsiveConnection: Int?
    private var sockets: [NWConnection] = []
    private var group: Data?
    private var counters = Stats()
    private var receivedSequences: Set<UInt32> = []
    private var nextExpected: UInt32 = 1
    private var stopped = false
    var port: UInt16? { listener.port?.rawValue }
    var stats: Stats { lock.lock(); defer { lock.unlock() }; return counters }

    init(reject: Bool = false, silentConnections: Int = 0, responsiveConnection: Int? = nil,
         ready: @escaping @Sendable () -> Void) throws {
        self.reject = reject
        self.silentConnections = silentConnections
        self.responsiveConnection = responsiveConnection
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in if case .ready = state { ready() } }
        listener.newConnectionHandler = { [weak self] socket in
            guard let self else { socket.cancel(); return }
            self.lock.lock()
            guard !self.stopped else { self.lock.unlock(); socket.cancel(); return }
            self.sockets.append(socket); self.counters.connections += 1
            self.lock.unlock()
            socket.start(queue: self.queue)
            self.receive(socket)
        }
    }
    func start() { listener.start(queue: queue) }
    func close() {
        lock.lock(); stopped = true; let connections = sockets; sockets.removeAll(); lock.unlock()
        connections.forEach { $0.cancel() }; listener.cancel()
    }
    private func receive(_ socket: NWConnection) {
        socket.receiveMessage { [weak self] data, _, complete, error in
            guard let self, error == nil else { return }
            if complete, let data {
                for response in self.replies(to: data, from: socket) {
                    socket.send(content: response, completion: .contentProcessed { _ in })
                }
            }
            self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
            if !stopped { self.receive(socket) }
        }
    }
    private func replies(to packet: Data, from socket: NWConnection) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return [] }
        if let index = sockets.firstIndex(where: { $0 === socket }) {
            if index < silentConnections { return [] }
            if let responsiveConnection, index != responsiveConnection { return [] }
        }
        switch SrtlaWire.type(packet) {
        case SrtlaWire.reg1 where packet.count == 258:
            counters.groupRequests += 1
            if reject { return [SrtlaWire.control(SrtlaWire.rejected)] }
            // Preserve the client nonce half and replace the receiver-owned half.
            let assigned = Data(packet.dropFirst(2).prefix(128)) + Data(repeating: 0xa9, count: 128)
            group = assigned
            return [SrtlaWire.control(SrtlaWire.reg2, payload: assigned)]
        case SrtlaWire.reg2 where packet.count == 258:
            guard Data(packet.dropFirst(2)) == group else {
                counters.invalidJoins += 1
                return [SrtlaWire.control(SrtlaWire.unknownGroup)]
            }
            counters.joins += 1
            return [SrtlaWire.control(SrtlaWire.reg3)]
        case SrtlaWire.keepalive where packet.count == 2:
            counters.keepalives += 1
            return [packet]
        default:
            if let source = SrtRelayHeader.handshakeSourceID(packet) {
                counters.handshake = packet
                var response = packet
                put(source, in: &response, at: 12)
                var wrong = Data(repeating: 0, count: 20)
                wrong[0] = 0x80; wrong[1] = 2; wrong[15] = 99; wrong[19] = 100
                return [wrong, response]
            }
            guard let sequence = SrtlaWire.sequence(packet), let handshake = counters.handshake,
                  let source = SrtRelayHeader.handshakeSourceID(handshake), counters.media.count < 256 else { return [] }
            counters.media.append(packet)
            counters.mediaConnections.insert(ObjectIdentifier(socket))
            receivedSequences.insert(sequence)
            while receivedSequences.remove(nextExpected) != nil { nextExpected = (nextExpected &+ 1) & 0x7fffffff }
            var hopACK = Data([0x91, 0, 0, 0, 0, 0, 0, 0])
            put(sequence, in: &hopACK, at: 4)
            var srtACK = Data(repeating: 0, count: 20)
            srtACK[0] = 0x80; srtACK[1] = 2
            put(source, in: &srtACK, at: 12)
            put(nextExpected, in: &srtACK, at: 16)
            return [hopACK, srtACK]
        }
    }
    private func put(_ value: UInt32, in bytes: inout Data, at offset: Int) {
        for index in 0..<4 { bytes[offset + index] = UInt8((value >> (24 - index * 8)) & 0xff) }
    }
}
