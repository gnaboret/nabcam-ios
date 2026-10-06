import XCTest
import Combine
@testable import NabcamStorageHost

@MainActor
final class ChatEmoteCacheTests: XCTestCase {
    func testOnlyBoundedProviderEmoteURLsAreAccepted() throws {
        XCTAssertTrue(ChatEmoteCache.allowedURL(try XCTUnwrap(URL(string: "https://files.kick.com/emotes/123/fullsize"))))
        XCTAssertTrue(ChatEmoteCache.allowedURL(try XCTUnwrap(URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/emotesv2_abc/static/dark/2.0"))))
        for text in ["http://files.kick.com/emotes/123/fullsize",
                     "https://example.com/emotes/123/fullsize",
                     "https://files.kick.com:443/emotes/123/fullsize",
                     "https://user@files.kick.com/emotes/123/fullsize",
                     "https://files.kick.com/emotes/123/fullsize?token=private",
                     "https://files.kick.com/emotes/123/fullsize#fragment",
                     "https://files.kick.com/emotes/abc/fullsize",
                     "https://files.kick.com/emotes/123456789012345678901/fullsize",
                     "https://files.kick.com/other",
                     "https://static-cdn.jtvnw.net/emoticons/v2/25/default/dark/2.0",
                     "https://static-cdn.jtvnw.net/emoticons/v2/25/static/dark/2.0?token=private",
                     "https://static-cdn.jtvnw.net/other",
                     "https://static-cdn.jtvnw.net.evil.test/emoticons/v2/25/static/dark/2.0"] {
            XCTAssertFalse(ChatEmoteCache.allowedURL(try XCTUnwrap(URL(string: text))), text)
        }
    }

    func testEmptyCacheStopIsIdempotent() {
        let cache = ChatEmoteCache()
        var changes = 0
        let observation = cache.$images.dropFirst().sink { _ in changes += 1 }
        cache.update(messages: [])
        cache.stop()
        cache.stop()
        XCTAssertTrue(cache.images.isEmpty)
        XCTAssertEqual(changes, 0, "Idle chat must not repeatedly invalidate the preview")
        withExtendedLifetime(observation) { }
    }
}
