import XCTest
import Security
import NabcamCore
@testable import NabcamStorageHost

@MainActor
final class TwitchLoginStoreTests: XCTestCase {
    func testKeychainRoundTripUpdateAndForget() throws {
        let service = "com.gnabcamirl.tests.twitch.\(UUID().uuidString)"
        let store = TwitchLoginStore(service: service)
        let login = try TwitchChatLogin(channel: "room", username: "viewer", token: "synthetic-only")
        XCTAssertFalse(store.save(login), "Must successfully load before writing")
        store.load()
        XCTAssertTrue(store.canWrite)
        XCTAssertTrue(store.save(login))
        defer { _ = store.forget() }
        let restored = TwitchLoginStore(service: service)
        restored.load()
        XCTAssertEqual(restored.login, login)
        let replacement = try TwitchChatLogin(channel: "other", username: "viewer", token: "synthetic-replacement")
        XCTAssertTrue(restored.save(replacement))
        store.load()
        XCTAssertEqual(store.login, replacement)
        XCTAssertTrue(restored.forget())
        store.load()
        XCTAssertNil(store.login)
    }

    func testMalformedStoredValueIsNotOverwritten() throws {
        let service = "com.gnabcamirl.tests.twitch.\(UUID().uuidString)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "login-v1",
            kSecAttrSynchronizable as String: false]
        var item = query
        let original = Data("invalid archive".utf8)
        item[kSecValueData as String] = original
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        defer { SecItemDelete(query as CFDictionary) }
        let store = TwitchLoginStore(service: service)
        store.load()
        XCTAssertFalse(store.canWrite)
        XCTAssertFalse(store.save(try TwitchChatLogin(channel: "room", username: "viewer", token: "synthetic")))
        XCTAssertFalse(store.forget())
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(lookup as CFDictionary, &result), errSecSuccess)
        XCTAssertEqual(result as? Data, original)
    }
}
