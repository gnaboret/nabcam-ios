import XCTest
@testable import NabcamCore

final class TwitchChatTests: XCTestCase {
    func testPartialAndMultipleLinesIncludingSplitUnicode() throws {
        var decoder = TwitchIRCDecoder()
        let data = Data("PING :tmi.twitch.tv\r\n:viewer PRIVMSG #room :😀\r\n".utf8)
        let cut = data.count - 4 // split the emoji's UTF-8 bytes
        XCTAssertEqual(try decoder.append(data.prefix(cut)), ["PING :tmi.twitch.tv"])
        XCTAssertEqual(try decoder.append(data.suffix(from: cut)), [":viewer PRIVMSG #room :😀"])
    }
    func testBoundsAndInvalidUTF8ResetDecoder() throws {
        var decoder = TwitchIRCDecoder()
        XCTAssertThrowsError(try decoder.append(Data(repeating: 65, count: 16_385)))
        XCTAssertThrowsError(try decoder.append(Data([255, 13, 10])))
        XCTAssertEqual(try decoder.append(Data("PING :ok\r\n".utf8)), ["PING :ok"])
        XCTAssertThrowsError(try decoder.append(Data(repeating: 65, count: 65_537)))
    }
    func testMetadataEmotesAndDeduplication() throws {
        let line = "@id=abc;display-name=Viewer;badges=moderator/1,subscriber/3;color=#ABCDEF;emotes=25:2-6 :viewer!viewer@host PRIVMSG #room :😀 Kappa hi"
        guard case .message(let message, let login) = TwitchChatPacket.parse(line, channel: "room") else { return XCTFail("Missing message") }
        XCTAssertEqual(login, "viewer")
        XCTAssertEqual(message.id, "twitch:abc")
        XCTAssertEqual(message.badges, ["MOD", "SUB"])
        XCTAssertEqual(message.colorHex, "#ABCDEF")
        XCTAssertEqual(message.fragments, [.text("😀 "), .emote(name: "Kappa", url: URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/25/static/dark/2.0")!), .text(" hi")])
        var inbox = ChatInbox()
        XCTAssertTrue(inbox.accept(message)); XCTAssertFalse(inbox.accept(message))
    }
    func testActionsAndScalarOffsetsAfterCombiningCharacters() {
        let line = "@emotes=25:3-7 :viewer!v@h PRIVMSG #room :\u{1}ACTION e\u{301} Kappa\u{1}"
        guard case .message(let message, _) = TwitchChatPacket.parse(line, channel: "room") else { return XCTFail() }
        XCTAssertEqual(message.text, "e\u{301} Kappa")
        XCTAssertEqual(message.fragments.first, .text("e\u{301} "))
        XCTAssertEqual(message.spokenText, "e\u{301}")
    }
    func testPlainTwitchTextIsNotParsedAsKickEmotes() {
        let text = "[emote:25:Kappa]"
        guard case .message(let message, _) = TwitchChatPacket.parse(":viewer!v@h PRIVMSG #room :\(text)", channel: "room") else { return XCTFail() }
        XCTAssertEqual(message.fragments, [.text(text)])
    }
    func testControlEventsAndChannelIsolation() {
        XCTAssertEqual(TwitchChatPacket.parse("PING :tmi.twitch.tv", channel: "room"), .ping("tmi.twitch.tv"))
        XCTAssertEqual(TwitchChatPacket.parse(":server 001 viewer :Welcome", channel: "room"), .authenticated)
        XCTAssertEqual(TwitchChatPacket.parse(":server ROOMSTATE #room", channel: "room"), .joined)
        XCTAssertEqual(TwitchChatPacket.parse(":server RECONNECT", channel: "room"), .reconnect)
        XCTAssertEqual(TwitchChatPacket.parse(":server NOTICE * :Login authentication failed", channel: "room"), .authenticationFailed)
        XCTAssertEqual(TwitchChatPacket.parse(":server CAP * NAK :twitch.tv/tags", channel: "room"), .capabilityRejected)
        XCTAssertNil(TwitchChatPacket.parse(":v!v@h PRIVMSG #other :hello", channel: "room"))
        XCTAssertNil(TwitchChatPacket.parse("PING :bad\r\nJOIN #other", channel: "room"))
        XCTAssertNil(TwitchChatPacket.parse("PING :ok", channel: "room\r\n"))
    }
    func testModerationEvents() {
        XCTAssertEqual(TwitchChatPacket.parse("@target-msg-id=m1 :server CLEARMSG #room :text", channel: "room"), .clearMessage("twitch:m1"))
        XCTAssertEqual(TwitchChatPacket.parse(":server CLEARCHAT #room :viewer", channel: "room"), .clearUser("viewer"))
        XCTAssertEqual(TwitchChatPacket.parse(":server CLEARCHAT #room", channel: "room"), .clearAll)
        XCTAssertNil(TwitchChatPacket.parse(":server CLEARCHAT #other", channel: "room"))
        XCTAssertNil(TwitchChatPacket.parse(":server CLEARMSG #room :text", channel: "room"))
    }
    func testEscapesAndMalformedEmoteRanges() {
        XCTAssertEqual(TwitchChatPacket.decodeTag(#"One\sTwo\:Three\\Four\nX"#), "One Two;Three\\Four X")
        let text = "Kappa hi"
        XCTAssertEqual(ChatFragment.twitch(text, tags: "../:0-4/25:-1-4,0-999,999999999999999999999-4"), [.text(text)])
        let valid = ChatFragment.twitch(text, tags: "25:0-4/26:0-4,2-5")
        XCTAssertEqual(valid.count, 2)
        XCTAssertEqual(valid.last, .text(" hi"))
    }
    func testDisplayBoundsAndInvalidColors() {
        let text = String(repeating: "a", count: 400)
        guard case .message(let message, _) = TwitchChatPacket.parse("@display-name=;color=notacolor :viewer!v@h PRIVMSG #room :\(text)", channel: "room") else { return XCTFail() }
        XCTAssertEqual(message.sender, "viewer")
        XCTAssertEqual(message.text.count, 300)
        XCTAssertEqual(message.colorHex, ChatAppearance.color(sender: "viewer", supplied: nil))
    }
}
