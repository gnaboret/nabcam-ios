import Foundation

/// Receiver addressing for the upcoming local SRT-to-SRTLA relay. Parsing this
/// type does not enable SRTLA in StreamDestination or the broadcast UI.
public struct SrtlaEndpoint: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum ValidationError: Error, LocalizedError {
        case invalidReceiver, callerRequired, invalidLocalPort
        public var errorDescription: String? {
            switch self {
            case .invalidReceiver: "Use an SRTLA receiver host and port, without a path or username."
            case .callerRequired: "The local SRTLA relay requires SRT caller mode."
            case .invalidLocalPort: "The local relay port is unavailable."
            }
        }
    }
    public let host: String
    public let port: UInt16
    private let encodedQuery: String?
    public var description: String { "SRTLA receiver (redacted)" }
    public var debugDescription: String { description }

    public init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8192,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ValidationError.invalidReceiver
        }
        let text = trimmed.contains("://") ? trimmed : "srtla://" + trimmed
        guard let parts = URLComponents(string: text),
              ["srtla", "srt"].contains(parts.scheme?.lowercased() ?? ""),
              let rawHost = parts.host, !rawHost.isEmpty,
              let rawPort = parts.port, (1...65535).contains(rawPort),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw ValidationError.invalidReceiver }
        for item in parts.queryItems ?? [] where item.name.lowercased() == "mode" {
            guard item.value?.lowercased() == "caller" else { throw ValidationError.callerRequired }
        }
        // HaishinKit 2.2.5 treats an adapter option without an explicit mode as
        // rendezvous. This bridge owns the local socket and only supports caller
        // mode; do not let receiver options change its local bind/mode implicitly.
        guard !(parts.queryItems ?? []).contains(where: {
            ["adapter", "port"].contains($0.name.lowercased())
        }) else { throw ValidationError.callerRequired }
        // URLComponents can retain brackets around an IPv6 literal; NWEndpoint.Host
        // expects the literal itself. Leave DNS names and zone IDs otherwise intact.
        host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        port = UInt16(rawPort)
        encodedQuery = parts.percentEncodedQuery
    }

    public func localSRTURL(port: UInt16) throws -> URL {
        guard port != 0 else { throw ValidationError.invalidLocalPort }
        var parts = URLComponents()
        parts.scheme = "srt"; parts.host = "127.0.0.1"; parts.port = Int(port)
        parts.percentEncodedQuery = encodedQuery
        guard let result = parts.url else { throw ValidationError.invalidReceiver }
        return result
    }
}
