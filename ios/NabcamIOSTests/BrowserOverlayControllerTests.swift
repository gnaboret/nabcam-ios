import XCTest
import NabcamCore
@testable import NabcamStorageHost

@MainActor
final class BrowserOverlayControllerTests: XCTestCase {
    func testDisabledSourcesDoNotCreateWebViewsOrDeliverFrames() async throws {
        let controller = BrowserOverlayController()
        let host = BrowserOverlayHost(frame: .zero)
        try controller.start(sources: [BrowserOverlayConfiguration(id: 1)], host: host) { _, _ in
            XCTFail("Disabled widget must not deliver frames")
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(controller.pages.isEmpty)
        XCTAssertTrue(controller.frames.isEmpty)
        XCTAssertTrue(controller.failedSources.isEmpty)
        XCTAssertTrue(host.subviews.isEmpty)
        controller.stop()
        controller.stop()
        XCTAssertTrue(host.subviews.isEmpty)
    }

    func testInvalidSourceIsRejectedBeforeCreatingAnyPage() throws {
        let controller = BrowserOverlayController()
        let host = BrowserOverlayHost(frame: .zero)
        let invalid = BrowserOverlayConfiguration(id: 1, enabled: true, url: "http://example.invalid/private-widget")
        XCTAssertThrowsError(try controller.start(sources: [invalid], host: host) { _, _ in
            XCTFail("Invalid widget must not deliver frames")
        })
        XCTAssertTrue(controller.pages.isEmpty)
        XCTAssertTrue(host.subviews.isEmpty)
    }
}
