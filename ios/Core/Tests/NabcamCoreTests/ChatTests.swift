import XCTest
@testable import NabcamCore

final class ChatTests: XCTestCase {
    private func packet(payload: Any, channel: String = "chatrooms.123.v2") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["event": "App\\Events\\ChatMessageEvent", "channel": channel, "data": payload])
    }
    private let payload: [String: Any] = ["id": "m1", "content": "Hi 😀 [emote:123:Kappa]!", "sender": ["username": "Viewer", "identity": ["color": "#ABCDEF", "badges": [["type": "moderator"], ["type": "subscriber"]]]]]

    func testObjectAndEncodedPayloadProduceSameMessage() throws {
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let first = KickPacket.parse(try packet(payload: payload), subscription: "chatrooms.123.v2")
        XCTAssertEqual(first, KickPacket.parse(try packet(payload: encoded), subscription: "chatrooms.123.v2"))
        guard case .message(let message) = first else { return XCTFail("Missing message") }
        XCTAssertEqual(message.badges, ["MOD", "SUB"])
        XCTAssertEqual(message.colorHex, "#ABCDEF")
        XCTAssertEqual(message.spokenText, "Hi 😀  !")
        XCTAssertEqual(message.fragments, [.text("Hi 😀 "), .emote(name: "Kappa", url: URL(string: "https://files.kick.com/emotes/123/fullsize")!), .text("!")])
    }
    func testOtherRoomsAndBadPacketsAreIgnored() throws {
        XCTAssertNil(KickPacket.parse(try packet(payload: payload, channel: "chatrooms.999.v2"), subscription: "chatrooms.123.v2"))
        XCTAssertNil(KickPacket.parse(Data("invalid".utf8), subscription: "room"))
        XCTAssertNil(KickPacket.parse(Data(repeating: 32, count: 65_537), subscription: "room"))
    }
    func testUnsafeEmoteIDIsPlainText() {
        let text = "[emote:../../evil:bad]"
        XCTAssertEqual(ChatFragment.kick(text), [.text(text)])
    }
    func testUsernameColorsAreStableAndRolesNotInvented() {
        XCTAssertEqual(ChatAppearance.color(sender: "Viewer", supplied: nil), ChatAppearance.color(sender: "viewer", supplied: "broken"))
        XCTAssertEqual(ChatAppearance.badges(["moderator", "unknown", "moderator"]), ["MOD"])
        XCTAssertTrue(ChatAppearance.badges([]).isEmpty)
    }
    func testHistoryAndDedupAreBounded() {
        var inbox = ChatInbox()
        let message = ChatMessage(id: "one", sender: "viewer", text: "Hello", color: nil, badgeTypes: [])
        XCTAssertTrue(inbox.accept(message))
        XCTAssertFalse(inbox.accept(message))
        for index in 0..<400 { inbox.accept(ChatMessage(id: "\(index)", sender: "v", text: "hi", color: nil, badgeTypes: [])) }
        XCTAssertEqual(inbox.messages.count, 30)
        XCTAssertEqual(inbox.messages.last?.id, "399")
        XCTAssertTrue(inbox.accept(message))
    }
}
