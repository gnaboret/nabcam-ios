import XCTest
import NabcamCore
@testable import NabcamStorageHost

@MainActor
final class OverlayStoreTests: XCTestCase {
    func testSaveReopenUpdateAndRemoveImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OverlayPreferencesStore(directory: directory)
        let empty = try await store.load()
        XCTAssertEqual(empty, OverlayPreferences())
        let preferences = OverlayPreferences(watermarks: [SavedWatermark(data: Data([1, 2, 3]), corner: .bottomLeft, percent: 15)], clockEnabled: true, clockCorner: .topLeft)
        try await store.save(preferences)
        let reopened = OverlayPreferencesStore(directory: directory)
        let saved = try await reopened.load()
        XCTAssertEqual(saved, preferences)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        try await reopened.save(OverlayPreferences(clockEnabled: true))
        let removed = try await store.load()
        XCTAssertTrue(removed.watermarks.isEmpty)
        XCTAssertTrue(removed.clockEnabled)
    }

    func testCorruptArchiveAndLockedWritesPreserveOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("overlays-v1.json")
        let original = Data("corrupt existing settings".utf8)
        try original.write(to: file)
        let store = OverlayPreferencesStore(directory: directory)
        do { _ = try await store.load(); XCTFail("Corrupt archive accepted") } catch { }
        do { try await store.save(OverlayPreferences()); XCTFail("Corrupt archive overwritten") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), original)
        // A structurally valid archive can still fail image decoding in the model.
        try OverlayArchive.encode(OverlayPreferences()).write(to: file)
        _ = try await store.load()
        await store.lockWrites()
        do { try await store.save(OverlayPreferences(clockEnabled: true)); XCTFail("Write lock ignored") } catch { }
        XCTAssertEqual(try OverlayArchive.decode(Data(contentsOf: file)), OverlayPreferences())
    }
}
