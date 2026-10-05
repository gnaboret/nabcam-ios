import Combine
import Foundation
import NabcamCore

@MainActor
final class KickChatService: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var status = "Chat off"
    @Published private(set) var isEnabled = false
    @Published private(set) var isConnected = false
    private let http: URLSession
    private var owner = UUID()
    private var worker: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var inbox = ChatInbox()

    init() {
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
        isConnected = false
        isEnabled = false
        status = "Chat off"
    }

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
