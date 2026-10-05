import Foundation

public enum SrtlaRegistrationError: Error { case invalidGroup, groupStillHealthy, tooManyPaths }

/// Socket-independent SRTLA registration. The transport must supply cryptographically
/// random 256-byte seeds, monotonic milliseconds, and a NEW path ID for each socket.
/// Call receive only for datagrams from the configured receiver on that path's socket.
public struct SrtlaRegistration: Sendable {
    public struct Transmission: Sendable {
        public let path: UInt64
        public let bytes: Data
    }
    private struct Path: Sendable {
        var registered = false
        var joinSent = false
        var lastControl: Int64?
        var lastReply: Int64?
        var retryAfter: Int64 = 0
    }
    private var paths: [UInt64: Path] = [:]
    private var group: Data
    private var hasGroup = false
    private var owner: UInt64?
    private var ownerDeadline: Int64 = 0
    private var lastTime: Int64 = 0
    public private(set) var needsNewGroup = false

    public init(randomSeed: Data) throws {
        guard randomSeed.count == SrtlaWire.groupIDSize else { throw SrtlaRegistrationError.invalidGroup }
        group = randomSeed
    }

    public mutating func addPath(_ id: UInt64) throws {
        guard paths[id] == nil else { return }
        guard paths.count < 8 else { throw SrtlaRegistrationError.tooManyPaths }
        paths[id] = Path()
    }
    public mutating func removePath(_ id: UInt64) {
        paths.removeValue(forKey: id)
        if owner == id { owner = nil }
    }
    public func isRegistered(_ id: UInt64) -> Bool { paths[id]?.registered == true }

    public mutating func poll(at time: Int64) -> [Transmission] {
        guard acceptTime(time), !needsNewGroup else { return [] }
        if let owner, time >= ownerDeadline {
            let retry = max(paths[owner]?.retryAfter ?? 0, time + 2000)
            paths[owner]?.retryAfter = retry
            self.owner = nil
        }
        var outgoing: [Transmission] = []
        for id in paths.keys.sorted() {
            guard var path = paths[id] else { continue }
            if path.registered, let reply = path.lastReply, time - reply > 4000 {
                path.registered = false
                path.joinSent = false
            }
            guard time >= path.retryAfter, path.lastControl.map({ time - $0 >= 1000 }) ?? true else {
                paths[id] = path
                continue
            }
            let kind: UInt16
            if path.registered { kind = SrtlaWire.keepalive }
            else if hasGroup { kind = SrtlaWire.reg2; path.joinSent = true }
            else if owner == nil || owner == id {
                if owner == nil { owner = id; ownerDeadline = time + 4000 }
                kind = SrtlaWire.reg1
            } else { paths[id] = path; continue }
            path.lastControl = time
            paths[id] = path
            outgoing.append(Transmission(path: id, bytes: SrtlaWire.control(kind,
                payload: kind == SrtlaWire.keepalive ? Data() : group)))
        }
        return outgoing
    }

    /// Returns immediate join packets after an accepted REG2. No application data is sent.
    public mutating func receive(_ bytes: Data, on id: UInt64, at time: Int64) -> [Transmission] {
        guard paths[id] != nil, acceptTime(time), !needsNewGroup else { return [] }
        switch SrtlaWire.type(bytes) {
        case SrtlaWire.reg2:
            guard bytes.count == 258, !hasGroup, owner == id, time < ownerDeadline,
                  bytes.dropFirst(2).prefix(128) == group.prefix(128) else { return [] }
            group = Data(bytes.dropFirst(2)); hasGroup = true; owner = nil
            var outgoing: [Transmission] = []
            for pathID in paths.keys.sorted() {
                guard var path = paths[pathID], time >= path.retryAfter else { continue }
                path.joinSent = true; path.lastControl = time; paths[pathID] = path
                outgoing.append(Transmission(path: pathID, bytes: SrtlaWire.control(SrtlaWire.reg2, payload: group)))
            }
            return outgoing
        case SrtlaWire.reg3:
            guard bytes.count == 2, hasGroup, var path = paths[id], path.joinSent,
                  time >= path.retryAfter else { return [] }
            path.registered = true; path.lastReply = time; paths[id] = path
        case SrtlaWire.unknownGroup:
            guard bytes.count == 2 else { return [] }
            paths[id]?.registered = false; paths[id]?.joinSent = false
            if !paths.values.contains(where: { $0.registered }) {
                needsNewGroup = true; hasGroup = false; owner = nil
                for pathID in paths.keys {
                    paths[pathID]?.joinSent = false
                    let retry = max(paths[pathID]?.retryAfter ?? 0, time + 2000)
                    paths[pathID]?.retryAfter = retry
                }
            }
        case SrtlaWire.error, SrtlaWire.rejected:
            guard bytes.count == 2 else { return [] }
            paths[id]?.registered = false; paths[id]?.joinSent = false
            paths[id]?.retryAfter = time + (SrtlaWire.type(bytes) == SrtlaWire.rejected ? 60000 : 10000)
            if owner == id { owner = nil }
        case SrtlaWire.keepalive:
            if bytes.count == 2 { noteValidatedActivity(on: id, at: time) }
        default: break
        }
        return []
    }

    /// The socket layer must validate SRT/SRTLA ACKs before calling this.
    public mutating func noteValidatedActivity(on id: UInt64, at time: Int64) {
        guard paths[id]?.registered == true, acceptTime(time) else { return }
        paths[id]?.lastReply = time
    }
    public mutating func replaceExpiredGroup(randomSeed: Data) throws {
        guard needsNewGroup else { throw SrtlaRegistrationError.groupStillHealthy }
        guard randomSeed.count == 256 else { throw SrtlaRegistrationError.invalidGroup }
        group = randomSeed; needsNewGroup = false
        for id in paths.keys { paths[id]?.lastControl = nil }
    }
    private mutating func acceptTime(_ time: Int64) -> Bool {
        guard time >= lastTime, time <= Int64.max - 60000 else { return false }
        lastTime = time
        return true
    }
}
