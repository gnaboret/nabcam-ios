import XCTest
@testable import NabcamCore

final class CameraDiagnosticsTests: XCTestCase {
    func testAdvertisedModesAreNotReportedAsMeasuredFPS() {
        var log = StreamDiagnostics()
        log.append(.cameraAvailable(front: true, lens: .ultraWide, advertised: [.hd30, .hd60]))
        let report = log.report()
        XCTAssertTrue(report.contains("front ultraWide"))
        XCTAssertTrue(report.contains("720p · 60 FPS"))
        XCTAssertTrue(report.contains("not measured delivery"))
    }
    func testRejectedSwitchAndAttachedLensRemainDistinct() {
        var log = StreamDiagnostics()
        log.append(.cameraModeRejected(front: false, lens: .telephoto, requested: .fullHD60))
        log.append(.cameraLensAttached(front: false, lens: .wide))
        let report = log.report()
        XCTAssertTrue(report.contains("rejected before attachment: rear telephoto"))
        XCTAssertTrue(report.contains("current camera kept"))
        XCTAssertTrue(report.contains("Camera lens attached: rear wide"))
    }
}
