import XCTest
import NabcamCore
@testable import NabcamStorageHost

@MainActor
private final class FakeTwitchSocket: TwitchChatSocket {
    private var frames: [Data] = []
    private var pending: CheckedContinuation<Data, Error>?
    private(set) var sent: [String] = []
    private(set) var canceled = false
    func resume() {}
    func cancel() {
        canceled = true
        pending?.resume(throwing: CancellationError()); pending = nil
    }
    func send(_ line: String) async throws {
        if canceled { throw CancellationError() }
        sent.append(line)
    }
    func receive() async throws -> Data {
        if canceled { throw CancellationError() }
        if !frames.isEmpty { return frames.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func feed(_ text: String) {
        guard !canceled else { return }
        let data = Data(text.utf8)
        if let waiter = pending { pending = nil; waiter.resume(returning: data) }
        else { frames.append(data) }
    }
}

@MainActor
final class TwitchChatServiceTests: XCTestCase {
    private func until(_ predicate: () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Expected asynchronous chat state did not arrive")
    }
    private func login() throws -> TwitchChatLogin {
        try TwitchChatLogin(channel: "room", username: "viewer", token: "synthetic-only")
    }

    func testHandshakePingMessageAndModeration() async throws {
        let socket = FakeTwitchSocket()
        let service = StreamChatService(makeTwitchSocket: { socket })
        service.connectTwitch(try login())
        defer { service.disconnect() }
        await until { socket.sent.count == 3 }
        XCTAssertEqual(socket.sent, ["PASS oauth:synthetic-only\r\n", "NICK viewer\r\n", "CAP REQ :twitch.tv/tags twitch.tv/commands\r\n"])
        XCTAssertFalse(service.isConnected)
        socket.feed("PING :tmi.twitch.tv\r\n:server 001 viewer :Welcome\r\n:server ROOMSTATE #room\r\n@id=one;display-name=Alice :alice!a@h PRIVMSG #room :hello\r\n")
        await until { service.messages.count == 1 }
        XCTAssertTrue(service.isConnected)
        XCTAssertTrue(socket.sent.contains("PONG :tmi.twitch.tv\r\n"))
        XCTAssertTrue(socket.sent.contains("JOIN #room\r\n"))
        socket.feed("@target-msg-id=one :server CLEARMSG #room :hello\r\n@id=one :alice!a@h PRIVMSG #room :hello\r\n")
        await until { service.messages.isEmpty }
        socket.feed("@id=two :alice!a@h PRIVMSG #room :new\r\n@id=three :bob!b@h PRIVMSG #room :other\r\n")
        await until { service.messages.count == 2 }
        socket.feed(":server CLEARCHAT #room :alice\r\n")
        await until { service.messages.count == 1 }
        XCTAssertEqual(service.messages.first?.sender, "bob")
        socket.feed(":server CLEARCHAT #room\r\n")
        await until { service.messages.isEmpty }
    }

    func testRejectedLoginStopsAndDoesNotExposeToken() async throws {
        let socket = FakeTwitchSocket()
        let service = StreamChatService(makeTwitchSocket: { socket })
        service.connectTwitch(try login())
        await until { socket.sent.count == 3 }
        socket.feed(":server NOTICE * :Login authentication failed\r\n")
        await until { !service.isEnabled }
        XCTAssertFalse(service.isConnected)
        XCTAssertTrue(socket.canceled)
        XCTAssertFalse(service.status.contains("synthetic-only"))
        XCTAssertEqual(service.messages.count, 0)
        service.disconnect()
    }

    func testDisconnectCancelsPendingReceiveAndNewConnectionOwnsState() async throws {
        let first = FakeTwitchSocket(), second = FakeTwitchSocket()
        var count = 0
        let service = StreamChatService(makeTwitchSocket: {
            count += 1
            return count == 1 ? first : second
        })
        service.connectTwitch(try login())
        await until { first.sent.count == 3 }
        service.disconnect()
        XCTAssertTrue(first.canceled)
        service.connectTwitch(try login())
        defer { service.disconnect() }
        await until { second.sent.count == 3 }
        first.feed(":server NOTICE * :Login authentication failed\r\n")
        second.feed(":server 001 viewer :Welcome\r\n:server ROOMSTATE #room\r\n")
        await until { service.isConnected }
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(service.status, "Twitch chat · #room")
    }
}
