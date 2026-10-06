import Foundation

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let sender: String
    public let text: String
    public let colorHex: String
    public let badges: [String]
    public let fragments: [ChatFragment]

    public init(id: String, sender: String, text: String, color: String?, badgeTypes: [String], twitchEmotes: String? = nil) {
        self.id = id
        self.sender = String(sender.prefix(40))
        self.text = String(text.prefix(300))
        colorHex = ChatAppearance.color(sender: sender, supplied: color)
        badges = ChatAppearance.badges(badgeTypes)
        if let twitchEmotes { fragments = ChatFragment.twitch(self.text, tags: twitchEmotes) }
        else { fragments = ChatFragment.kick(self.text) }
    }

    public var spokenText: String {
        fragments.map { if case .text(let value) = $0 { value } else { " " } }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ChatAppearance {
    private static let palette = ["#FFAD66", "#79C9FF", "#C4A0FF", "#7FE0AF", "#FF91C8", "#E5D879", "#83DDDD"]

    public static func color(sender: String, supplied: String?) -> String {
        if let supplied, supplied.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil { return supplied }
        // Kotlin-compatible deterministic fallback; never use Swift's randomized Hasher.
        let hash = sender.lowercased().utf16.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1) }
        let index = (Int(hash) % palette.count + palette.count) % palette.count
        return palette[index]
    }

    public static func badges(_ types: [String]) -> [String] {
        let labels = ["broadcaster": "HOST", "moderator": "MOD", "vip": "VIP", "subscriber": "SUB", "founder": "FOUND", "verified": "✓", "staff": "STAFF"]
        return types.reduce(into: [String]()) { result, type in
            if let label = labels[type.lowercased()], !result.contains(label), result.count < 4 { result.append(label) }
        }
    }
}

public enum ChatFragment: Equatable, Sendable {
    case text(String)
    case emote(name: String, url: URL)

    public static func kick(_ text: String) -> [ChatFragment] {
        guard let regex = try? NSRegularExpression(pattern: #"\[emote:([0-9]{1,20}):([^\]\r\n]{1,80})\]"#) else { return [.text(text)] }
        let source = text as NSString
        var cursor = 0
        var result: [ChatFragment] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).prefix(100) {
            if match.range.location > cursor { result.append(.text(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))) }
            let id = source.substring(with: match.range(at: 1))
            let name = source.substring(with: match.range(at: 2))
            if let url = URL(string: "https://files.kick.com/emotes/\(id)/fullsize") { result.append(.emote(name: name, url: url)) }
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length { result.append(.text(source.substring(from: cursor))) }
        return result
    }
}

public enum KickPacket: Equatable, Sendable {
    case ping, connected, subscriptionError
    case message(ChatMessage)

    public static func parse(_ data: Data, subscription: String) -> KickPacket? {
        guard data.count <= 65_536,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = root["event"] as? String else { return nil }
        if event == "pusher:ping" { return .ping }
        if event == "pusher:error" { return .subscriptionError }
        guard root["channel"] as? String == subscription else { return nil }
        if event == "pusher_internal:subscription_succeeded" { return .connected }
        guard event.hasSuffix("ChatMessageEvent") else { return nil }
        var payload = root["data"] as? [String: Any]
        if let encoded = root["data"] as? String, let bytes = encoded.data(using: .utf8) {
            payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }
        guard let payload, let sender = payload["sender"] as? [String: Any],
              let username = sender["username"] as? String, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let content = payload["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let identity = sender["identity"] as? [String: Any]
        let types = (identity?["badges"] as? [[String: Any]])?.compactMap { $0["type"] as? String } ?? []
        let id = (payload["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        return .message(ChatMessage(id: id, sender: username, text: content, color: identity?["color"] as? String, badgeTypes: types))
    }
}

/// Bounded deduplication across reconnects; no chat history is written to disk.
public struct ChatInbox: Sendable {
    public private(set) var messages: [ChatMessage] = []
    private var seen: Set<String> = []
    private var order: [String] = []
    public init() {}
    @discardableResult public mutating func accept(_ message: ChatMessage) -> Bool {
        guard seen.insert(message.id).inserted else { return false }
        order.append(message.id)
        if order.count > 300 { seen.remove(order.removeFirst()) }
        messages.append(message)
        if messages.count > 30 { messages.removeFirst(messages.count - 30) }
        return true
    }
}
