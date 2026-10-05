import XCTest
@testable import NabcamCore

final class WatermarkTests: XCTestCase {
    func testWideLogoAndPortraitLogoFit() {
        let wide = WatermarkLayout(imageWidth: 1000, imageHeight: 250, videoWidth: 1280, videoHeight: 720, percent: 20)
        XCTAssertEqual(wide?.width, 256)
        XCTAssertEqual(wide?.height, 64)
        let tall = WatermarkLayout(imageWidth: 100, imageHeight: 1000, videoWidth: 1280, videoHeight: 720, percent: 40)
        XCTAssertEqual(tall?.width, 28)
        XCTAssertEqual(tall?.height, 288)
    }
    func testBoundsAndFullHD() {
        XCTAssertNil(WatermarkLayout(imageWidth: 0, imageHeight: 10, videoWidth: 1280, videoHeight: 720, percent: 20))
        XCTAssertNil(WatermarkLayout(imageWidth: 10, imageHeight: 10, videoWidth: 1280, videoHeight: 720, percent: 41))
        let layout = WatermarkLayout(imageWidth: 500, imageHeight: 500, videoWidth: 1920, videoHeight: 1080, percent: 40)
        XCTAssertEqual(layout?.width, 432)
        XCTAssertEqual(layout?.height, 432)
    }
}
