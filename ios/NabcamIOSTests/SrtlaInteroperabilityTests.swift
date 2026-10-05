@preconcurrency import AVFoundation
import Darwin
import Foundation
import HaishinKit
import Network
import NabcamCore
import SRTHaishinKit
import libsrt
import XCTest
@testable import NabcamStorageHost

@MainActor
final class SrtlaInteroperabilityTests: XCTestCase {
    func testHaishinKitPublishesEncryptedAudioThroughTwoPathRelay() async throws {
        try await exerciseEncryptedStream(blackholeOnePath: false)
    }

    func testEncryptedStreamContinuesWhenOneRegisteredPathStopsReplying() async throws {
        try await exerciseEncryptedStream(blackholeOnePath: true)
    }

    private func exerciseEncryptedStream(blackholeOnePath: Bool) async throws {
        // All addresses are loopback; this never contacts a user's stream host.
        // The passphrase is a fixed, synthetic test fixture, not an account secret.
        let server = try NativeSRTReceiver()
        defer { server.close() }
        server.start()
        let proxyReady = expectation(description: "Local SRTLA-to-SRT proxy ready")
        let proxy = try SRTLAInteropProxy(srtPort: server.port) { proxyReady.fulfill() }
        defer { proxy.close() }
        proxy.start()
        await fulfillment(of: [proxyReady], timeout: 5)
        let receiverPort = try XCTUnwrap(proxy.port)
        let endpoint = try SrtlaEndpoint("127.0.0.1:\(receiverPort)?mode=caller&latency=120&conntimeo=5000&streamid=nabcam-interop&passphrase=nabcam-local-test&pbkeylen=16")
        let relay = try SrtlaControlSession(endpoint: endpoint, interfaces: [.automatic, .automatic], pacingKbps: 1200)
        defer { relay.close() }
        relay.start()
        for _ in 0..<200 {
            if relay.localSRTURL() != nil && relay.snapshot().filter({ $0.state == .registered }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(relay.snapshot().filter { $0.state == .registered }.count, 2)
        let url = try XCTUnwrap(relay.localSRTURL())
        let connection = SRTConnection()
        let stream = SRTStream(connection: connection)
        do {
            try await connection.connect(url)
            let connected = await connection.connected
            XCTAssertTrue(connected)
            await stream.setExpectedMedias([.audio])
            try await stream.setAudioSettings(AudioCodecSettings(bitRate: 96_000, sampleRate: 48_000))
            await stream.publish()
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            var packetsBeforeLinkLoss = 0
            for frame in 0..<90 {
                if blackholeOnePath, frame == 45 {
                    packetsBeforeLinkLoss = server.snapshot().transportPackets
                    XCTAssertGreaterThan(packetsBeforeLinkLoss, 0)
                    XCTAssertTrue(proxy.blackholeOneMediaPath())
                }
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
                buffer.frameLength = 1024
                let samples = try XCTUnwrap(buffer.floatChannelData?[0])
                for index in 0..<1024 { samples[index] = Float(sin(Double(frame * 1024 + index) * 0.0576)) * 0.25 }
                await stream.append(buffer, when: AVAudioTime(sampleTime: Int64(frame * 1024), atRate: 48_000))
                try await Task.sleep(for: .milliseconds(21))
            }
            let minimumReceived = blackholeOnePath ? max(14, packetsBeforeLinkLoss + 7) : 14
            for _ in 0..<100 {
                if server.snapshot().transportPackets >= minimumReceived { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let received = server.snapshot()
            XCTAssertTrue(received.accepted)
            XCTAssertEqual(received.streamID, "nabcam-interop")
            XCTAssertGreaterThanOrEqual(received.transportPackets, 14)
            if blackholeOnePath {
                XCTAssertGreaterThanOrEqual(received.transportPackets - packetsBeforeLinkLoss, 7)
            }
            XCTAssertEqual(received.invalidMessages, 0)
            XCTAssertEqual(proxy.failureCount, 0)
            XCTAssertEqual(proxy.mediaPathCount, 2)
            XCTAssertEqual(relay.relaySnapshot().overflowPackets, 0)
            await stream.close()
            await connection.close()
        } catch {
            await stream.close()
            await connection.close()
            throw error
        }
    }
}

/// Actual libsrt listener. Nonblocking accept/receive make failure cleanup bounded.
private final class NativeSRTReceiver: @unchecked Sendable {
    struct Snapshot { var accepted = false; var streamID = ""; var transportPackets = 0; var invalidMessages = 0 }
    enum Failure: Error { case setup }
    let port: UInt16
    private let listener: SRTSOCKET
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.gnabcamirl.tests.native-srt")
    private var acceptedSocket: SRTSOCKET = SRT_INVALID_SOCK
    private var stats = Snapshot()
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init() throws {
        guard srt_startup() == 0 else { throw Failure.setup }
        let socket = srt_create_socket()
        var complete = false
        defer { if !complete { if socket != SRT_INVALID_SOCK { srt_close(socket) }; srt_cleanup() } }
        guard socket != SRT_INVALID_SOCK else { throw Failure.setup }
        var synchronous = false
        guard srt_setsockflag(socket, SRTO_RCVSYN, &synchronous, Int32(MemoryLayout<Bool>.size)) == 0 else { throw Failure.setup }
        let passphrase = Array("nabcam-local-test".utf8)
        let configured = passphrase.withUnsafeBytes { srt_setsockflag(socket, SRTO_PASSPHRASE, $0.baseAddress, Int32($0.count)) }
        guard configured == 0 else { throw Failure.setup }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                srt_bind(socket, $0, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, srt_listen(socket, 1) == 0 else { throw Failure.setup }
        var length = Int32(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { srt_getsockname(socket, $0, &length) }
        }
        guard named == 0, address.sin_port != 0 else { throw Failure.setup }
        port = UInt16(bigEndian: address.sin_port)
        listener = socket
        complete = true
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil, !stopped else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer; timer.resume()
    }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return stats }
    func close() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true; timer?.cancel(); timer = nil
        let accepted = acceptedSocket; acceptedSocket = SRT_INVALID_SOCK
        lock.unlock()
        if accepted != SRT_INVALID_SOCK { srt_close(accepted) }
        srt_close(listener)
    }
    private func poll() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        if acceptedSocket == SRT_INVALID_SOCK {
            acceptedSocket = srt_accept(listener, nil, nil)
            guard acceptedSocket != SRT_INVALID_SOCK else { return }
            var synchronous = false
            guard srt_setsockflag(acceptedSocket, SRTO_RCVSYN, &synchronous, Int32(MemoryLayout<Bool>.size)) == 0 else {
                srt_close(acceptedSocket)
                acceptedSocket = SRT_INVALID_SOCK
                stats.invalidMessages += 1
                return
            }
            stats.accepted = true
            var name = [CChar](repeating: 0, count: 512)
            var length: Int32 = 512
            if srt_getsockflag(acceptedSocket, SRTO_STREAMID, &name, &length) == 0 {
                stats.streamID = String(decoding: name.prefix(Int(max(0, min(512, length)))).map { UInt8(bitPattern: $0) }.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBufferPointer {
                srt_recvmsg(acceptedSocket, $0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { break }
            let size = Int(count)
            if size % 188 == 0 && stride(from: 0, to: size, by: 188).allSatisfy({ UInt8(bitPattern: buffer[$0]) == 0x47 }) {
                stats.transportPackets += size / 188
            } else { stats.invalidMessages += 1 }
        }
    }
    deinit { close(); srt_cleanup() }
}

/// Test-only SRTLA receiver: two registered UDP flows merge into one real SRT
/// socket. Backend replies return over a registered flow without header changes.
private final class SRTLAInteropProxy: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.gnabcamirl.tests.srtla-proxy")
    private let lock = NSLock()
    private var backend: SrtlaDatagramPath?
    private var flows: [NWConnection] = []
    private var registered: Set<ObjectIdentifier> = []
    private var mediaPaths: Set<ObjectIdentifier> = []
    private var blackholed: ObjectIdentifier?
    private var group: Data?
    private var stopped = false
    private var listenerStarted = false
    private var failures = 0
    var port: UInt16? { listener.port?.rawValue }
    var failureCount: Int { lock.lock(); defer { lock.unlock() }; return failures }
    var mediaPathCount: Int { lock.lock(); defer { lock.unlock() }; return mediaPaths.count }

    /// Drop traffic in BOTH directions without an immediate socket error, as a
    /// lost uplink can do. Keep the other path and backend SRT connection intact.
    func blackholeOneMediaPath() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard blackholed == nil, mediaPaths.count == 2,
              let flow = flows.first(where: { mediaPaths.contains(ObjectIdentifier($0)) }) else { return false }
        blackholed = ObjectIdentifier(flow)
        return true
    }

    init(srtPort: UInt16, ready: @escaping @Sendable () -> Void) throws {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        backend = try SrtlaDatagramPath(host: "127.0.0.1", port: srtPort) { [weak self] event in
            guard let self else { return }
            if case .ready = event {
                self.lock.lock()
                if !self.stopped, !self.listenerStarted {
                    self.listenerStarted = true
                    self.listener.start(queue: self.queue)
                }
                self.lock.unlock()
            }
            if case .failed = event { self.lock.lock(); self.failures += 1; self.lock.unlock() }
            if case .datagram(let bytes) = event { self.returnReply(bytes) }
        }
        listener.stateUpdateHandler = { state in if case .ready = state { ready() } }
        listener.newConnectionHandler = { [weak self] flow in
            guard let self else { flow.cancel(); return }
            self.lock.lock()
            guard !self.stopped, self.flows.count < 2 else { self.lock.unlock(); flow.cancel(); return }
            self.flows.append(flow); self.lock.unlock()
            flow.start(queue: self.queue)
            self.receive(flow)
        }
    }
    func start() { backend?.start() }
    func close() {
        lock.lock(); stopped = true; let sockets = flows; flows.removeAll(); registered.removeAll(); lock.unlock()
        listener.cancel(); backend?.close(); sockets.forEach { $0.cancel() }
    }
    private func receive(_ flow: NWConnection) {
        flow.receiveMessage { [weak self] bytes, _, complete, error in
            guard let self, error == nil else { return }
            if complete, let bytes { self.handle(bytes, from: flow) }
            self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
            if !stopped { self.receive(flow) }
        }
    }
    private func handle(_ bytes: Data, from flow: NWConnection) {
        lock.lock()
        guard !stopped, blackholed != ObjectIdentifier(flow) else { lock.unlock(); return }
        var response: Data?
        var forward = false
        switch SrtlaWire.type(bytes) {
        case SrtlaWire.reg1 where bytes.count == 258:
            let issued = Data(bytes.dropFirst(2).prefix(128)) + Data(repeating: 0x5c, count: 128)
            group = issued; response = SrtlaWire.control(SrtlaWire.reg2, payload: issued)
        case SrtlaWire.reg2 where bytes.count == 258:
            if Data(bytes.dropFirst(2)) == group {
                registered.insert(ObjectIdentifier(flow)); response = SrtlaWire.control(SrtlaWire.reg3)
            }
        case SrtlaWire.keepalive where bytes.count == 2: response = bytes
        default:
            forward = registered.contains(ObjectIdentifier(flow)) && SrtRelayHeader.isTransportPacket(bytes)
            if forward, let sequence = SrtlaWire.sequence(bytes) {
                mediaPaths.insert(ObjectIdentifier(flow))
                response = Data([0x91, 0, 0, 0, UInt8(sequence >> 24), UInt8((sequence >> 16) & 0xff),
                                 UInt8((sequence >> 8) & 0xff), UInt8(sequence & 0xff)])
            }
        }
        lock.unlock()
        if let response { flow.send(content: response, completion: .contentProcessed { _ in }) }
        if forward, backend?.send(bytes) != true { lock.lock(); failures += 1; lock.unlock() }
    }
    private func returnReply(_ bytes: Data) {
        lock.lock()
        let flow = stopped ? nil : flows.first {
            registered.contains(ObjectIdentifier($0)) && blackholed != ObjectIdentifier($0)
        }
        lock.unlock()
        flow?.send(content: bytes, completion: .contentProcessed { _ in })
    }
}
