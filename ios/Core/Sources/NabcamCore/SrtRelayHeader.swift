import Foundation

/// Minimal inspection only; never rewrites SRT packets. Offsets follow the SRT
/// protocol's 16-byte header and 48-byte handshake CIF (Haivision srt-rfc §3).
public enum SrtRelayHeader {
    public static func isTransportPacket(_ packet: Data) -> Bool {
        guard (16...1500).contains(packet.count), let type = SrtlaWire.type(packet) else { return false }
        // User-defined SRT control (including extension/key-management messages)
        // is 0xffff, not an SRTLA registration packet.
        return type < 0x8000 || (0x8000...0x8008).contains(type) || type == 0xffff
    }

    public static func handshakeSourceID(_ packet: Data) -> UInt32? {
        guard packet.count >= 64, isTransportPacket(packet), SrtlaWire.type(packet) == 0x8000,
              word(packet, at: 0) == 0x80000000,
              [UInt32(4), 5].contains(word(packet, at: 16)) else { return nil }
        let id = word(packet, at: 40)
        return id == 0 ? nil : id
    }

    public static func destinationID(_ packet: Data) -> UInt32? {
        guard isTransportPacket(packet) else { return nil }
        return word(packet, at: 12)
    }

    public static func cumulativeACK(_ packet: Data, for socketID: UInt32) -> UInt32? {
        guard packet.count >= 20, packet.count % 4 == 0, destinationID(packet) == socketID,
              word(packet, at: 0) == 0x80020000 else { return nil }
        return word(packet, at: 16) & 0x7fffffff
    }

    private static func word(_ packet: Data, at offset: Int) -> UInt32 {
        let index = packet.startIndex + offset
        return UInt32(packet[index]) << 24 | UInt32(packet[index + 1]) << 16
            | UInt32(packet[index + 2]) << 8 | UInt32(packet[index + 3])
    }
}
