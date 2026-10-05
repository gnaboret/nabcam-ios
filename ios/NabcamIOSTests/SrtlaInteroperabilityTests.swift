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
    // HaishinKit owns libsrt startup/cleanup. Keep one client for this suite:
    // receiver fixtures own sockets only, never the process-global SRT runtime.
    // Reusing the client also exercises close -> reconnect -> publish lifecycle.
    private static let session = SrtPublishSession()

    func testHaishinKitPublishesEncryptedAudioThroughTwoPathRelay() async throws {
        try await exerciseStream(blackholeOnePath: false, audioBitrate: .kbps192)
    }

    func testEncryptedStreamContinuesWhenOneRegisteredPathStopsReplying() async throws {
        try await exerciseStream(blackholeOnePath: true)
    }

    func testEncodedAudioAndVideoContinueAfterInputFormatChange() async throws {
        try await exerciseStream(blackholeOnePath: false, videoFormatChange: true)
    }

    func testEscapedStreamIDAndPassphraseReachReceiverUnchanged() async throws {
        try await exerciseStream(blackholeOnePath: false, escapedCredentials: true, audioBitrate: .kbps128)
    }

    func testUnencryptedDestinationClearsPreviouslyConfiguredCredentials() async throws {
        // Exercise the exact pre-connect cancellation case: options were applied,
        // but no successful connect occurred, so connection.close() is a no-op.
        let old = try SrtConnectionOptions(XCTUnwrap(URL(string:
            "srt://127.0.0.1:9000?streamid=stale-fixture&passphrase=stale-test-secret")))
        try await old.apply(to: Self.session.connection)
        try await exerciseStream(blackholeOnePath: false, encrypted: false, audioBitrate: .kbps64)
    }

    func testStopDuringNativeConnectionDoesNotPublishLater() async throws {
        let listening = expectation(description: "Non-SRT UDP listener ready")
        let unexpectedDisconnect = expectation(description: "Explicit Stop must not report a remote disconnect")
        unexpectedDisconnect.isInverted = true
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.newConnectionHandler = { $0.cancel() } // No SRT handshake response.
        listener.start(queue: DispatchQueue(label: "com.gnabcamirl.tests.silent-udp"))
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let url = try XCTUnwrap(URL(string: "srt://127.0.0.1:\(port)?conntimeo=1000&passphrase=cancel-fixture-secret"))
        let session = Self.session
        try await session.configure(url, expectedMedias: [.audio])
        let pending = Task { try await session.connect { unexpectedDisconnect.fulfill() } }
        try await Task.sleep(for: .milliseconds(30))
        pending.cancel()
        await session.close()
        do { try await pending.value; XCTFail("Cancelled connection must not become live") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation") }
        let connected = await session.connected
        XCTAssertFalse(connected)
        try await session.configure(url, expectedMedias: [.audio])
        await fulfillment(of: [unexpectedDisconnect], timeout: 0.2)
    }

    private func exerciseStream(blackholeOnePath: Bool, escapedCredentials: Bool = false, encrypted: Bool = true,
                                videoFormatChange: Bool = false, audioBitrate: AudioBitrate = .kbps96) async throws {
        // All addresses are loopback; this never contacts a user's stream host.
        // The passphrase is a fixed, synthetic test fixture, not an account secret.
        let session = Self.session
        let stream = await session.mediaStream
        let streamID = encrypted ? (escapedCredentials ? "#!::r=nabcam/interop,token=a+b&c?%" : "nabcam-interop") : ""
        let passphrase: String? = encrypted ? (escapedCredentials ? "nabcam+local&test#?%" : "nabcam-local-test") : nil
        let server = try NativeSRTReceiver(passphrase: passphrase)
        defer { server.close() }
        server.start()
        let proxyReady = expectation(description: "Local SRTLA-to-SRT proxy ready")
        let proxy = try SRTLAInteropProxy(srtPort: server.port) { proxyReady.fulfill() }
        defer { proxy.close() }
        proxy.start()
        await fulfillment(of: [proxyReady], timeout: 5)
        let receiverPort = try XCTUnwrap(proxy.port)
        var address = URLComponents()
        address.scheme = "srtla"; address.host = "127.0.0.1"; address.port = Int(receiverPort)
        address.queryItems = [URLQueryItem(name: "mode", value: "caller"), URLQueryItem(name: "latency", value: "120"),
                              URLQueryItem(name: "conntimeo", value: "5000")]
        if let passphrase {
            address.queryItems?.append(contentsOf: [URLQueryItem(name: "streamid", value: streamID),
                URLQueryItem(name: "passphrase", value: passphrase), URLQueryItem(name: "pbkeylen", value: "16")])
        }
        let endpoint = try SrtlaEndpoint(XCTUnwrap(address.url).absoluteString)
        let relay = try SrtlaControlSession(endpoint: endpoint, interfaces: [.automatic, .automatic], pacingKbps: 1200)
        defer { relay.close() }
        relay.start()
        let url = try await relay.waitUntilReady()
        for _ in 0..<200 {
            if relay.localSRTURL() != nil && relay.snapshot().filter({ $0.state == .registered }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(relay.snapshot().filter { $0.state == .registered }.count, 2)
        do {
            try await session.configure(url, expectedMedias: videoFormatChange ? [.audio, .video] : [.audio])
            try await stream.setAudioSettings(AudioCodecSettings(bitRate: audioBitrate.bitsPerSecond, sampleRate: 48_000))
            if videoFormatChange {
                try await stream.setVideoSettings(VideoEncoderConfiguration.settings(codec: .h264, preset: .hd30, bitrateKbps: 600))
            }
            try await session.connect({})
            // Upstream publish() adds previously seen input types even after
            // close. This reusable fixture explicitly chooses its media set;
            // otherwise a prior A/V test can make an audio-only test await video.
            await stream.setExpectedMedias(videoFormatChange ? [.audio, .video] : [.audio])
            let connected = await session.connected
            XCTAssertTrue(connected)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            var packetsBeforeLinkLoss = 0
            var beforeFormatChange = NativeSRTReceiver.Snapshot()
            for frame in 0..<90 {
                if videoFormatChange, frame == 45 {
                    beforeFormatChange = server.snapshot()
                    XCTAssertGreaterThan(beforeFormatChange.audioPES, 0)
                    XCTAssertGreaterThan(beforeFormatChange.videoPES, 0)
                }
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
                if videoFormatChange, frame.isMultiple(of: 2) {
                    // Synthetic capture input changes size, while the requested
                    // output and the audio/publisher session remain unchanged.
                    let video = try Self.videoSample(width: frame < 45 ? 640 : 1280,
                                                     height: frame < 45 ? 360 : 720,
                                                     sampleTime: Int64((frame + 1) * 1024))
                    await stream.append(video)
                }
                try await Task.sleep(for: .milliseconds(21))
            }
            let minimumReceived = blackholeOnePath ? max(14, packetsBeforeLinkLoss + 7) : 14
            for _ in 0..<100 {
                let snapshot = server.snapshot()
                if snapshot.transportPackets >= minimumReceived,
                   !videoFormatChange || (snapshot.videoPES >= beforeFormatChange.videoPES + 10 &&
                                          snapshot.audioPES >= beforeFormatChange.audioPES + 10) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let received = server.snapshot()
            XCTAssertTrue(received.accepted)
            XCTAssertEqual(received.streamID, streamID)
            XCTAssertGreaterThanOrEqual(received.transportPackets, 14)
            if videoFormatChange {
                XCTAssertGreaterThanOrEqual(received.videoPES - beforeFormatChange.videoPES, 10)
                XCTAssertGreaterThanOrEqual(received.audioPES - beforeFormatChange.audioPES, 10)
            }
            if blackholeOnePath {
                XCTAssertGreaterThanOrEqual(received.transportPackets - packetsBeforeLinkLoss, 7)
            }
            XCTAssertEqual(received.invalidMessages, 0)
            XCTAssertEqual(proxy.failureCount, 0)
            XCTAssertEqual(proxy.mediaPathCount, 2)
            XCTAssertEqual(relay.relaySnapshot().overflowPackets, 0)
            await session.close()
        } catch {
            await session.close()
            throw error
        }
    }

    private static func videoSample(width: Int, height: Int, sampleTime: Int64) throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                          nil, &image), kCVReturnSuccess)
        let pixels = try XCTUnwrap(image)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixels, []), kCVReturnSuccess)
        if let bytes = CVPixelBufferGetBaseAddress(pixels) {
            // Low-complexity gray fixture avoids testing uplink capacity.
            memset(bytes, 128, CVPixelBufferGetBytesPerRow(pixels) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                   imageBuffer: pixels, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 2048, timescale: 48_000),
                                       presentationTimeStamp: CMTime(value: sampleTime, timescale: 48_000),
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                               formatDescription: try XCTUnwrap(format),
                                                               sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

/// Actual libsrt listener. Nonblocking accept/receive make failure cleanup bounded.
private final class NativeSRTReceiver: @unchecked Sendable {
    struct Snapshot {
        var accepted = false; var streamID = ""; var transportPackets = 0; var invalidMessages = 0
        var audioPES = 0; var videoPES = 0
    }
    enum Failure: Error { case setup }
    let port: UInt16
    private let listener: SRTSOCKET
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.gnabcamirl.tests.native-srt")
    private var acceptedSocket: SRTSOCKET = SRT_INVALID_SOCK
    private var stats = Snapshot()
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init(passphrase: String?) throws {
        let socket = srt_create_socket()
        var complete = false
        defer { if !complete, socket != SRT_INVALID_SOCK { srt_close(socket) } }
        guard socket != SRT_INVALID_SOCK else { throw Failure.setup }
        var synchronous = false
        guard srt_setsockflag(socket, SRTO_RCVSYN, &synchronous, Int32(MemoryLayout<Bool>.size)) == 0 else { throw Failure.setup }
        var enforceEncryption = true
        guard srt_setsockflag(socket, SRTO_ENFORCEDENCRYPTION, &enforceEncryption, Int32(MemoryLayout<Bool>.size)) == 0 else { throw Failure.setup }
        if let passphrase {
            let passwordBytes = Array(passphrase.utf8)
            let configured = passwordBytes.withUnsafeBytes { srt_setsockflag(socket, SRTO_PASSPHRASE, $0.baseAddress, Int32($0.count)) }
            guard configured == 0 else { throw Failure.setup }
        }
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
                // Pinned HaishinKit muxer uses video PID 256 and audio PID 257.
                // Count PES starts, not padding/continuations. This proves
                // transport progress only, not decoding, lip sync, or camera FPS.
                for offset in stride(from: 0, to: size, by: 188) {
                    let high = UInt8(bitPattern: buffer[offset + 1])
                    let pid = (Int(high & 0x1f) << 8) | Int(UInt8(bitPattern: buffer[offset + 2]))
                    let control = UInt8(bitPattern: buffer[offset + 3])
                    if high & 0x40 != 0, control & 0x10 != 0 {
                        if pid == 256 { stats.videoPES += 1 }
                        if pid == 257 { stats.audioPES += 1 }
                    }
                }
            } else { stats.invalidMessages += 1 }
        }
    }
    deinit { close() }
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
