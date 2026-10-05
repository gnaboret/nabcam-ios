import Foundation
import Network

/// A single receiver-bound UDP socket. Still unused by BroadcastModel until the
/// complete SRTLA relay, pacing and recovery integration is verified.
final class SrtlaDatagramPath: @unchecked Sendable {
    enum Event: Sendable { case ready, waiting, failed, closed, datagram(Data) }
    enum SetupError: Error { case invalidEndpoint }
    static let maximumPacketBytes = 1500
    static let maximumPendingPackets = 64
    static let maximumPendingBytes = 64 * 1024

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.gnabcamirl.srtla.path")
    private let onEvent: @Sendable (Event) -> Void
    private let lock = NSLock()
    // All admission/lifecycle state is protected by lock. Receive-loop ownership
    // stays exclusively on queue. No packet data is retained after completion.
    private var ready = false
    private var closed = false
    private var started = false
    private var pendingPackets = 0
    private var pendingBytes = 0
    private var receiving = false

    init(host: String, port: UInt16, interface: NWInterface.InterfaceType? = nil,
         onEvent: @escaping @Sendable (Event) -> Void) throws {
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: port), port.rawValue != 0 else {
            throw SetupError.invalidEndpoint
        }
        let parameters = NWParameters.udp
        if let interface { parameters.requiredInterfaceType = interface }
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        self.onEvent = onEvent
    }

    func start() {
        lock.lock()
        guard !started, !closed else { lock.unlock(); return }
        started = true
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        connection.start(queue: queue)
    }

    /// True means admitted locally, not delivered. Completion reports only OS
    /// submission success; receiver ACKs remain the authority for delivery.
    @discardableResult
    func send(_ bytes: Data, completion: @escaping @Sendable (Bool) -> Void = { _ in }) -> Bool {
        lock.lock()
        guard ready, !closed, !bytes.isEmpty, bytes.count <= Self.maximumPacketBytes,
              pendingPackets < Self.maximumPendingPackets,
              pendingBytes + bytes.count <= Self.maximumPendingBytes else {
            lock.unlock(); completion(false); return false
        }
        pendingPackets += 1; pendingBytes += bytes.count
        lock.unlock()
        // Admission happens before dispatch: callers cannot build an unbounded
        // DispatchQueue of retained datagrams while the network is stalled.
        queue.async { [weak self] in
            guard let self else { completion(false); return }
            guard self.isOpen else { self.finish(bytes.count); completion(false); return }
            self.connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                self?.finish(bytes.count)
                completion(error == nil)
            })
        }
        return true
    }

    func close() {
        guard markClosed() else { return }
        connection.cancel()
        queue.async { [onEvent] in onEvent(.closed) }
    }
    private func markClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        closed = true; ready = false
        return true
    }
    deinit { connection.cancel() }

    private var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed
    }
    private func finish(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        pendingPackets -= 1; pendingBytes -= count
    }
    private func handle(_ state: NWConnection.State) {
        guard isOpen else { return }
        switch state {
        case .ready:
            lock.lock()
            guard !closed else { lock.unlock(); return }
            ready = true; lock.unlock()
            onEvent(.ready)
            if !receiving { receiving = true; receive() }
        case .waiting:
            lock.lock()
            guard !closed else { lock.unlock(); return }
            ready = false; lock.unlock()
            onEvent(.waiting)
        case .failed:
            guard markClosed() else { return }
            connection.cancel()
            onEvent(.failed) // Never forward raw network errors containing endpoints.
        default: break
        }
    }
    private func receive() {
        guard isOpen else { return }
        connection.receiveMessage { [weak self] data, _, complete, error in
            guard let self, self.isOpen else { return }
            if error != nil {
                guard self.markClosed() else { return }
                self.connection.cancel(); self.onEvent(.failed)
                return
            }
            if complete, let data, !data.isEmpty, data.count <= Self.maximumPacketBytes {
                self.onEvent(.datagram(data))
            }
            self.receive()
        }
    }
}
