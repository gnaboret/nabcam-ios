import NabcamCore
import Security
import XCTest
@testable import NabcamStorageHost

@MainActor
final class BrowserOverlaySourcesTests: XCTestCase {
    private func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "sources-v1",
         kSecAttrSynchronizable as String: false]
    }

    func testThreeSourcesPersistPrivatelyAndRemovedSlotCanBeReused() throws {
        let service = "com.gnabcamirl.tests.browser.\(UUID().uuidString)"
        defer { SecItemDelete(query(service) as CFDictionary) }
        let store = BrowserOverlaySources(service: service)
        store.load()
        XCTAssertTrue(store.canWrite)
        XCTAssertEqual(store.sources.map(\.id), [1])
        XCTAssertEqual(store.add(), 2)
        XCTAssertEqual(store.add(), 3)
        XCTAssertNil(store.add())
        let source = BrowserOverlayConfiguration(id: 2, enabled: true, url: "https://example.com/widget?token=test-only")
        XCTAssertTrue(store.save(source))
        let reopened = BrowserOverlaySources(service: service)
        reopened.load()
        XCTAssertEqual(reopened.sources, store.sources)
        XCTAssertEqual(reopened.sources[1], source)
        XCTAssertFalse(reopened.remove(id: 1))
        XCTAssertTrue(reopened.remove(id: 2))
        XCTAssertEqual(reopened.add(), 2)
        XCTAssertEqual(reopened.sources.first { $0.id == 2 }?.url, "")
        var request = query(service)
        request[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(request as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertFalse(attributes[kSecAttrSynchronizable as String] as? Bool ?? false)
    }

    func testCorruptSavedSourcesAreNotOverwrittenOrExposedInErrors() {
        let service = "com.gnabcamirl.tests.browser.\(UUID().uuidString)"
        defer { SecItemDelete(query(service) as CFDictionary) }
        let original = Data("private-token-unreadable".utf8)
        var item = query(service)
        item[kSecValueData as String] = original
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        let store = BrowserOverlaySources(service: service)
        store.load()
        XCTAssertFalse(store.canWrite)
        XCTAssertTrue(store.sources.isEmpty)
        XCTAssertFalse(store.errorMessage?.contains("private-token") ?? true)
        XCTAssertNil(store.add())
        XCTAssertFalse(store.save(BrowserOverlayConfiguration(id: 1)))
        var request = query(service)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(request as CFDictionary, &result), errSecSuccess)
        XCTAssertEqual(result as? Data, original)
    }
}
