import Foundation

@MainActor
protocol TwitchChatSocket: AnyObject {
    func resume()
    func cancel()
    func send(_ line: String) async throws
    func receive() async throws -> Data
}

private final class TwitchNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Fixed TLS endpoint, no redirects, cookies, caching, custom trust or logs.
@MainActor
final class NativeTwitchChatSocket: TwitchChatSocket {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration, delegate: TwitchNoRedirects(), delegateQueue: nil)
        socket = session.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
        socket.maximumMessageSize = 65_536
    }
    func resume() { socket.resume() }
    func cancel() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
    func send(_ line: String) async throws { try await socket.send(.string(line)) }
    func receive() async throws -> Data {
        switch try await socket.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: throw URLError(.cannotParseResponse)
        }
    }
}
