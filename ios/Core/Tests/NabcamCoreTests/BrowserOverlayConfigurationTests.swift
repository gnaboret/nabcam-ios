import XCTest
@testable import NabcamCore

final class BrowserOverlayConfigurationTests: XCTestCase {
    func testURLsAreHTTPSOnlyAndDoNotAcceptCredentialsOrWhitespace() {
        XCTAssertNotNil(BrowserOverlayConfiguration.allowedURL("https://example.com/widget?token=fixture"))
        for url in ["", "http://example.com", "file:///tmp/widget", "javascript:alert(1)",
                    "https://user:secret@example.com/", "https://example.com:0/", "https://example.com:65536/",
                    "https:///", "https://example.com/a b", "https://example.com/\n", String(repeating: "x", count: 4097)] {
            XCTAssertNil(BrowserOverlayConfiguration.allowedURL(url))
        }
    }

    func testDisabledBlankSourceAndBoundsValidation() throws {
        let source = BrowserOverlayConfiguration(id: 1)
        XCTAssertEqual(try source.validated(), source)
        var invalid = source
        invalid.enabled = true
        XCTAssertThrowsError(try invalid.validated())
        invalid.url = "https://example.com/widget"
        XCTAssertNoThrow(try invalid.validated())
        invalid.opacityPercent = 101
        XCTAssertThrowsError(try invalid.validated())
        XCTAssertThrowsError(try BrowserOverlayConfiguration(id: 4).validated())
        XCTAssertThrowsError(try BrowserOverlayConfiguration(id: 1, contentWidth: 4097).validated())
    }

    func testSnapshotBoundAndPlacementForAllNinePositions() throws {
        for position in BrowserOverlayPosition.allCases {
            let source = BrowserOverlayConfiguration(id: 1, position: position)
            XCTAssertEqual(source.snapshotSize, VideoFrameSize(width: 640, height: 360))
            let rect = try XCTUnwrap(source.rectangle(videoWidth: 1280, videoHeight: 720))
            XCTAssertGreaterThanOrEqual(rect.x, 0)
            XCTAssertGreaterThanOrEqual(rect.y, 0)
            XCTAssertLessThanOrEqual(rect.x + rect.width, 1280)
            XCTAssertLessThanOrEqual(rect.y + rect.height, 720)
        }
        let tall = BrowserOverlayConfiguration(id: 1, contentWidth: 100, contentHeight: 4000)
        XCTAssertEqual(tall.snapshotSize, VideoFrameSize(width: 16, height: 640))
        var resized = tall
        resized.sizePercent = 100
        XCTAssertEqual(resized.snapshotSize, tall.snapshotSize, "Placement size must not reflow or enlarge snapshots")
        XCTAssertNil(tall.rectangle(videoWidth: 0, videoHeight: 720))
    }

    func testArchiveRoundTripLimitsAndCorruption() throws {
        let sources = (1...3).map { BrowserOverlayConfiguration(id: $0) }
        XCTAssertEqual(try BrowserOverlayArchive.decode(BrowserOverlayArchive.encode(sources)), sources)
        XCTAssertThrowsError(try BrowserOverlayArchive.encode(sources + [sources[0]]))
        XCTAssertThrowsError(try BrowserOverlayArchive.encode([sources[0], sources[0]]))
        XCTAssertThrowsError(try BrowserOverlayArchive.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try BrowserOverlayArchive.decode(Data(repeating: 0, count: BrowserOverlayArchive.maximumBytes + 1)))
    }
}
