import Foundation

public enum DestinationError: Error, LocalizedError {
    case invalid, unsupported, missingStreamName, missingPort
    public var errorDescription: String? {
        switch self {
        case .invalid: "Enter a complete streaming destination URL."
        case .unsupported: "Use an RTMP, RTMPS, SRT or experimental SRTLA destination."
        case .missingStreamName: "RTMP needs the full server URL, including its app path and stream key."
        case .missingPort: "SRT needs a receiver port."
        }
    }
}

public struct StreamDestination: Sendable {
    public let url: URL
    public let protocolName: String
    public var requiresSrtlaRelay: Bool { url.scheme == "srtla" }

    public init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: { $0.isWhitespace }),
              var parts = URLComponents(string: text),
              let host = parts.host, !host.isEmpty, let scheme = parts.scheme?.lowercased()
        else { throw DestinationError.invalid }
        guard ["rtmp", "rtmps", "srt", "srtla"].contains(scheme) else { throw DestinationError.unsupported }
        parts.scheme = scheme
        if scheme == "srtla" {
            _ = try SrtlaEndpoint(text)
        } else if scheme == "srt" {
            guard let port = parts.port, (1...65535).contains(port) else { throw DestinationError.missingPort }
        } else {
            guard parts.path.split(separator: "/").count >= 2 else { throw DestinationError.missingStreamName }
        }
        guard parts.fragment == nil, let url = parts.url else { throw DestinationError.invalid }
        self.url = url
        protocolName = scheme.uppercased()
    }
}
