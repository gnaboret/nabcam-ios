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
}

private final class ControlReceiver: @unchecked Sendable {
    struct Stats { var connections = 0; var groupRequests = 0; var joins = 0; var invalidJoins = 0; var keepalives = 0 }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.gnabcamirl.tests.control-receiver")
    private let lock = NSLock()
    private let reject: Bool
    private var sockets: [NWConnection] = []
    private var group: Data?
    private var counters = Stats()
    private var stopped = false
    var port: UInt16? { listener.port?.rawValue }
    var stats: Stats { lock.lock(); defer { lock.unlock() }; return counters }

    init(reject: Bool = false, ready: @escaping @Sendable () -> Void) throws {
        self.reject = reject
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
            if complete, let data, let response = self.reply(to: data) {
                socket.send(content: response, completion: .contentProcessed { _ in })
            }
            self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
            if !stopped { self.receive(socket) }
        }
    }
    private func reply(to packet: Data) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return nil }
        switch SrtlaWire.type(packet) {
        case SrtlaWire.reg1 where packet.count == 258:
            counters.groupRequests += 1
            if reject { return SrtlaWire.control(SrtlaWire.rejected) }
            // Preserve the client nonce half and replace the receiver-owned half.
            let assigned = Data(packet.dropFirst(2).prefix(128)) + Data(repeating: 0xa9, count: 128)
            group = assigned
            return SrtlaWire.control(SrtlaWire.reg2, payload: assigned)
        case SrtlaWire.reg2 where packet.count == 258:
            guard Data(packet.dropFirst(2)) == group else {
                counters.invalidJoins += 1
                return SrtlaWire.control(SrtlaWire.unknownGroup)
            }
            counters.joins += 1
            return SrtlaWire.control(SrtlaWire.reg3)
        case SrtlaWire.keepalive where packet.count == 2:
            counters.keepalives += 1
            return packet
        default: return nil
        }
    }
}
