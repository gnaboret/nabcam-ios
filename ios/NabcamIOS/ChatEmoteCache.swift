import Combine
import Foundation
import ImageIO
import UIKit
import NabcamCore

private final class EmoteRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(ChatEmoteCache.allowedURL) == true ? request : nil)
    }
}

/// At most 32 small static emotes, fetched serially. No cookies, persistent cache,
/// arbitrary image hosts, or chat history on disk. Missing images use text names.
@MainActor
final class ChatEmoteCache: ObservableObject {
    @Published private(set) var images: [URL: UIImage] = [:]
    private var wanted: [URL] = []
    private var failed: Set<URL> = []
    private var worker: Task<Void, Never>?
    private var generation = 0
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration, delegate: EmoteRedirectPolicy(), delegateQueue: nil)
    }

    nonisolated static func allowedURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "files.kick.com" && url.port == nil &&
        url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
        url.path.range(of: "^/emotes/[0-9]{1,20}/fullsize$", options: .regularExpression) != nil
    }

    func update(messages: [ChatMessage]) {
        var urls: [URL] = []
        for message in messages.suffix(8).reversed() {
            for fragment in message.fragments {
                if case .emote(_, let url) = fragment, Self.allowedURL(url), !urls.contains(url), urls.count < 32 {
                    urls.append(url)
                }
            }
        }
        wanted = urls
        let keep = Set(urls)
        if images.keys.contains(where: { !keep.contains($0) }) {
            images = images.filter { keep.contains($0.key) }
        }
        failed.formIntersection(keep)
        guard worker == nil, wanted.contains(where: { images[$0] == nil && !failed.contains($0) }) else { return }
        let owner = generation
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if generation == owner { worker = nil } }
            while !Task.isCancelled, generation == owner,
                  let url = wanted.first(where: { images[$0] == nil && !failed.contains($0) }) {
                do {
                    let (bytes, response) = try await session.bytes(from: url)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                          http.url.map(Self.allowedURL) == true,
                          http.mimeType?.hasPrefix("image/") == true,
                          http.expectedContentLength <= 1_048_576 else { throw Failure.invalid }
                    var data = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard data.count < 1_048_576 else { throw Failure.invalid }
                        data.append(byte)
                    }
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 64,
                            kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary) else { throw Failure.invalid }
                    guard !Task.isCancelled, generation == owner else { return }
                    if wanted.contains(url) { images[url] = UIImage(cgImage: image) }
                } catch {
                    guard !Task.isCancelled, generation == owner else { return }
                    if wanted.contains(url) { failed.insert(url) }
                }
            }
        }
    }

    func stop() {
        generation += 1
        worker?.cancel(); worker = nil
        wanted = []; images = [:]; failed = []
    }

    deinit { worker?.cancel(); session.invalidateAndCancel() }
    private enum Failure: Error { case invalid }
}
