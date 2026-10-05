import Foundation

public enum VideoCodecChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case h264, hevc
    public var id: String { rawValue }
    public var label: String { self == .h264 ? "H.264" : "HEVC (H.265)" }

    public enum ValidationError: Error, LocalizedError {
        case unsupportedTransport, unavailableHardware
        public var errorDescription: String? {
            switch self {
            case .unsupportedTransport: "This iOS build supports HEVC over SRT/SRTLA only. Select H.264 for RTMP/RTMPS."
            case .unavailableHardware: "This device does not report a hardware HEVC encoder. Select H.264."
            }
        }
    }

    public func validate(destination: StreamDestination, hardwareHEVC: Bool) throws {
        guard self == .hevc else { return }
        guard let scheme = destination.url.scheme, ["srt", "srtla"].contains(scheme) else { throw ValidationError.unsupportedTransport }
        guard hardwareHEVC else { throw ValidationError.unavailableHardware }
    }
}
