import Foundation

/// Only used for direct Twitch authentication and device-local Keychain storage.
/// Never include this value in diagnostics or error descriptions.
public struct TwitchChatLogin: Equatable, Sendable {
    public let channel: String
    public let username: String
    public let token: String
    public enum Failure: Error { case invalid }

    public init(channel: String, username: String, token: String) throws {
        var room = channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if room.hasPrefix("#") { room.removeFirst() }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if secret.hasPrefix("oauth:") { secret.removeFirst(6) }
        guard TwitchChatPacket.validLogin(room), TwitchChatPacket.validLogin(user),
              !secret.isEmpty, secret.utf8.count <= 2048,
              secret.utf8.allSatisfy({ (33...126).contains($0) }) else { throw Failure.invalid }
        self.channel = room; self.username = user; self.token = secret
    }
}

public enum TwitchLoginArchive {
    private struct Archive: Codable {
        let version: Int
        let channel: String
        let username: String
        let token: String
    }
    public static func encode(_ login: TwitchChatLogin) throws -> Data {
        try JSONEncoder().encode(Archive(version: 1, channel: login.channel, username: login.username, token: login.token))
    }
    public static func decode(_ data: Data) throws -> TwitchChatLogin {
        guard data.count <= 8192 else { throw TwitchChatLogin.Failure.invalid }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1 else { throw TwitchChatLogin.Failure.invalid }
        return try TwitchChatLogin(channel: archive.channel, username: archive.username, token: archive.token)
    }
}
