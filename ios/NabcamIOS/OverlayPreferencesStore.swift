import Foundation
import NabcamCore

/// App-owned files only. Actor isolation keeps bounded disk I/O off the UI actor.
actor OverlayPreferencesStore {
    private let directory: URL
    private var canWrite = false
    private var file: URL { directory.appendingPathComponent("overlays-v1.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GNABOverlays", isDirectory: true)
    }

    func load() throws -> OverlayPreferences {
        canWrite = false
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: OverlayArchive.maximumBytes + 1) ?? Data()
            let preferences = try OverlayArchive.decode(data)
            canWrite = true
            return preferences
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            canWrite = true
            return OverlayPreferences()
        } catch { throw StoreError.unavailable }
    }

    /// A structurally valid archive may still contain an undecodable image.
    func lockWrites() { canWrite = false }

    func save(_ preferences: OverlayPreferences) throws {
        guard canWrite else { throw StoreError.unavailable }
        do {
            let data = try OverlayArchive.encode(preferences)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
        } catch { throw StoreError.unavailable }
    }

    enum StoreError: Error { case unavailable }
}
