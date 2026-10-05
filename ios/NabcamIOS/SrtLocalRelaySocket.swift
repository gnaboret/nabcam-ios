import Foundation
import Network
import NabcamCore

/// Loopback-only SRT ingress. The first complete handshake pins one UDP flow and
/// socket ID until close. This is flow isolation, not authentication of an app.
/// Create a fresh relay for a new broadcast/reconnect instead of silently adopting
/// a different caller and mixing its ACKs with queued media from the old stream.
final class SrtLocalRelaySocket: @unchecked Sendable {
    struct Snapshot: Sendable {
        let port: UInt16?
        let socketID: UInt32?
        let failed: Bool
    }
    private struct Candidate {
        let socket: SrtlaDatagramPath
        let created: UInt64
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.gnabcamirl.srtla.local-listener")
    private let lock = NSLock()
    private let onPacket: @Sendable (Data) -> Void
    // Mutable state is locked; onPacket ALWAYS runs outside the lock so the
    // relay may synchronously send a reply without a lock/queue inversion.
    private var candidates: [UUID: Candidate] = [:]
    private var pinned: UUID?
    private var socketID: UInt32?
    private var port: UInt16?
    private var started = false
    private var closed = false
    private var failed = false
    private var timer: DispatchSourceTimer?

    init(onPacket: @escaping @Sendable (Data) -> Void) throws {
        self.onPacket = onPacket
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                if !self.closed { self.port = self.listener.port?.rawValue }
                self.lock.unlock()
            case .failed: self.close(failed: true)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
    }

    func start() {
        lock.lock()
        guard !started, !closed else { lock.unlock(); return }
        started = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
        timer.setEventHandler { [weak self] in self?.expireCandidates() }
        self.timer = timer
        timer.resume()
        lock.unlock()
        listener.start(queue: queue)
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(port: port, socketID: socketID, failed: failed)
    }

    /// Only receiver replies addressed to the pinned SRT socket can return locally.
    @discardableResult
    func send(_ bytes: Data, completion: @escaping @Sendable (Bool) -> Void = { _ in }) -> Bool {
        lock.lock()
        let socket = pinned.flatMap { candidates[$0]?.socket }
        let valid = !closed && socketID != nil && SrtRelayHeader.destinationID(bytes) == socketID
        lock.unlock()
        guard valid, let socket else { completion(false); return false }
        return socket.send(bytes, completion: completion)
    }

    func close() { close(failed: false) }
    private func close(failed: Bool) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true; self.failed = failed; port = nil; socketID = nil; pinned = nil
        let sockets = candidates.values.map(\.socket)
        candidates.removeAll()
        timer?.cancel(); timer = nil
        lock.unlock()
        listener.cancel()
        sockets.forEach { $0.close() }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        guard !closed, pinned == nil, candidates.count < 2 else {
            lock.unlock(); connection.cancel(); return
        }
        let id = UUID()
        let socket = SrtlaDatagramPath(acceptedConnection: connection) { [weak self] event in
            self?.receive(event, from: id)
        }
        candidates[id] = Candidate(socket: socket, created: DispatchTime.now().uptimeNanoseconds)
        lock.unlock()
        socket.start()
    }

    private func receive(_ event: SrtlaDatagramPath.Event, from id: UUID) {
        lock.lock()
        guard !closed, let candidate = candidates[id] else { lock.unlock(); return }
        switch event {
        case .datagram(let bytes):
            guard SrtRelayHeader.isTransportPacket(bytes) else {
                let unclaimed = pinned != id
                if unclaimed { candidates.removeValue(forKey: id) }
                lock.unlock()
                if unclaimed { candidate.socket.close() }
                return
            }
            if pinned == nil {
                guard let source = SrtRelayHeader.handshakeSourceID(bytes) else {
                    candidates.removeValue(forKey: id); lock.unlock(); candidate.socket.close(); return
                }
                pinned = id; socketID = source
                let others = candidates.filter { $0.key != id }.map { $0.value.socket }
                candidates = [id: candidate]
                lock.unlock()
                others.forEach { $0.close() }
                onPacket(bytes)
            } else {
                let sameCaller = pinned == id
                let sameHandshake = SrtlaWire.type(bytes) != 0x8000 || SrtRelayHeader.handshakeSourceID(bytes) == socketID
                lock.unlock()
                if sameCaller && sameHandshake { onPacket(bytes) }
            }
        case .failed, .closed:
            let wasPinned = pinned == id
            candidates.removeValue(forKey: id)
            lock.unlock()
            if wasPinned { close(failed: true) }
        default: lock.unlock()
        }
    }

    private func expireCandidates() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let expired = candidates.filter { $0.key != pinned && now - $0.value.created >= 5_000_000_000 }
        for id in expired.keys { candidates.removeValue(forKey: id) }
        lock.unlock()
        expired.values.forEach { $0.socket.close() }
    }

    deinit {
        timer?.cancel()
        listener.cancel()
        for candidate in candidates.values { candidate.socket.close() }
    }
}
