import Combine
import Foundation
import NabcamCore

@MainActor
final class StreamChatService: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var status = "Chat off"
    @Published private(set) var isEnabled = false
    @Published private(set) var isConnected = false
    private let http: URLSession
    private var owner = UUID()
    private var worker: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var inbox = ChatInbox()
    private var twitchSocket: (any TwitchChatSocket)?
    private var twitchAuthors: [String: String] = [:]
    private let makeTwitchSocket: @MainActor () -> any TwitchChatSocket
    private let validateTwitchToken: @MainActor (TwitchChatLogin) async throws -> Void
    private let tokenValidationInterval: Duration

    init(makeTwitchSocket: @escaping @MainActor () -> any TwitchChatSocket = { NativeTwitchChatSocket() },
         validateTwitchToken: @escaping @MainActor (TwitchChatLogin) async throws -> Void = { try await TwitchTokenValidator.validate($0) },
         tokenValidationInterval: Duration = .seconds(3600)) {
        self.makeTwitchSocket = makeTwitchSocket
        self.validateTwitchToken = validateTwitchToken
        self.tokenValidationInterval = tokenValidationInterval
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        http = URLSession(configuration: configuration)
    }

    func connect(channel input: String) {
        disconnect()
        let channel = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard channel.range(of: "^[a-z0-9_-]{1,50}$", options: .regularExpression) != nil else {
            status = "Enter a Kick channel name, not a URL"
            return
        }
        inbox = ChatInbox()
        messages = []
        isEnabled = true
        let token = owner
        worker = Task { [weak self] in
            guard let self else { return }
            var retry = 0
            while !Task.isCancelled && token == owner {
                do {
                    status = "Finding #\(channel)…"
                    let room = try await resolve(channel)
                    try Task.checkCancellation()
                    guard token == owner else { return }
                    try await run(room: room, channel: channel, token: token)
                } catch is CancellationError { return }
                catch ChatError.denied(let code) {
                    guard token == owner else { return }
                    isConnected = false
                    isEnabled = false
                    status = "Kick lookup HTTP \(code) · check channel and retry"
                    return
                } catch {
                    guard !Task.isCancelled, token == owner else { return }
                    if isConnected { retry = 0 }
                    isConnected = false
                    let delay = min(30, 3 * (1 << min(retry, 4)))
                    retry += 1
                    status = "Chat disconnected · retry in \(delay)s"
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
            }
        }
    }

    func disconnect() {
        owner = UUID()
        worker?.cancel()
        worker = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        twitchSocket?.cancel()
        twitchSocket = nil
        isConnected = false
        isEnabled = false
        status = "Chat off"
    }

    func connectTwitch(_ login: TwitchChatLogin) {
        disconnect()
        inbox = ChatInbox(); messages = []
        twitchAuthors = [:]
        isEnabled = true
        let token = owner
        worker = Task { [weak self] in
            guard let self else { return }
            var retry = 0
            while !Task.isCancelled, token == owner {
                do {
                    try await runTwitch(login, token: token)
                } catch is CancellationError { return }
                catch TwitchFailure.authentication {
                    guard token == owner else { return }
                    isEnabled = false; isConnected = false
                    status = "Twitch login rejected · check username and chat token"
                    return
                } catch TwitchFailure.unavailable {
                    guard token == owner else { return }
                    isEnabled = false; isConnected = false
                    status = "Twitch chat unavailable · check channel and permissions"
                    return
                } catch {
                    guard !Task.isCancelled, token == owner else { return }
                    if isConnected { retry = 0 }
                    isConnected = false
                    let delay = min(30, 3 * (1 << min(retry, 4)))
                    retry += 1
                    status = "Twitch disconnected · retry in \(delay)s"
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
            }
        }
    }

    private func runTwitch(_ login: TwitchChatLogin, token: UUID) async throws {
        status = "Checking Twitch login…"
        do { try await validateTwitchToken(login) }
        catch TwitchTokenValidation.Failure.rejected { throw TwitchFailure.authentication }
        try Task.checkCancellation()
        guard token == owner else { throw CancellationError() }
        let connection = makeTwitchSocket()
        twitchSocket = connection
        connection.resume()
        status = "Connecting Twitch · #\(login.channel)"
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            connection.cancel()
        }
        var tokenRejected = false
        var validationFailed = false
        let validation = Task {
            do {
                while !Task.isCancelled, token == owner {
                    try await Task.sleep(for: tokenValidationInterval)
                    try Task.checkCancellation()
                    try await validateTwitchToken(login)
                }
            } catch is CancellationError { return }
            catch {
                guard token == owner, !Task.isCancelled else { return }
                validationFailed = true
                if case TwitchTokenValidation.Failure.rejected = error { tokenRejected = true }
                // A network failure also closes the session; reconnect validates
                // again before any authentication credentials are sent to IRC.
                connection.cancel()
            }
        }
        defer {
            timeout.cancel(); validation.cancel(); connection.cancel()
            if token == owner { twitchSocket = nil }
        }
        try await connection.send("PASS oauth:\(login.token)\r\n")
        try await connection.send("NICK \(login.username)\r\n")
        try await connection.send("CAP REQ :twitch.tv/tags twitch.tv/commands\r\n")
        var decoder = TwitchIRCDecoder()
        var joinedRequested = false
        while !Task.isCancelled, token == owner {
            let bytes: Data
            do { bytes = try await connection.receive() }
            catch {
                if tokenRejected { throw TwitchFailure.authentication }
                if validationFailed { throw TwitchFailure.reconnect }
                throw error
            }
            try Task.checkCancellation()
            guard token == owner else { return }
            for line in try decoder.append(bytes) {
                guard let packet = TwitchChatPacket.parse(line, channel: login.channel) else { continue }
                switch packet {
                case .ping(let payload): try await connection.send("PONG :\(payload)\r\n")
                case .authenticated:
                    if !joinedRequested {
                        joinedRequested = true
                        try await connection.send("JOIN #\(login.channel)\r\n")
                    }
                case .joined:
                    guard joinedRequested else { continue }
                    timeout.cancel(); isConnected = true
                    status = "Twitch chat · #\(login.channel)"
                case .authenticationFailed: throw TwitchFailure.authentication
                case .channelUnavailable, .capabilityRejected: throw TwitchFailure.unavailable
                case .reconnect: throw TwitchFailure.reconnect
                case .message(let message, let author):
                    guard isConnected else { continue }
                    if inbox.accept(message) {
                        twitchAuthors[message.id] = author
                        let retained = Set(inbox.messages.map(\.id))
                        twitchAuthors = twitchAuthors.filter { retained.contains($0.key) }
                        messages = inbox.messages
                    }
                case .clearMessage(let id):
                    inbox.removeMessages(ids: [id]); twitchAuthors.removeValue(forKey: id)
                    messages = inbox.messages
                case .clearUser(let author):
                    let ids = Set(twitchAuthors.filter { $0.value == author }.keys)
                    inbox.removeMessages(ids: ids)
                    twitchAuthors = twitchAuthors.filter { !ids.contains($0.key) }
                    messages = inbox.messages
                case .clearAll:
                    inbox.clearMessages(); twitchAuthors.removeAll(); messages = []
                }
                try Task.checkCancellation()
                guard token == owner else { return }
            }
        }
    }

    private enum TwitchFailure: Error { case authentication, unavailable, reconnect }

    private func resolve(_ channel: String) async throws -> Int64 {
        let url = URL(string: "https://kick.com/api/v2/channels/\(channel)")!
        let (bytes, response) = try await http.bytes(from: url)
        guard let response = response as? HTTPURLResponse else { throw ChatError.invalidResponse }
        if [401, 403, 404].contains(response.statusCode) { throw ChatError.denied(response.statusCode) }
        guard (200...299).contains(response.statusCode) else { throw ChatError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw ChatError.invalidResponse }
            data.append(byte)
        }
        struct Channel: Decodable {
            struct Room: Decodable { let id: Int64 }
            let chatroom: Room
        }
        let channel = try JSONDecoder().decode(Channel.self, from: data)
        guard channel.chatroom.id > 0 else { throw ChatError.invalidResponse }
        return channel.chatroom.id
    }

    private func run(room: Int64, channel: String, token: UUID) async throws {
        let subscription = "chatrooms.\(room).v2"
        // Same public Pusher application endpoint used by the Android app; not a private credential.
        let url = URL(string: "wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679?protocol=7&client=js&version=8.4.0&flash=false")!
        let connection = http.webSocketTask(with: url)
        socket = connection
        connection.maximumMessageSize = 65_536
        connection.resume()
        status = "Connecting chat · #\(channel)"
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            connection.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timeout.cancel()
            connection.cancel(with: .goingAway, reason: nil)
            if token == owner { socket = nil }
        }
        let request: [String: Any] = ["event": "pusher:subscribe", "data": ["auth": "", "channel": subscription]]
        let subscribe = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        try await connection.send(.string(subscribe))
        while !Task.isCancelled && token == owner {
            let frame = try await connection.receive()
            try Task.checkCancellation()
            guard token == owner else { return }
            let data: Data
            switch frame {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            switch KickPacket.parse(data, subscription: subscription) {
            case .ping:
                try await connection.send(.string(#"{"event":"pusher:pong","data":{}}"#))
            case .connected:
                timeout.cancel()
                isConnected = true
                status = "Kick chat · #\(channel)"
            case .subscriptionError:
                throw ChatError.invalidResponse
            case .message(let message):
                if inbox.accept(message) { messages = inbox.messages }
            case nil: break
            }
        }
    }

    private enum ChatError: Error { case denied(Int), invalidResponse }
}
