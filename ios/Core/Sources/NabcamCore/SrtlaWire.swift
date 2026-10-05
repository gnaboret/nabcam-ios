import Foundation

/// Wire primitives ported from GNAB CAM IRL's Android implementation.
/// This is not a transport: no sockets, registration, routing or bonding yet.
public enum SrtlaWire {
    public static let keepalive: UInt16 = 0x9000
    public static let ack: UInt16 = 0x9100
    public static let reg1: UInt16 = 0x9200
    public static let reg2: UInt16 = 0x9201
    public static let reg3: UInt16 = 0x9202
    public static let error: UInt16 = 0x9210
    public static let unknownGroup: UInt16 = 0x9211
    public static let rejected: UInt16 = 0x9212
    public static let groupIDSize = 256
    private static let sequenceMask: UInt32 = 0x7fffffff
    // Bound parsing to the maximum UDP datagram size, including hostile input.
    private static let maximumDatagramBytes = 65535

    public static func type(_ bytes: Data) -> UInt16? {
        guard bytes.count >= 2 else { return nil }
        return UInt16(bytes[bytes.startIndex]) << 8 | UInt16(bytes[bytes.startIndex + 1])
    }

    public static func control(_ type: UInt16, payload: Data = Data()) -> Data {
        var bytes = Data([UInt8(type >> 8), UInt8(type & 0xff)])
        bytes.append(payload)
        return bytes
    }

    public static func sequence(_ bytes: Data) -> UInt32? {
        guard bytes.count >= 16, bytes.count <= maximumDatagramBytes,
              bytes[bytes.startIndex] & 0x80 == 0 else { return nil }
        return word(bytes, offset: 0) & sequenceMask
    }

    public static func acknowledgements(_ bytes: Data) -> [UInt32] {
        guard type(bytes) == ack, bytes.count >= 8,
              bytes.count <= maximumDatagramBytes, bytes.count % 4 == 0 else { return [] }
        return stride(from: 4, to: bytes.count, by: 4).map { word(bytes, offset: $0) & sequenceMask }
    }

    /// SRT cumulative ACK is the next expected sequence; equality is not acknowledged.
    public static func isBefore(_ sequence: UInt32, nextExpected: UInt32) -> Bool {
        guard sequence <= sequenceMask, nextExpected <= sequenceMask else { return false }
        let distance = (nextExpected &- sequence) & sequenceMask
        return distance > 0 && distance < 0x40000000
    }

    /// Check a bounded outstanding sequence without expanding attacker-supplied NAK ranges.
    /// A malformed trailing range invalidates the entire NAK, even after an earlier match.
    public static func isLost(_ sequence: UInt32, in bytes: Data) -> Bool {
        guard sequence <= sequenceMask, type(bytes) == 0x8003, bytes.count >= 20,
              bytes.count <= maximumDatagramBytes, bytes.count % 4 == 0 else { return false }
        var offset = 16
        var matched = false
        while offset < bytes.count {
            let value = word(bytes, offset: offset)
            offset += 4
            if value & 0x80000000 != 0 {
                guard offset < bytes.count else { return false }
                let first = value & sequenceMask
                let last = word(bytes, offset: offset) & sequenceMask
                offset += 4
                let span = (last &- first) & sequenceMask
                guard span < 0x40000000 else { return false }
                let distance = (sequence &- first) & sequenceMask
                matched = matched || distance <= span
            } else {
                matched = matched || value == sequence
            }
        }
        return matched
    }

    private static func word(_ bytes: Data, offset: Int) -> UInt32 {
        let index = bytes.startIndex + offset
        // Byte assembly avoids alignment assumptions on UDP buffers and Data slices.
        return UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }
}
