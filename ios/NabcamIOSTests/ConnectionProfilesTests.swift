import XCTest
import Security
import NabcamCore
@testable import NabcamStorageHost

final class ConnectionProfilesTests: XCTestCase {
    private func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "profiles-v1",
         kSecAttrSynchronizable as String: false]
    }

    @MainActor
    func testSaveReopenUpdateDelete() throws {
        let service = "com.gnabcamirl.tests.\(UUID().uuidString)"
        defer { SecItemDelete(query(service) as CFDictionary) }
        let first = ConnectionProfiles(service: service)
        first.load()
        XCTAssertTrue(first.canWrite)
        var profile = try ConnectionProfile(name: "Test receiver", destination: "srt://example.com:9000?passphrase=example-test-only", bitrateKbps: 1600)
        XCTAssertTrue(first.save(profile))
        let reopened = ConnectionProfiles(service: service)
        reopened.load()
        XCTAssertEqual(reopened.profiles, [profile])
        profile.bitrateKbps = 2500
        XCTAssertTrue(reopened.save(profile))
        first.load()
        XCTAssertEqual(first.profiles, [profile])
        XCTAssertTrue(first.delete(id: profile.id))
        reopened.load()
        XCTAssertEqual(reopened.profiles, [])
    }

    @MainActor
    func testDeviceOnlyAccessibilityAndNoSync() throws {
        let service = "com.gnabcamirl.tests.\(UUID().uuidString)"
        defer { SecItemDelete(query(service) as CFDictionary) }
        let store = ConnectionProfiles(service: service)
        store.load()
        XCTAssertTrue(store.save(try ConnectionProfile(name: "Test", destination: "rtmps://example.com/live/test", bitrateKbps: 1600)))
        var request = query(service)
        request[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(request as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertFalse(attributes[kSecAttrSynchronizable as String] as? Bool ?? false)
    }

    @MainActor
    func testUnreadableArchiveCannotBeOverwritten() throws {
        let service = "com.gnabcamirl.tests.\(UUID().uuidString)"
        defer { SecItemDelete(query(service) as CFDictionary) }
        let original = Data("unreadable archive".utf8)
        var item = query(service)
        item[kSecValueData as String] = original
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        let store = ConnectionProfiles(service: service)
        store.load()
        XCTAssertFalse(store.canWrite)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.save(try ConnectionProfile(name: "New", destination: "rtmps://example.com/live/test", bitrateKbps: 1600)))
        var request = query(service)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(request as CFDictionary, &result), errSecSuccess)
        XCTAssertEqual(result as? Data, original)
    }
}
