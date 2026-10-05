import Foundation

/// Successful local UDP send completions, not delivered network throughput.
/// Fixed one-millisecond buckets keep memory bounded independently of packet rate.
/// Callers supply monotonic milliseconds; windows are (now - duration, now].
public struct DatagramRateMeter: Sendable {
    public struct Window: Sendable {
        public let milliseconds: Int64
        public let bytes: UInt64
        public let packets: UInt64
        public let retransmittedBytes: UInt64
        public let retransmittedPackets: UInt64
        public var kbps: Double { Double(bytes) * 8 / Double(milliseconds) }
    }
    public struct Snapshot: Sendable {
        public let totalBytes: UInt64
        public let totalPackets: UInt64
        public let totalRetransmittedBytes: UInt64
        public let totalRetransmittedPackets: UInt64
        public let windows: [Window]
    }
    private struct Bucket: Sendable {
        var time: Int64 = -1
        var bytes: UInt64 = 0
        var packets: UInt64 = 0
        var retransmittedBytes: UInt64 = 0
        var retransmittedPackets: UInt64 = 0
    }
    private var buckets = Array(repeating: Bucket(), count: 1000)
    private var totals = Bucket()
    private var latestTime: Int64 = -1
    public init() {}

    @discardableResult
    public mutating func record(bytes: Int, retransmission: Bool, at time: Int64) -> Bool {
        guard (1...1500).contains(bytes), time >= 0, time >= latestTime else { return false }
        latestTime = time
        let index = Int(time % 1000)
        if buckets[index].time != time { buckets[index] = Bucket(time: time) }
        Self.add(bytes: UInt64(bytes), retransmission: retransmission, to: &buckets[index])
        Self.add(bytes: UInt64(bytes), retransmission: retransmission, to: &totals)
        return true
    }

    public func snapshot(at time: Int64) -> Snapshot {
        let durations: [Int64] = [50, 100, 250, 1000]
        let windows: [Window] = durations.map { duration in
            var sum = Bucket()
            for bucket in buckets where bucket.time >= 0 && bucket.time <= time && time - bucket.time < duration {
                sum.bytes = Self.saturatingAdd(sum.bytes, bucket.bytes)
                sum.packets = Self.saturatingAdd(sum.packets, bucket.packets)
                sum.retransmittedBytes = Self.saturatingAdd(sum.retransmittedBytes, bucket.retransmittedBytes)
                sum.retransmittedPackets = Self.saturatingAdd(sum.retransmittedPackets, bucket.retransmittedPackets)
            }
            return Window(milliseconds: duration, bytes: sum.bytes, packets: sum.packets,
                          retransmittedBytes: sum.retransmittedBytes, retransmittedPackets: sum.retransmittedPackets)
        }
        return Snapshot(totalBytes: totals.bytes, totalPackets: totals.packets,
                        totalRetransmittedBytes: totals.retransmittedBytes,
                        totalRetransmittedPackets: totals.retransmittedPackets, windows: windows)
    }

    private static func add(bytes: UInt64, retransmission: Bool, to bucket: inout Bucket) {
        bucket.bytes = saturatingAdd(bucket.bytes, bytes)
        bucket.packets = saturatingAdd(bucket.packets, 1)
        if retransmission {
            bucket.retransmittedBytes = saturatingAdd(bucket.retransmittedBytes, bytes)
            bucket.retransmittedPackets = saturatingAdd(bucket.retransmittedPackets, 1)
        }
    }
    private static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let sum = a.addingReportingOverflow(b)
        return sum.overflow ? .max : sum.partialValue
    }
}
