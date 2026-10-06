import XCTest
@testable import NabcamCore

final class CameraSelectionTests: XCTestCase {
    let front = CameraSelection(id: "front", front: true, wide: true)
    let rear = CameraSelection(id: "rear", front: false, wide: true)
    let tele = CameraSelection(id: "tele", front: false, wide: false)

    func testNoCameraDoesNotInventOne() {
        XCTAssertNil(CameraSelection.initial(in: [], keeping: nil))
        XCTAssertNil(CameraSelection.opposite(in: [], front: false))
    }
    func testSingleFrontCameraStartsButCannotFlip() {
        XCTAssertEqual(CameraSelection.initial(in: [front], keeping: nil), "front")
        XCTAssertNil(CameraSelection.opposite(in: [front], front: true))
    }
    func testRetainsSelectedLensAndFallsBackFromMissingDevice() {
        XCTAssertEqual(CameraSelection.initial(in: [tele, front, rear], keeping: "tele"), "tele")
        XCTAssertEqual(CameraSelection.initial(in: [tele, front, rear], keeping: "missing"), "rear")
    }
    func testFlipPrefersWideButSupportsFrontUltraWideOnly() {
        XCTAssertEqual(CameraSelection.opposite(in: [tele, rear, front], front: true), "rear")
        let ultra = CameraSelection(id: "front-ultra", front: true, wide: false)
        XCTAssertEqual(CameraSelection.opposite(in: [rear, ultra], front: false), "front-ultra")
    }
}
