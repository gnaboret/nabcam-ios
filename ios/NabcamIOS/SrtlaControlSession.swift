import Foundation
import Network
import Security
import NabcamCore

/// Receiver registration plus an optional paced loopback SRT relay. Exposed only
/// through the explicit experimental option; physical-iPhone failover is unverified.
final class SrtlaControlSession: @unchecked Sendable {
    enum Interface: Sendable {
        case wifi, cellular, automatic
        fileprivate var networkType: NWInterface.InterfaceType? {
            switch self { case .wifi: .wifi; case .cellular: .cellular; case .automatic: nil }
        }
    }
    enum State: Sendable { case connecting, ready, waiting, failed, registered, cooldown }
    struct PathSnapshot: Sendable {
        let id: UInt64
        let interface: Interface
        let state: State
        let controlPacketsAdmitted: UInt64
        let transmittedBytes: UInt64
        let outstandingPackets: Int
        let acknowledgedPackets: UInt64
        let relayRTTMilliseconds: Double?
        let relayRTTAgeMilliseconds: Int64?
        let traffic: DatagramRateMeter.Snapshot
    }
    struct RelaySnapshot: Sendable {
        let queuedPackets: Int
        let queuedBytes: Int
        let oldestMilliseconds: Int64
        let overflowPackets: UInt64
        let rejectedReplies: UInt64
        let localReplyDrops: UInt64
        let socketReplacements: UInt64
    }
    enum SetupError: Error { case invalidPathCount, invalidPacingRate, randomSourceUnavailable, identityExhausted }
    enum ConnectionWaitError: Error { case notStarted, closed, timedOut, invalidTimeout }
    private struct Path {
        let socket: SrtlaDatagramPath
        let interface: Interface
        var state: State = .connecting
        var controlPacketsAdmitted: UInt64 = 0
        var traffic = DatagramRateMeter()
        var flight = SrtlaFlightTracker()
        var acknowledgedPackets: UInt64 = 0
        var rtt: Double?
        var rttSampleTime: Int64?
        var window = 8.0
        var lastMediaSend: Int64?
        var retryAfter: Int64 = 0
        var serverRetryAfter: Int64 = 0
        var recovery = SrtlaSocketRecovery()
    }

    // All mutable session state belongs to this queue. Socket callbacks synchronously
    // hand off ONE event, so a fast sender cannot create an unbounded event mailbox.
    // No user callbacks run on this queue; callers obtain value-only snapshots.
    private let queue = DispatchQueue(label: "com.gnabcamirl.srtla.control")
    private let endpoint: SrtlaEndpoint
    private let interfaces: [Interface]
    private var registration: SrtlaRegistration
    private var paths: [UInt64: Path] = [:]
    private var timer: DispatchSourceTimer?
    private let pacingKbps: Int?
    private var local: SrtLocalRelaySocket?
    private var pacer = SrtlaPacketPacer()
    private var controls: [Data] = []
    private var pendingSend = false
    private var drainScheduled = false
    private var controlOverflow: UInt64 = 0
    private var rejectedReplies: UInt64 = 0
    private var localReplyDrops: UInt64 = 0
    private var nextPathID: UInt64 = 0
    private var socketReplacements: UInt64 = 0
    private var started = false
    private var closed = false

    init(endpoint: SrtlaEndpoint, interfaces: [Interface] = [.wifi, .cellular], pacingKbps: Int? = nil) throws {
        guard (1...2).contains(interfaces.count) else { throw SetupError.invalidPathCount }
        if let pacingKbps, !(1...100_000).contains(pacingKbps) { throw SetupError.invalidPacingRate }
        self.endpoint = endpoint
        self.interfaces = interfaces
        self.pacingKbps = pacingKbps
        registration = try SrtlaRegistration(randomSeed: Self.randomSeed())
    }

    func start() {
        queue.sync {
            guard !started, !closed else { return }
            started = true
            if pacingKbps != nil {
                do {
                    local = try SrtLocalRelaySocket { [weak self] bytes in
                        guard let self else { return }
                        self.queue.sync { self.fromLocal(bytes) }
                    }
                    local?.start()
                } catch { closeOnQueue(); return }
            }
            for interface in interfaces {
                do {
                    try openPath(interface: interface)
                } catch {
                    closeOnQueue()
                    return
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(25))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func snapshot() -> [PathSnapshot] {
        queue.sync {
            let now = Self.now()
            return paths.keys.sorted().compactMap { id in
                guard let path = paths[id] else { return nil }
                let state: State
                if path.state == .ready && registration.isRegistered(id) { state = .registered }
                else if path.state == .ready && registration.isCoolingDown(id, at: Self.now()) { state = .cooldown }
                else { state = path.state }
                let traffic = path.traffic.snapshot(at: now)
                return PathSnapshot(id: id, interface: path.interface, state: state,
                                    controlPacketsAdmitted: path.controlPacketsAdmitted,
                                    transmittedBytes: traffic.totalBytes, outstandingPackets: path.flight.count,
                                    acknowledgedPackets: path.acknowledgedPackets, relayRTTMilliseconds: path.rtt,
                                    relayRTTAgeMilliseconds: path.rttSampleTime.map { max(0, now - $0) }, traffic: traffic)
            }
        }
    }

    /// Contains the original private SRT options. Use only to open the local SRT
    /// client; never place this URL in logs or diagnostic snapshots.
    func localSRTURL() -> URL? {
        queue.sync {
            guard !closed, let port = local?.snapshot().port else { return nil }
            return try? endpoint.localSRTURL(port: port)
        }
    }

    /// One registered uplink is enough to begin; never wait for an unavailable
    /// second radio. Cancellation remains responsive during receiver registration.
    /// The returned URL contains private options and must not be logged.
    func waitUntilReady(timeoutMilliseconds: Int = 20_000) async throws -> URL {
        guard (1...60_000).contains(timeoutMilliseconds) else { throw ConnectionWaitError.invalidTimeout }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        while true {
            try Task.checkCancellation()
            let url: URL? = try queue.sync {
                guard !closed else { throw ConnectionWaitError.closed }
                guard started, pacingKbps != nil else { throw ConnectionWaitError.notStarted }
                guard paths.contains(where: { $0.value.state == .ready && registration.isRegistered($0.key) }),
                      let port = local?.snapshot().port else { return nil }
                return try endpoint.localSRTURL(port: port)
            }
            if let url { return url }
            guard clock.now < deadline else { throw ConnectionWaitError.timedOut }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(50))))
        }
    }

    func relaySnapshot() -> RelaySnapshot {
        queue.sync {
            RelaySnapshot(queuedPackets: pacer.queuedPackets + controls.count,
                          queuedBytes: pacer.queuedBytes + controls.reduce(0) { $0 + $1.count },
                          oldestMilliseconds: pacer.oldestAge(at: Self.now()),
                          overflowPackets: pacer.overflowPackets &+ controlOverflow,
                          rejectedReplies: rejectedReplies, localReplyDrops: localReplyDrops,
                          socketReplacements: socketReplacements)
        }
    }

    /// Terminal and idempotent. Create a new session for another broadcast.
    func close() { queue.sync { closeOnQueue() } }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        timer?.cancel(); timer = nil
        local?.close(); local = nil
        pacer.reset(); controls.removeAll()
        for (id, path) in paths {
            registration.removePath(id)
            path.socket.close()
        }
        paths.removeAll()
    }

    private func receive(_ event: SrtlaDatagramPath.Event, on id: UInt64) {
        guard !closed, paths[id] != nil else { return }
        switch event {
        case .ready:
            do { try registration.addPath(id) }
            catch { closeOnQueue(); return }
            paths[id]?.state = .ready
            paths[id]?.recovery.ready(at: Self.now())
            pacer.rebase(at: Self.now())
            poll()
        case .waiting:
            // Keep protocol cooldowns intact. Sending is disabled by the socket;
            // registration naturally times out while the interface is unavailable.
            paths[id]?.state = .waiting
            pacer.rebase(at: Self.now())
        case .failed, .closed:
            registration.removePath(id)
            paths[id]?.state = .failed
            paths[id]?.recovery.failed(at: Self.now())
        case .datagram(let bytes):
            let now = Self.now()
            send(registration.receive(bytes, on: id, at: now))
            let deadline = max(paths[id]?.serverRetryAfter ?? 0, registration.retryDeadline(id))
            paths[id]?.serverRetryAfter = deadline
            paths[id]?.recovery.received(at: now, registered: registration.isRegistered(id))
            let acks = SrtlaWire.acknowledgements(bytes)
            if registration.isRegistered(id), !acks.isEmpty {
                registration.noteValidatedActivity(on: id, at: now)
                for sequence in acks {
                    for pathID in paths.keys {
                        if let receipt = paths[pathID]?.flight.acknowledge(sequence: sequence, at: now) {
                            confirm(pathID, count: 1)
                            if let sample = receipt.roundTripMilliseconds {
                                let clamped = Double(max(1, min(4000, sample)))
                                let smoothed = (paths[pathID]?.rtt ?? clamped) * 0.85 + clamped * 0.15
                                paths[pathID]?.rtt = smoothed
                                paths[pathID]?.rttSampleTime = now
                            }
                        }
                    }
                }
            } else if SrtRelayHeader.isTransportPacket(bytes) {
                receiveTransport(bytes, on: id, at: now)
            }
            drain()
        }
    }

    private func poll() {
        guard !closed else { return }
        if local?.snapshot().failed == true { closeOnQueue(); return }
        if registration.needsNewGroup {
            do { try registration.replaceExpiredGroup(randomSeed: Self.randomSeed()) }
            catch { closeOnQueue(); return }
        }
        send(registration.poll(at: Self.now()))
        for id in paths.keys { paths[id]?.flight.expire(at: Self.now()) }
        recoverSockets()
        drain()
    }

    private func openPath(interface: Interface, history: SrtlaSocketRecovery = SrtlaSocketRecovery()) throws {
        guard nextPathID < UInt64.max else { throw SetupError.identityExhausted }
        nextPathID += 1
        let id = nextPathID
        let socket = try SrtlaDatagramPath(host: endpoint.host, port: endpoint.port,
                                         interface: interface.networkType) { [weak self] event in
            guard let self else { return }
            self.queue.sync { self.receive(event, on: id) }
        }
        var recovery = history
        recovery.opened(at: Self.now())
        paths[id] = Path(socket: socket, interface: interface, recovery: recovery)
        // Waiting interfaces cannot own initial registration. Every replacement
        // gets a new ID so late replies/completions cannot revive an old socket.
        socket.start()
    }

    private func recoverSockets() {
        let now = Self.now()
        for id in Array(paths.keys) {
            guard let path = paths[id] else { continue }
            let deadline = max(path.serverRetryAfter, registration.retryDeadline(id))
            guard path.recovery.shouldReplace(at: now, registered: registration.isRegistered(id),
                                              socketReady: path.state == .ready, serverRetryAfter: deadline) else { continue }
            var history = path.recovery
            history.replacing(at: now)
            registration.removePath(id)
            paths.removeValue(forKey: id)
            path.socket.close()
            do { try openPath(interface: path.interface, history: history) }
            catch { closeOnQueue(); return }
            socketReplacements &+= 1
            // Keep originals, repairs and their timestamps. SRT owns recovery of
            // packets already written to a failed link; this only resets burst credit.
            pacer.rebase(at: Self.now())
        }
    }

    private func send(_ transmissions: [SrtlaRegistration.Transmission]) {
        for transmission in transmissions {
            guard let path = paths[transmission.path], path.state == .ready else { continue }
            // OS submission is not a server acknowledgment. Failed admission leaves
            // the state machine to retry on its normal bounded control interval.
            let pathID = transmission.path
            let count = transmission.bytes.count
            if path.socket.send(transmission.bytes, completion: { [weak self] success in
                guard let self else { return }
                self.queue.async {
                    if !self.closed, success {
                        self.paths[pathID]?.traffic.record(bytes: count, retransmission: false, at: Self.now())
                    }
                }
            }) {
                paths[pathID]?.controlPacketsAdmitted &+= 1
                let kind = SrtlaWire.type(transmission.bytes)
                if kind == SrtlaWire.reg1 || kind == SrtlaWire.reg2 {
                    paths[pathID]?.recovery.registrationSent(at: Self.now())
                }
            }
        }
    }

    private func fromLocal(_ bytes: Data) {
        guard !closed, pacingKbps != nil else { return }
        if SrtlaWire.sequence(bytes) != nil { pacer.offer(bytes, at: Self.now()) }
        else if !controls.contains(bytes) {
            if controls.count < 32 { controls.append(bytes) } else { controlOverflow &+= 1 }
        }
        drain()
    }

    private func receiveTransport(_ bytes: Data, on id: UInt64, at now: Int64) {
        guard registration.isRegistered(id), let socketID = local?.snapshot().socketID,
              SrtRelayHeader.destinationID(bytes) == socketID else { rejectedReplies &+= 1; return }
        registration.noteValidatedActivity(on: id, at: now)
        if let next = SrtRelayHeader.cumulativeACK(bytes, for: socketID) {
            pacer.acknowledgeBefore(next)
            for pathID in paths.keys {
                let removed = paths[pathID]?.flight.acknowledgeBefore(next, at: now) ?? 0
                confirm(pathID, count: removed)
            }
        } else if SrtlaWire.type(bytes) == 0x8003 {
            for pathID in paths.keys {
                if (paths[pathID]?.flight.negativeAcknowledgement(bytes, at: now) ?? 0) > 0 {
                    let window = max(4, (paths[pathID]?.window ?? 8) * 0.75)
                    paths[pathID]?.window = window
                }
            }
        }
        if local?.send(bytes) != true { localReplyDrops &+= 1 }
    }

    private func confirm(_ id: UInt64, count: Int) {
        guard count > 0 else { return }
        paths[id]?.acknowledgedPackets &+= UInt64(count)
        let window = min(96, (paths[id]?.window ?? 8) + Double(count) * 0.15)
        paths[id]?.window = window
    }

    private func choosePath(media: Bool, at now: Int64) -> UInt64? {
        let eligible = paths.keys.sorted().filter {
            paths[$0]?.state == .ready && registration.isRegistered($0) && now >= (paths[$0]?.retryAfter ?? 0)
        }
        let proven = eligible.filter { (paths[$0]?.acknowledgedPackets ?? 0) > 0 }
        // New paths get small media probes without stealing handshake/control
        // traffic from an incumbent with demonstrated receiver progress.
        if media, let probe = eligible.first(where: { id in
            paths[id]?.acknowledgedPackets == 0 && (paths[id]?.lastMediaSend).map { now - $0 >= 250 } != false
        }) { return probe }
        let candidates = proven.isEmpty ? eligible : proven
        return candidates.max { first, second in
            func score(_ id: UInt64) -> Double {
                guard let path = paths[id] else { return 0 }
                return path.window / Double(path.flight.count + 1) / sqrt(max(5, path.rtt ?? 100))
            }
            let a = score(first), b = score(second)
            return a == b ? first > second : a < b
        }
    }

    private func drain() {
        guard !closed, !pendingSend, let rate = pacingKbps else { return }
        let now = Self.now()
        let isMedia = controls.isEmpty
        guard let id = choosePath(media: isMedia, at: now), let path = paths[id] else {
            // A short retry is useful only for a registered socket's temporary
            // write backoff. Offline/unregistered paths already wake drain from
            // receive/ready events and the control timer; avoid 50 Hz idle work
            // throughout an outage while retaining the bounded packet queue.
            if (pacer.queuedPackets > 0 || !controls.isEmpty), paths.contains(where: {
                $0.value.state == .ready && registration.isRegistered($0.key)
            }) { scheduleDrain(after: 20) }
            return
        }
        let submission = isMedia ? pacer.take(at: now, kbps: rate) : nil
        guard let bytes = controls.first ?? submission?.bytes else {
            if pacer.queuedPackets > 0 { scheduleDrain(after: pacer.delayMilliseconds(at: now, kbps: rate)) }
            return
        }
        pendingSend = true
        let sequence = SrtlaWire.sequence(bytes)
        if let sequence {
            paths[id]?.flight.record(sequence: sequence, bytes: bytes.count, at: now)
            paths[id]?.lastMediaSend = now
        }
        // At most one media/control completion is queued. Registration traffic is
        // independently bounded to the two paths' normal control intervals.
        path.socket.send(bytes) { [weak self] success in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                let completed = Self.now()
                if let submission { self.pacer.finish(submission.id, successful: success, at: completed) }
                else if success, !self.controls.isEmpty { self.controls.removeFirst() }
                if success {
                    let retransmission = sequence != nil && bytes[bytes.startIndex + 4] & 0x04 != 0
                    self.paths[id]?.traffic.record(bytes: bytes.count, retransmission: retransmission, at: completed)
                }
                else {
                    if let sequence { _ = self.paths[id]?.flight.acknowledge(sequence: sequence, at: completed) }
                    self.paths[id]?.retryAfter = completed + 20
                }
                self.pendingSend = false
                self.drain()
            }
        }
    }

    private func scheduleDrain(after milliseconds: Int64) {
        guard !drainScheduled else { return }
        drainScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(max(1, min(20, milliseconds))))) { [weak self] in
            guard let self else { return }
            self.drainScheduled = false
            self.drain()
        }
    }

    private static func now() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private static func randomSeed() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: SrtlaWire.groupIDSize)
        let result = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard result == errSecSuccess else { throw SetupError.randomSourceUnavailable }
        return Data(bytes)
    }

    deinit {
        // No external references remain; do not queue.sync from a queue-owned
        // callback's final release, which could otherwise deadlock destruction.
        timer?.cancel()
        local?.close()
        for path in paths.values { path.socket.close() }
    }
}
