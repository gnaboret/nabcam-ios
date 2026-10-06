import Foundation

/// Edits only the shared SRT latency option; never normalizes credential values.
public struct SrtLatencySetting: CustomStringConvertible, CustomDebugStringConvertible {
    public enum Failure: Error {
        case invalidDestination, advancedOptions, invalidValue
    }
    private let parts: URLComponents
    private let otherFields: [String]
    public let milliseconds: Int?
    public var description: String { "SRT latency setting (destination redacted)" }
    public var debugDescription: String { description }

    public init(_ input: String) throws {
        let destination = try StreamDestination(input)
        guard ["srt", "srtla"].contains(destination.url.scheme ?? ""),
              let parts = URLComponents(url: destination.url, resolvingAgainstBaseURL: false),
              destination.url.absoluteString.utf8.count <= 8192 else { throw Failure.invalidDestination }
        var remaining: [String] = []
        var latency: Int?
        var found = false
        for field in (parts.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: false) {
            if field.isEmpty { continue }
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(pair[0]).removingPercentEncoding?.lowercased()
            // A single control must not silently override directional options.
            if name == "peerlatency" || name == "rcvlatency" { throw Failure.advancedOptions }
            guard name == "latency" else { remaining.append(String(field)); continue }
            guard !found, pair.count == 2,
                  let text = String(pair[1]).removingPercentEncoding,
                  !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(text), value <= Int(Int32.max) else { throw Failure.invalidValue }
            found = true
            latency = value
        }
        self.parts = parts
        otherFields = remaining
        milliseconds = latency
    }

    /// nil removes only `latency`, restoring the library/receiver defaults.
    public func replacing(with milliseconds: Int?) throws -> String {
        if let milliseconds, !(0...10_000).contains(milliseconds) { throw Failure.invalidValue }
        var updated = parts
        var fields = otherFields
        if let milliseconds { fields.append("latency=\(milliseconds)") }
        updated.percentEncodedQuery = fields.isEmpty ? nil : fields.joined(separator: "&")
        guard let result = updated.url?.absoluteString, result.utf8.count <= 8192 else { throw Failure.invalidDestination }
        return result
    }
}
