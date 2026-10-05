import Foundation
import Combine
import Security
import NabcamCore

@MainActor
final class ConnectionProfiles: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published private(set) var canWrite = false
    @Published var errorMessage: String?
    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.gnabcamirl.app.connections",
        kSecAttrAccount as String: "profiles-v1",
        kSecAttrSynchronizable as String: false
    ]

    func load() {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        do {
            if status == errSecItemNotFound { profiles = [] }
            else {
                guard status == errSecSuccess, let data = result as? Data else { throw StorageError.unavailable }
                profiles = try ProfileArchive.decode(data)
            }
            canWrite = true
            errorMessage = nil
        } catch {
            canWrite = false
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult func save(_ profile: ConnectionProfile) -> Bool {
        var next = profiles
        if let index = next.firstIndex(where: { $0.id == profile.id }) { next[index] = profile }
        else { next.append(profile) }
        return persist(next)
    }

    @discardableResult func delete(id: UUID) -> Bool {
        persist(profiles.filter { $0.id != id })
    }

    private func persist(_ next: [ConnectionProfile]) -> Bool {
        guard canWrite else { errorMessage = StorageError.unavailable.localizedDescription; return false }
        do {
            let data = try ProfileArchive.encode(next)
            let update = [kSecValueData as String: data] as CFDictionary
            var status = SecItemUpdate(query as CFDictionary, update)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw StorageError.unavailable }
            profiles = next
            errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private enum StorageError: Error, LocalizedError {
        case unavailable
        var errorDescription: String? { "Unlock your iPhone and retry loading saved connections. Nothing was overwritten." }
    }
}
