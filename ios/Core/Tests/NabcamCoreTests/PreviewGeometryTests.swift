import XCTest
@testable import NabcamCore

final class PreviewGeometryTests: XCTestCase {
    func testLandscapeVideoLetterboxesInsideTablet() throws {
        let frame = try XCTUnwrap(VideoFrameSize(width: 1280, height: 720))
        let rect = try XCTUnwrap(PreviewGeometry.fittedRectangle(frame: frame, width: 1024, height: 768))
        XCTAssertEqual(rect.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.y, 96, accuracy: 0.001)
        XCTAssertEqual(rect.width, 1024, accuracy: 0.001)
        XCTAssertEqual(rect.height, 576, accuracy: 0.001)
        XCTAssertEqual(frame.label, "1280×720")
    }

    func testWidePhonePillarboxesAndPortraitFrameIsNotAssumedLandscape() throws {
        let landscape = try XCTUnwrap(VideoFrameSize(width: 1920, height: 1080))
        let phone = try XCTUnwrap(PreviewGeometry.fittedRectangle(frame: landscape, width: 900, height: 400))
        XCTAssertEqual(phone.height, 400, accuracy: 0.001)
        XCTAssertEqual(phone.width, 400 * 16 / 9, accuracy: 0.001)
        XCTAssertEqual(phone.x, (900 - phone.width) / 2, accuracy: 0.001)
        XCTAssertEqual(phone.y, 0, accuracy: 0.001)
        let portrait = try XCTUnwrap(VideoFrameSize(width: 360, height: 640))
        let rect = try XCTUnwrap(PreviewGeometry.fittedRectangle(frame: portrait, width: 1000, height: 800))
        XCTAssertEqual(rect.width, 450, accuracy: 0.001)
        XCTAssertEqual(rect.height, 800, accuracy: 0.001)
        XCTAssertEqual(rect.x, 275, accuracy: 0.001)
    }

    func testInvalidSizesNeverProduceDrawingCoordinates() throws {
        XCTAssertNil(VideoFrameSize(width: 0, height: 720))
        XCTAssertNil(VideoFrameSize(width: 1280, height: -1))
        let frame = try XCTUnwrap(VideoFrameSize(width: 1280, height: 720))
        for invalid in [0, -1, Double.infinity, -Double.infinity, Double.nan] {
            XCTAssertNil(PreviewGeometry.fittedRectangle(frame: frame, width: invalid, height: 800))
            XCTAssertNil(PreviewGeometry.fittedRectangle(frame: frame, width: 1000, height: invalid))
        }
    }

    func testMatchingAspectFillsExactlyAndGridDivisionsStayInsidePicture() throws {
        let frame = try XCTUnwrap(VideoFrameSize(width: 1280, height: 720))
        let rect = try XCTUnwrap(PreviewGeometry.fittedRectangle(frame: frame, width: 640, height: 360))
        XCTAssertEqual(rect.x, 0)
        XCTAssertEqual(rect.y, 0)
        XCTAssertEqual(rect.width, 640)
        XCTAssertEqual(rect.height, 360)
        for third in [1.0 / 3, 2.0 / 3] {
            XCTAssertTrue((rect.x...(rect.x + rect.width)).contains(rect.x + rect.width * third))
            XCTAssertTrue((rect.y...(rect.y + rect.height)).contains(rect.y + rect.height * third))
        }
    }
}
