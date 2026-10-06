import Combine
import Foundation
import Security
import NabcamCore

@MainActor
final class TwitchLoginStore: ObservableObject {
    @Published private(set) var login: TwitchChatLogin?
    @Published private(set) var canWrite = false
    @Published private(set) var errorMessage: String?
    private let query: [String: Any]

    init(service: String = "com.gnabcamirl.app.twitch-chat") {
        query = [kSecClass as String: kSecClassGenericPassword,
                 kSecAttrService as String: service, kSecAttrAccount as String: "login-v1",
                 kSecAttrSynchronizable as String: false]
    }

    func load() {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        do {
            if status == errSecItemNotFound { login = nil }
            else {
                guard status == errSecSuccess, let data = result as? Data else { throw Failure.unavailable }
                login = try TwitchLoginArchive.decode(data)
            }
            canWrite = true; errorMessage = nil
        } catch {
            canWrite = false
            errorMessage = "Unlock this device and retry loading Twitch login. Nothing was overwritten."
        }
    }

    @discardableResult func save(_ next: TwitchChatLogin) -> Bool {
        guard canWrite else { return false }
        do {
            let data = try TwitchLoginArchive.encode(next)
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw Failure.unavailable }
            login = next; errorMessage = nil
            return true
        } catch { errorMessage = "Could not save Twitch login. Unlock this device and retry."; return false }
    }

    @discardableResult func forget() -> Bool {
        guard canWrite else { return false }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            errorMessage = "Could not remove Twitch login. Unlock this device and retry."
            return false
        }
        login = nil; errorMessage = nil
        return true
    }
    private enum Failure: Error { case unavailable }
}
