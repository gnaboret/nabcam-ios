import XCTest
@testable import NabcamCore

final class OverlayArchiveTests: XCTestCase {
    func testRoundTripPreservesIdentityImagesAndClock() throws {
        let original = OverlayPreferences(watermarks: [SavedWatermark(data: Data([1, 2, 3]), corner: .bottomLeft, percent: 25)], clockEnabled: true, clockCorner: .topLeft)
        XCTAssertEqual(try OverlayArchive.decode(OverlayArchive.encode(original)), original)
    }
    func testRejectsDuplicateIDsTooManyImagesAndInvalidSizes() {
        let image = SavedWatermark(data: Data([1]))
        for marks in [[image, image], (0..<4).map { _ in SavedWatermark(data: Data([1])) },
                      [SavedWatermark(data: Data())], [SavedWatermark(data: Data([1]), percent: 41)],
                      [SavedWatermark(data: Data(repeating: 1, count: SavedWatermark.maximumBytes + 1))]] {
            XCTAssertThrowsError(try OverlayArchive.encode(OverlayPreferences(watermarks: marks)))
        }
    }
    func testRejectsCorruptUnknownAndOversizedArchives() throws {
        XCTAssertThrowsError(try OverlayArchive.decode(Data("not JSON".utf8)))
        let valid = try OverlayArchive.encode(OverlayPreferences())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["version"] = 2
        XCTAssertThrowsError(try OverlayArchive.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try OverlayArchive.decode(Data(repeating: 0, count: OverlayArchive.maximumBytes + 1)))
    }
    func testDecodeRevalidatesFields() throws {
        let preferences = OverlayPreferences(watermarks: [SavedWatermark(data: Data([1]))])
        let data = try OverlayArchive.encode(preferences)
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var fields = try XCTUnwrap(archive["preferences"] as? [String: Any])
        var images = try XCTUnwrap(fields["watermarks"] as? [[String: Any]])
        images[0]["percent"] = 0
        fields["watermarks"] = images
        archive["preferences"] = fields
        XCTAssertThrowsError(try OverlayArchive.decode(JSONSerialization.data(withJSONObject: archive)))
    }
}
