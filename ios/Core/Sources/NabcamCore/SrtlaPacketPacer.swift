import Foundation

/// Android's bounded token-bucket policy adapted to asynchronous iOS socket writes.
/// One leased packet at a time: only a successful completion spends byte credit.
/// SRT owns timestamps, ACKs and retransmission. Queue age NEVER expires media.
public struct SrtlaPacketPacer: Sendable {
    public struct Submission: Sendable {
        public let id: UInt64
        public let bytes: Data
    }
    private struct Entry: Sendable {
        let id: UInt64
        let bytes: Data
        let sequence: UInt32
        let at: Int64
        let retry: Bool
    }
    private struct Lease: Sendable { let entry: Entry; var acknowledged = false }
    public static let maximumBytes = 262_144
    public static let maximumPackets = 256
    private var originals: [Entry] = []
    private var retries: [Entry] = []
    private var lease: Lease?
    private var nextID: UInt64 = 0
    private var originalsSinceRetry = 0
    private var tokens = 1500.0
    private var lastRefill: Int64?
    private var lastTime: Int64 = 0
    private var lastRate = 1
    private var highestSent: UInt32?
    private var acknowledgedBefore: UInt32?
    public private(set) var queuedBytes = 0
    public private(set) var overflowPackets: UInt64 = 0
    public private(set) var duplicateRetries: UInt64 = 0
    public private(set) var acknowledgedRemoved: UInt64 = 0
    public private(set) var maximumWaitMilliseconds: Int64 = 0
    public var queuedPackets: Int { originals.count + retries.count + (lease == nil ? 0 : 1) }

    public init() {}

    @discardableResult
    public mutating func offer(_ bytes: Data, at time: Int64) -> Bool {
        guard bytes.count <= 1500, let sequence = SrtlaWire.sequence(bytes),
              nextID < UInt64.max, accept(time) else { return false }
        if let next = acknowledgedBefore, SrtlaWire.isBefore(sequence, nextExpected: next) {
            acknowledgedRemoved &+= 1
            return true
        }
        let retry = bytes[bytes.startIndex + 4] & 0x04 != 0
        if retry && (retries.contains { $0.bytes == bytes } || lease.map { $0.entry.retry && $0.entry.bytes == bytes } == true) {
            duplicateRetries &+= 1
            return true
        }
        let byteLimit = Self.maximumBytes - (retry ? 0 : 16 * 1500)
        let packetLimit = Self.maximumPackets - (retry ? 0 : 16)
        guard queuedBytes + bytes.count <= byteLimit, queuedPackets < packetLimit else {
            overflowPackets &+= 1
            return false
        }
        nextID += 1
        let entry = Entry(id: nextID, bytes: bytes, sequence: sequence, at: time, retry: retry)
        if retry { retries.append(entry) } else { originals.append(entry) }
        queuedBytes += bytes.count
        return true
    }

    /// Lease a packet for one socket attempt. Keep the ID until its OS completion;
    /// failed admission also requires finish(successful: false). No second lease
    /// is granted in the meantime, including while a cumulative ACK arrives.
    public mutating func take(at time: Int64, kbps: Int) -> Submission? {
        guard accept(time) else { return nil }
        refill(at: time, kbps: kbps)
        guard lease == nil, let entry = next(at: time), tokens >= Double(entry.bytes.count + 48) else { return nil }
        if entry.retry { retries.removeFirst() } else { originals.removeFirst() }
        lease = Lease(entry: entry)
        return Submission(id: entry.id, bytes: entry.bytes)
    }

    @discardableResult
    public mutating func finish(_ id: UInt64, successful: Bool, at time: Int64) -> Bool {
        guard let current = lease, current.entry.id == id, accept(time) else { return false }
        let entry = current.entry
        lease = nil
        if successful {
            tokens -= Double(entry.bytes.count + 48) // UDP + IPv6 overhead allowance.
            queuedBytes -= entry.bytes.count
            originalsSinceRetry = entry.retry ? 0 : min(3, originalsSinceRetry + 1)
            if highestSent.map({ SrtlaWire.isBefore($0, nextExpected: entry.sequence) }) ?? true {
                highestSent = entry.sequence
            }
            maximumWaitMilliseconds = max(maximumWaitMilliseconds, time - entry.at)
        } else if current.acknowledged {
            queuedBytes -= entry.bytes.count
            acknowledgedRemoved &+= 1
        } else if entry.retry {
            retries.insert(entry, at: 0)
        } else {
            originals.insert(entry, at: 0)
        }
        return true
    }

    public mutating func delayMilliseconds(at time: Int64, kbps: Int) -> Int64 {
        guard accept(time) else { return 20 }
        refill(at: time, kbps: kbps)
        guard lease == nil, let entry = next(at: time) else { return 20 }
        return Int64(ceil(max(0, Double(entry.bytes.count + 48) - tokens) * 8 / Double(max(1, min(kbps, 100_000)))))
    }

    /// Topology/scheduler changes cap saved credit; they never flush the queue.
    public mutating func rebase(at time: Int64) {
        guard accept(time) else { return }
        tokens = min(tokens, 1500)
        lastRefill = time
    }

    public func oldestAge(at time: Int64) -> Int64 {
        guard time >= lastTime else { return 0 }
        let earliest = [originals.first?.at, retries.first?.at, lease?.entry.at].compactMap { $0 }.min()
        return earliest.map { time - $0 } ?? 0
    }

    /// Only a validated end-to-end SRT ACK, NEVER an SRTLA hop ACK. Caller must
    /// validate the SRT destination socket ID. Equality is still outstanding.
    @discardableResult
    public mutating func acknowledgeBefore(_ next: UInt32) -> Int {
        guard next <= 0x7fffffff else { return 0 }
        var upper = highestSent
        if let pending = lease?.entry.sequence,
           upper.map({ SrtlaWire.isBefore($0, nextExpected: pending) }) ?? true { upper = pending }
        guard let upper else { return 0 }
        let afterUpper = (upper &+ 1) & 0x7fffffff
        guard next == afterUpper || SrtlaWire.isBefore(next, nextExpected: afterUpper) else { return 0 }
        if let previous = acknowledgedBefore, !SrtlaWire.isBefore(previous, nextExpected: next) { return 0 }
        acknowledgedBefore = next
        let redundant: (Entry) -> Bool = { SrtlaWire.isBefore($0.sequence, nextExpected: next) }
        let removed = originals.filter(redundant) + retries.filter(redundant)
        originals.removeAll(where: redundant); retries.removeAll(where: redundant)
        queuedBytes -= removed.reduce(0) { $0 + $1.bytes.count }
        acknowledgedRemoved &+= UInt64(removed.count)
        if let current = lease, redundant(current.entry) { lease?.acknowledged = true }
        // An already-issued write still owns its bytes/credit until completion.
        return removed.count
    }

    /// A new SRT caller/session can explicitly reset. IDs are never reused, so a
    /// late socket completion from the previous caller cannot consume new media.
    public mutating func reset() {
        let id = nextID
        self = Self()
        nextID = id
    }

    public static func rate(videoKbps: Int, audioKbps: Int, headroomPercent: Int) -> Int {
        let sum = min(100_000, max(0, videoKbps)) + min(100_000, max(0, audioKbps))
        return max(64, min(100_000, sum * max(115, min(150, headroomPercent)) / 100))
    }

    private func next(at time: Int64) -> Entry? {
        let delayed = retries.first.map { time - $0.at >= 100 } ?? false
        let useRetry = !retries.isEmpty && (originals.isEmpty || originalsSinceRetry >= (delayed ? 1 : 3))
        return useRetry ? retries.first : originals.first
    }
    private mutating func refill(at time: Int64, kbps: Int) {
        let elapsed = lastRefill.map { time - $0 } ?? 0
        // Credit accrued before a bitrate change uses the previous rate.
        tokens = min(3000, tokens + Double(elapsed) * Double(lastRate) / 8)
        lastRefill = time
        lastRate = max(1, min(100_000, kbps))
    }
    private mutating func accept(_ time: Int64) -> Bool {
        guard time >= lastTime else { return false }
        lastTime = time
        return true
    }
}
