import Foundation

/// IRC-over-WebSocket can contain multiple lines or an incomplete final line.
/// Reject oversized/invalid input rather than retaining unbounded network data.
public struct TwitchIRCDecoder: Sendable {
    private var pending = Data()
    public init() {}
    public enum Failure: Error { case oversized, invalidUTF8 }
    public mutating func append(_ bytes: Data) throws -> [String] {
        guard bytes.count <= 65_536, pending.count + bytes.count <= 65_536 else {
            pending.removeAll(); throw Failure.oversized
        }
        pending.append(bytes)
        var lines: [String] = []
        let delimiter = Data([13, 10])
        while let range = pending.range(of: delimiter) {
            let line = pending.prefix(upTo: range.lowerBound)
            guard line.count <= 16_384 else { pending.removeAll(); throw Failure.oversized }
            guard let value = String(data: line, encoding: .utf8) else {
                pending.removeAll(); throw Failure.invalidUTF8
            }
            if !value.isEmpty { lines.append(value) }
            pending.removeSubrange(pending.startIndex..<range.upperBound)
        }
        guard pending.count <= 16_384 else { pending.removeAll(); throw Failure.oversized }
        return lines
    }
}

public enum TwitchChatPacket: Equatable, Sendable {
    case ping(String), authenticated, joined, reconnect
    case authenticationFailed, channelUnavailable, capabilityRejected
    case message(ChatMessage, login: String)
    case clearMessage(String), clearUser(String), clearAll

    public static func validLogin(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 25 && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 95
        }
    }

    /// Parses one complete line. No server error text or credentials are returned.
    public static func parse(_ line: String, channel: String) -> Self? {
        guard line.utf8.count <= 16_384, validLogin(channel),
              !line.contains("\r"), !line.contains("\n"), !line.contains("\0") else { return nil }
        var rest = line[...]
        var tags: [String: String] = [:]
        if rest.first == "@" {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            for entry in rest[rest.index(after: rest.startIndex)..<space].split(separator: ";").prefix(128) {
                let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2, tags[String(parts[0])] == nil {
                    tags[String(parts[0])] = decodeTag(String(parts[1]))
                }
            }
            rest = rest[rest.index(after: space)...]
        }
        var prefix = ""
        if rest.first == ":" {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            prefix = String(rest[rest.index(after: rest.startIndex)..<space])
            rest = rest[rest.index(after: space)...]
        }
        let trailingStart = rest.range(of: " :")
        let trailing = trailingStart.map { String(rest[$0.upperBound...]) }
        let head = trailingStart.map { rest[..<$0.lowerBound] } ?? rest
        let words = head.split(separator: " ").map(String.init)
        guard let command = words.first else { return nil }
        switch command {
        case "PING":
            guard let payload = trailing, !payload.isEmpty, payload.utf8.count <= 512 else { return nil }
            return .ping(payload)
        case "001": return .authenticated
        case "RECONNECT": return .reconnect
        case "CAP": return words.contains("NAK") ? .capabilityRejected : nil
        case "NOTICE":
            if trailing == "Login authentication failed" || trailing == "Improperly formatted auth" { return .authenticationFailed }
            if words.dropFirst().first == "#\(channel)", tags["msg-id"] == "msg_channel_suspended" { return .channelUnavailable }
            return nil
        default: break
        }
        guard words.count >= 2, words[1] == "#\(channel)" else { return nil }
        switch command {
        case "ROOMSTATE": return .joined
        case "CLEARMSG":
            guard let id = tags["target-msg-id"], !id.isEmpty, id.count <= 128 else { return nil }
            return .clearMessage("twitch:\(id)")
        case "CLEARCHAT":
            if let trailing { return validLogin(trailing) ? .clearUser(trailing) : nil }
            return .clearAll
        case "PRIVMSG":
            let login = String(prefix.prefix { $0 != "!" })
            guard validLogin(login), var text = trailing else { return nil }
            if text.hasPrefix("\u{1}ACTION "), text.hasSuffix("\u{1}") {
                text = String(text.dropFirst(8).dropLast())
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let display = tags["display-name"].flatMap { $0.isEmpty ? nil : $0 } ?? login
            let id = tags["id"].flatMap { $0.isEmpty || $0.count > 128 ? nil : $0 } ?? UUID().uuidString
            let badges = (tags["badges"] ?? "").split(separator: ",").map { String($0.prefix { $0 != "/" }) }
            return .message(ChatMessage(id: "twitch:\(id)", sender: display, text: text,
                color: tags["color"], badgeTypes: badges, twitchEmotes: tags["emotes"] ?? ""), login: login)
        default: return nil
        }
    }

    static func decodeTag(_ value: String) -> String {
        var output = "", escaped = false
        for character in value {
            if escaped {
                switch character {
                case "s": output.append(" ")
                case ":": output.append(";")
                case "r", "n": output.append(" ") // no multiline names in overlays
                default: output.append(character)
                }
                escaped = false
            } else if character == "\\" { escaped = true }
            else { output.append(character) }
        }
        return output
    }
}

extension ChatFragment {
    /// Twitch positions count Unicode scalars, not UTF-16 units or Swift graphemes.
    public static func twitch(_ text: String, tags: String) -> [ChatFragment] {
        let points = Array(text.unicodeScalars)
        var ranges: [(start: Int, end: Int, id: String)] = []
        for entry in tags.prefix(4096).split(separator: "/") {
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { continue }
            for pair in parts[1].split(separator: ",") where ranges.count < 100 {
                let bounds = pair.split(separator: "-", omittingEmptySubsequences: false)
                guard bounds.count == 2, let start = Int(bounds[0]), let last = Int(bounds[1]),
                      start >= 0, last >= start, last < points.count else { continue }
                ranges.append((start, last + 1, String(parts[0])))
            }
        }
        func slice(_ from: Int, _ to: Int) -> String { String(String.UnicodeScalarView(points[from..<to])) }
        var result: [ChatFragment] = [], cursor = 0
        for range in ranges.sorted(by: { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }) {
            guard range.start >= cursor else { continue }
            if range.start > cursor { result.append(.text(slice(cursor, range.start))) }
            let url = URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(range.id)/static/dark/2.0")!
            result.append(.emote(name: slice(range.start, range.end), url: url))
            cursor = range.end
        }
        if cursor < points.count { result.append(.text(slice(cursor, points.count))) }
        return result
    }
}
