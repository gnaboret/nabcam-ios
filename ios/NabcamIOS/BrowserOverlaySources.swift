import Combine
import Foundation
import NabcamCore
import Security

@MainActor
final class BrowserOverlaySources: ObservableObject {
    @Published private(set) var sources: [BrowserOverlayConfiguration] = []
    @Published private(set) var canWrite = false
    @Published private(set) var errorMessage: String?
    private let query: [String: Any]

    init(service: String = "com.gnabcamirl.app.browser-overlays") {
        query = [kSecClass as String: kSecClassGenericPassword,
                 kSecAttrService as String: service,
                 kSecAttrAccount as String: "sources-v1",
                 kSecAttrSynchronizable as String: false]
    }

    func load() {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        do {
            if status == errSecItemNotFound {
                sources = [BrowserOverlayConfiguration(id: 1)]
            } else {
                guard status == errSecSuccess, let data = result as? Data else { throw Failure.unavailable }
                sources = try BrowserOverlayArchive.decode(data)
            }
            canWrite = true
            errorMessage = nil
        } catch {
            sources = []
            canWrite = false
            errorMessage = "Saved browser sources could not be read. Unlock the device and retry. Nothing was overwritten."
        }
    }

    @discardableResult func save(_ source: BrowserOverlayConfiguration) -> Bool {
        var next = sources
        if let index = next.firstIndex(where: { $0.id == source.id }) { next[index] = source }
        else { next.append(source) }
        return persist(next.sorted { $0.id < $1.id })
    }

    func add() -> Int? {
        guard let id = (1...BrowserOverlayConfiguration.maximumSources).first(where: { id in !sources.contains { $0.id == id } }),
              save(BrowserOverlayConfiguration(id: id)) else { return nil }
        return id
    }

    @discardableResult func remove(id: Int) -> Bool {
        guard id != 1 else { return false } // The first source can be disabled.
        return persist(sources.filter { $0.id != id })
    }

    private func persist(_ next: [BrowserOverlayConfiguration]) -> Bool {
        guard canWrite else { return false }
        do {
            let data = try BrowserOverlayArchive.encode(next)
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw Failure.unavailable }
            sources = next
            errorMessage = nil
            return true
        } catch {
            // Never include an NSError or decoding description containing a URL.
            errorMessage = "Could not save browser sources. Check the HTTPS URL and settings, then retry."
            return false
        }
    }

    private enum Failure: Error { case unavailable }
}
