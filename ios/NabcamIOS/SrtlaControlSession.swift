import Foundation
import Network
import Security
import NabcamCore

/// Registers receiver-bound sockets and maintains their control session. Media
/// forwarding/pacing is not wired up yet; BroadcastModel must not use this alone.
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
    }
    enum SetupError: Error { case invalidPathCount, randomSourceUnavailable }
    private struct Path {
        let socket: SrtlaDatagramPath
        let interface: Interface
        var state: State = .connecting
        var controlPacketsAdmitted: UInt64 = 0
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
    private var started = false
    private var closed = false

    init(endpoint: SrtlaEndpoint, interfaces: [Interface] = [.wifi, .cellular]) throws {
        guard (1...2).contains(interfaces.count) else { throw SetupError.invalidPathCount }
        self.endpoint = endpoint
        self.interfaces = interfaces
        registration = try SrtlaRegistration(randomSeed: Self.randomSeed())
    }

    func start() {
        queue.sync {
            guard !started, !closed else { return }
            started = true
            for (index, interface) in interfaces.enumerated() {
                let id = UInt64(index + 1)
                do {
                    let socket = try SrtlaDatagramPath(host: endpoint.host, port: endpoint.port,
                                                      interface: interface.networkType) { [weak self] event in
                        guard let self else { return }
                        self.queue.sync { self.receive(event, on: id) }
                    }
                    paths[id] = Path(socket: socket, interface: interface)
                    // A waiting socket is not allowed to become registration owner.
                    // Add it to the state machine only after NWConnection is ready.
                    socket.start()
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
            paths.keys.sorted().compactMap { id in
                guard let path = paths[id] else { return nil }
                let state: State
                if path.state == .ready && registration.isRegistered(id) { state = .registered }
                else if path.state == .ready && registration.isCoolingDown(id, at: Self.now()) { state = .cooldown }
                else { state = path.state }
                return PathSnapshot(id: id, interface: path.interface, state: state,
                                    controlPacketsAdmitted: path.controlPacketsAdmitted)
            }
        }
    }

    /// Terminal and idempotent. Create a new session for another broadcast.
    func close() { queue.sync { closeOnQueue() } }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        timer?.cancel(); timer = nil
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
            poll()
        case .waiting:
            // Keep protocol cooldowns intact. Sending is disabled by the socket;
            // registration naturally times out while the interface is unavailable.
            paths[id]?.state = .waiting
        case .failed, .closed:
            registration.removePath(id)
            paths[id]?.state = .failed
        case .datagram(let bytes):
            let now = Self.now()
            send(registration.receive(bytes, on: id, at: now))
            if !SrtlaWire.acknowledgements(bytes).isEmpty {
                registration.noteValidatedActivity(on: id, at: now)
            }
        }
    }

    private func poll() {
        guard !closed else { return }
        if registration.needsNewGroup {
            do { try registration.replaceExpiredGroup(randomSeed: Self.randomSeed()) }
            catch { closeOnQueue(); return }
        }
        send(registration.poll(at: Self.now()))
    }

    private func send(_ transmissions: [SrtlaRegistration.Transmission]) {
        for transmission in transmissions {
            guard let path = paths[transmission.path], path.state == .ready else { continue }
            // OS submission is not a server acknowledgment. Failed admission leaves
            // the state machine to retry on its normal bounded control interval.
            if path.socket.send(transmission.bytes) { paths[transmission.path]?.controlPacketsAdmitted &+= 1 }
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
        for path in paths.values { path.socket.close() }
    }
}
