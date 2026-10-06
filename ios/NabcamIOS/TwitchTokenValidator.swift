import Foundation
import NabcamCore

private final class TokenNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

enum TwitchTokenValidator {
    static func validate(_ login: TwitchChatLogin) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: TokenNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
        request.setValue("OAuth \(login.token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 401 { throw TwitchTokenValidation.Failure.rejected }
        guard response.statusCode == 200, response.expectedContentLength <= 8192 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8192 else { throw TwitchTokenValidation.Failure.malformed }
            data.append(byte)
        }
        try TwitchTokenValidation.check(data, username: login.username)
    }
}
