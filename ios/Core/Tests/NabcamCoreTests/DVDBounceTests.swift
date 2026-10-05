import Foundation
import XCTest
@testable import NabcamCore

final class DVDBounceTests: XCTestCase {
    func testMovementAndReflectionMatchAndroidGeometry() {
        func point(_ time: Double) -> DVDBounce {
            DVDBounce(width: 1280, height: 720, objectWidth: 256, objectHeight: 144, elapsedSeconds: time)
        }
        XCTAssertEqual(point(0).x, 24)
        XCTAssertEqual(point(0).y, 24)
        XCTAssertEqual(point(1).x, 96, accuracy: 0.0001)
        XCTAssertEqual(point(1).y, 78, accuracy: 0.0001)
        let rightEdgeTime = (1280.0 - 256 - 48) / 72
        XCTAssertEqual(point(rightEdgeTime).x, 1000, accuracy: 0.0001)
        XCTAssertEqual(point(rightEdgeTime + 1).x, 928, accuracy: 0.0001)
        XCTAssertEqual(point(rightEdgeTime * 2).x, 24, accuracy: 0.0001)
    }

    func testLongRunsStayInsideBoundsWithoutFrameCountDependency() {
        for time in [0.0, 0.1, 1, 17, 1024, 86400, 1e12, Double.greatestFiniteMagnitude] {
            let point = DVDBounce(width: 1920, height: 1080, objectWidth: 300, objectHeight: 200, elapsedSeconds: time)
            XCTAssertTrue((24...1596).contains(point.x))
            XCTAssertTrue((24...856).contains(point.y))
        }
    }

    func testOversizeAndInvalidInputsRemainFinite() {
        let oversized = DVDBounce(width: 100, height: 100, objectWidth: 120, objectHeight: 99, elapsedSeconds: 3)
        XCTAssertEqual(oversized.x, 0)
        XCTAssertEqual(oversized.y, 0.5)
        let invalid = DVDBounce(width: .nan, height: 100, objectWidth: 10, objectHeight: 10, elapsedSeconds: .infinity)
        XCTAssertEqual(invalid.x, 0)
        XCTAssertEqual(invalid.y, 0)
    }

    func testAnimationPreferenceAndLegacyStaticImagesRoundTrip() throws {
        let image = Data([1, 2, 3]) // Archive validates bounds; native layer validates image decoding.
        for dvd in [nil, false, true] as [Bool?] {
            let settings = OverlayPreferences(watermarks: [SavedWatermark(data: image, dvd: dvd)])
            let bytes = try OverlayArchive.encode(settings)
            let restored = try OverlayArchive.decode(bytes)
            XCTAssertEqual(restored, settings)
            XCTAssertEqual(restored.watermarks.first?.dvd == true, dvd == true)
            if dvd == nil { XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("dvd")) }
        }
    }
}
