import Foundation

/// Per-socket accounting only. Never retains media or initiates retransmission.
/// The relay must validate the source/socket before passing acknowledgments here.
public struct SrtlaFlightTracker: Sendable {
    public struct Receipt: Equatable, Sendable {
        public let bytes: Int
        /// Nil after a repeated sequence: the ACK cannot identify which send it confirms.
        public let roundTripMilliseconds: Int64?
    }
    private struct Flight: Sendable {
        let firstSent: Int64
        var bytes: Int
        var repeated = false
    }
    public static let capacity = 256
    private var flights: [UInt32: Flight] = [:]
    private var lastTime: Int64 = 0
    public private(set) var capacityEvictions: UInt64 = 0
    public var count: Int { flights.count }
    public var bytes: Int { flights.values.reduce(0) { $0 + $1.bytes } }

    public init() {}

    /// Call after successful socket submission, not merely relay-queue admission.
    @discardableResult
    public mutating func record(sequence: UInt32, bytes: Int, at time: Int64) -> Bool {
        guard sequence <= 0x7fffffff, (1...1500).contains(bytes), accept(time) else { return false }
        if var existing = flights[sequence] {
            existing.repeated = true
            existing.bytes = bytes
            flights[sequence] = existing
            return true
        }
        if flights.count == Self.capacity,
           let oldest = flights.min(by: {
               $0.value.firstSent == $1.value.firstSent ? $0.key < $1.key : $0.value.firstSent < $1.value.firstSent
           })?.key {
            flights.removeValue(forKey: oldest)
            capacityEvictions &+= 1
        }
        flights[sequence] = Flight(firstSent: time, bytes: bytes)
        return true
    }

    public mutating func acknowledge(sequence: UInt32, at time: Int64) -> Receipt? {
        guard accept(time), let flight = flights.removeValue(forKey: sequence) else { return nil }
        return Receipt(bytes: flight.bytes,
                       roundTripMilliseconds: flight.repeated ? nil : time - flight.firstSent)
    }

    /// Cumulative SRT ACKs release accounting but do not produce a per-path RTT sample.
    @discardableResult
    public mutating func acknowledgeBefore(_ nextExpected: UInt32, at time: Int64) -> Int {
        guard nextExpected <= 0x7fffffff, accept(time) else { return 0 }
        return remove { SrtlaWire.isBefore($0, nextExpected: nextExpected) }
    }

    /// Release lost packets from the flight estimate; SRT remains responsible for retrying.
    @discardableResult
    public mutating func negativeAcknowledgement(_ packet: Data, at time: Int64) -> Int {
        guard packet.count <= 1500, accept(time) else { return 0 }
        return remove { SrtlaWire.isLost($0, in: packet) }
    }

    /// Bounded diagnostic expiry, not an assertion that delivery failed.
    @discardableResult
    public mutating func expire(at time: Int64) -> Int {
        guard accept(time) else { return 0 }
        let expired = flights.filter { time - $0.value.firstSent > 1500 }.map(\.key)
        for sequence in expired { flights.removeValue(forKey: sequence) }
        return expired.count
    }

    public func oldestAge(at time: Int64) -> Int64? {
        guard time >= lastTime, let oldest = flights.values.map(\.firstSent).min() else { return nil }
        return time - oldest
    }

    private mutating func remove(where predicate: (UInt32) -> Bool) -> Int {
        let removed = flights.keys.filter(predicate)
        for sequence in removed { flights.removeValue(forKey: sequence) }
        return removed.count
    }

    private mutating func accept(_ time: Int64) -> Bool {
        guard time >= lastTime else { return false }
        lastTime = time
        return true
    }
}
