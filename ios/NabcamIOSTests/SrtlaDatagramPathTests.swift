import Foundation
import Network
import NabcamCore
import XCTest
@testable import NabcamStorageHost

@MainActor
final class SrtlaDatagramPathTests: XCTestCase {
    func testLoopbackDatagramBoundariesRegistrationReplyAndClose() async throws {
        let listening = expectation(description: "Loopback receiver ready")
        let connected = expectation(description: "UDP path ready")
        let reply = expectation(description: "Receiver returns REG2")
        let closed = expectation(description: "Path closed")
        let seed = Data(repeating: 0x38, count: 256)
        let expected = SrtlaWire.control(SrtlaWire.reg2, payload: seed)
        let receiver = try LoopbackReceiver(ready: { listening.fulfill() })
        defer { receiver.close() }
        receiver.start()
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(receiver.port)
        let path = try SrtlaDatagramPath(host: "127.0.0.1", port: port) { event in
            switch event {
            case .ready: connected.fulfill()
            case .datagram(let data):
                if data == expected { reply.fulfill() }
            case .closed: closed.fulfill()
            default: break
            }
        }
        defer { path.close() }
        XCTAssertFalse(path.send(SrtlaWire.control(SrtlaWire.reg1, payload: seed)))
        path.start()
        await fulfillment(of: [connected], timeout: 5)
        XCTAssertFalse(path.send(Data()))
        XCTAssertFalse(path.send(Data(repeating: 0, count: 1501)))
        XCTAssertTrue(path.send(SrtlaWire.control(SrtlaWire.reg1, payload: seed)))
        await fulfillment(of: [reply], timeout: 5)
        path.close()
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertFalse(path.send(Data([0x90, 0])))
        XCTAssertEqual(receiver.receivedCount, 1)
    }

    func testInvalidEndpointAndCloseBeforeStart() throws {
        XCTAssertThrowsError(try SrtlaDatagramPath(host: "", port: 9000, onEvent: { _ in }))
        XCTAssertThrowsError(try SrtlaDatagramPath(host: "127.0.0.1", port: 0, onEvent: { _ in }))
        let path = try SrtlaDatagramPath(host: "127.0.0.1", port: 9000, onEvent: { _ in })
        path.close(); path.start(); path.close()
        XCTAssertFalse(path.send(Data([0x90, 0])))
    }

    func testAdmissionIsBoundedBeforeDispatch() async throws {
        for packetBytes in [2, 1500] {
            let connected = expectation(description: "Ready with held callback queue")
            let release = DispatchSemaphore(value: 0)
            let path = try SrtlaDatagramPath(host: "127.0.0.1", port: 9000) { event in
                if case .ready = event {
                    connected.fulfill()
                    _ = release.wait(timeout: .now() + 10)
                }
            }
            // Close before unblocking so none of the queued test packets are sent.
            defer { path.close(); release.signal() }
            path.start()
            await fulfillment(of: [connected], timeout: 5)
            let capacity = min(SrtlaDatagramPath.maximumPendingPackets,
                               SrtlaDatagramPath.maximumPendingBytes / packetBytes)
            let packet = Data(repeating: 0, count: packetBytes)
            for _ in 0..<capacity { XCTAssertTrue(path.send(packet)) }
            XCTAssertFalse(path.send(packet))
            path.close()
            XCTAssertFalse(path.send(packet))
            release.signal()
        }
    }
}

/// Real UDP on loopback only; never contacts the user's streaming service.
private final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.gnabcamirl.tests.udp")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var count = 0
    private var stopped = false
    var port: UInt16? { listener.port?.rawValue }
    var receivedCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    init(ready: @escaping @Sendable () -> Void) throws {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in if case .ready = state { ready() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock()
            guard !self.stopped else { self.lock.unlock(); connection.cancel(); return }
            self.connections.append(connection)
            self.lock.unlock()
            connection.start(queue: self.queue)
            connection.receiveMessage { [weak self] data, _, complete, error in
                guard let self, complete, error == nil, let data else { return }
                self.lock.lock(); self.count += 1; self.lock.unlock()
                guard data.count == 258, SrtlaWire.type(data) == SrtlaWire.reg1 else { return }
                connection.send(content: SrtlaWire.control(SrtlaWire.reg2, payload: Data(data.dropFirst(2))),
                    completion: .contentProcessed { _ in })
            }
        }
    }
    func start() { listener.start(queue: queue) }
    func close() {
        lock.lock(); stopped = true; let sockets = connections; connections.removeAll(); lock.unlock()
        sockets.forEach { $0.cancel() }; listener.cancel()
    }
}
