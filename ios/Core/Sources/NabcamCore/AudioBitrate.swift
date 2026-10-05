/// Requested AAC rate, independent of microphone gain and video bitrate.
public enum AudioBitrate: Int, Codable, CaseIterable, Identifiable, Sendable {
    case kbps64 = 64, kbps96 = 96, kbps128 = 128, kbps192 = 192
    public var id: Int { rawValue }
    public var bitsPerSecond: Int { rawValue * 1000 }
    public var label: String { "\(rawValue) kbps" }
}
