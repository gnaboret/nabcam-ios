import XCTest
@testable import NabcamCore

final class TwitchLoginTests: XCTestCase {
    func testNormalizationAndRoundTrip() throws {
        let login = try TwitchChatLogin(channel: " #Room ", username: " Viewer ", token: "oauth:synthetic-test-token")
        XCTAssertEqual(login.channel, "room")
        XCTAssertEqual(login.username, "viewer")
        XCTAssertEqual(login.token, "synthetic-test-token")
        XCTAssertEqual(try TwitchLoginArchive.decode(TwitchLoginArchive.encode(login)), login)
    }
    func testRejectsIRCInjectionAndInvalidCredentials() {
        for token in ["", "oauth:", "fake\r\nJOIN #other", "fake token", "😀", String(repeating: "x", count: 2049)] {
            XCTAssertThrowsError(try TwitchChatLogin(channel: "room", username: "viewer", token: token))
        }
        for channel in ["", "room\r\nJOIN", "https://twitch.tv/room", String(repeating: "x", count: 26)] {
            XCTAssertThrowsError(try TwitchChatLogin(channel: channel, username: "viewer", token: "synthetic"))
        }
    }
    func testInvalidArchiveAndFutureVersionCannotLoad() {
        XCTAssertThrowsError(try TwitchLoginArchive.decode(Data(repeating: 32, count: 8193)))
        XCTAssertThrowsError(try TwitchLoginArchive.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try TwitchLoginArchive.decode(Data(#"{"version":2,"channel":"room","username":"viewer","token":"synthetic"}"#.utf8)))
    }
}
