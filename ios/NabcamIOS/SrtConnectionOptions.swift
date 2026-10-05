import Foundation
import SRTHaishinKit

/// HaishinKit 2.2.5 reads URL option values without percent-decoding. Apply
/// credentials through its public socket API, then connect using a URL without
/// those fields. This preserves literal +, &, #, ?, % and Unicode in stream IDs.
struct SrtConnectionOptions: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum ValidationError: Error, LocalizedError {
        case malformed, callerRequired, invalidConnectionTimeout, duplicateCredential, invalidStreamID, invalidPassphrase, configurationFailed
        var errorDescription: String? {
            switch self {
            case .malformed: "The SRT connection options are not supported."
            case .callerRequired: "This iOS broadcaster requires SRT caller mode."
            case .invalidConnectionTimeout: "Use an SRT connection timeout from 1 to 10000 milliseconds."
            case .duplicateCredential: "Use only one SRT stream ID and one passphrase."
            case .invalidStreamID: "The SRT stream ID must fit within 512 UTF-8 bytes and contain no null characters."
            case .invalidPassphrase: "The SRT passphrase must contain 10–79 UTF-8 bytes and no null characters."
            case .configurationFailed: "Could not apply the SRT connection options."
            }
        }
    }

    let url: URL
    private let credentials: [SRTSocketOption]
    var description: String { "SRT options (redacted)" }
    var debugDescription: String { description }

    init(_ url: URL) throws {
        guard url.absoluteString.utf8.count <= 8192,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "srt", let host = parts.host, !host.isEmpty,
              let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.fragment == nil else { throw ValidationError.malformed }
        var streamID = ""
        var passphrase = ""
        var remaining: [URLQueryItem] = []
        var names: Set<String> = []
        var hasMode = false
        var hasConnectionTimeout = false
        for item in parts.queryItems ?? [] {
            let name = item.name.lowercased()
            if ["adapter", "port", "rendezvous"].contains(name) { throw ValidationError.callerRequired }
            if name == "mode" {
                guard !hasMode, item.value?.lowercased() == "caller" else { throw ValidationError.callerRequired }
                hasMode = true
                remaining.append(URLQueryItem(name: "mode", value: "caller"))
                continue
            }
            if name == "conntimeo" {
                guard !hasConnectionTimeout, let text = item.value, let value = Int(text), (1...10_000).contains(value)
                else { throw ValidationError.invalidConnectionTimeout }
                hasConnectionTimeout = true
                remaining.append(URLQueryItem(name: "conntimeo", value: String(value)))
                continue
            }
            guard name == "streamid" || name == "passphrase" else { remaining.append(item); continue }
            guard names.insert(name).inserted else { throw ValidationError.duplicateCredential }
            guard let value = item.value, !value.utf8.contains(0) else {
                throw name == "streamid" ? ValidationError.invalidStreamID : ValidationError.invalidPassphrase
            }
            if name == "streamid" {
                guard value.utf8.count <= 512 else { throw ValidationError.invalidStreamID }
                streamID = value
            } else {
                guard (10...79).contains(value.utf8.count) else { throw ValidationError.invalidPassphrase }
                passphrase = value
            }
        }
        if !hasMode { remaining.append(URLQueryItem(name: "mode", value: "caller")) }
        if !hasConnectionTimeout { remaining.append(URLQueryItem(name: "conntimeo", value: "5000")) }
        parts.queryItems = remaining.isEmpty ? nil : remaining
        // Remaining options still use the library's URL parser. Reject values it
        // would silently reinterpret rather than send a different configuration.
        guard parts.percentEncodedQuery == parts.query, parts.percentEncodedQuery?.contains("?") != true,
              let transportURL = parts.url else { throw ValidationError.malformed }
        self.url = transportURL
        // Set BOTH on every attempt, including empty defaults. A cancelled
        // pre-connect attempt must not leave its credentials on the next one.
        credentials = [try SRTSocketOption(name: .streamid, value: streamID),
                       try SRTSocketOption(name: .passphrase, value: passphrase)]
    }

    /// Before connect only. Do not log errors from the underlying library: option
    /// failures may contain values. The caller owns connection cleanup on failure.
    func apply(to connection: SRTConnection) async throws {
        do {
            for option in credentials { try await connection.setSocketOption(option) }
        } catch { throw ValidationError.configurationFailed }
    }
}
