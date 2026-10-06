import XCTest
import HaishinKit
import NabcamCore
@testable import NabcamStorageHost

final class StreamBrowserOverlaysTests: XCTestCase {
    func testDestinationRoutingReplacementAndInvalidProposalPreservation() async throws {
        let counts = try await Task { @ScreenActor in
            let screen = Screen()
            let baseline = screen.childCounts
            let overlays = StreamBrowserOverlays()
            let sources = [
                BrowserOverlayConfiguration(id: 1, enabled: true, url: "https://example.invalid/1", destination: .previewOnly),
                BrowserOverlayConfiguration(id: 2, enabled: true, url: "https://example.invalid/2", destination: .streamOnly),
                BrowserOverlayConfiguration(id: 3, enabled: true, url: "https://example.invalid/3", destination: .both)
            ]
            try overlays.install(on: screen, sources: sources, width: 1280, height: 720)
            let installed = screen.childCounts
            do {
                try overlays.install(on: screen, sources: [sources[0], sources[0]], width: 1280, height: 720)
                XCTFail("Duplicate IDs must be rejected")
            } catch { XCTAssertTrue(error is BrowserOverlayConfiguration.Failure) }
            let preserved = screen.childCounts
            overlays.update(id: 2, image: nil)
            overlays.update(id: 3, image: nil)
            try overlays.install(on: screen, sources: [sources[0]], width: 1280, height: 720)
            let previewOnly = screen.childCounts
            overlays.remove()
            overlays.remove()
            return [baseline, installed, preserved, previewOnly, screen.childCounts]
        }.value
        XCTAssertEqual(counts[1], counts[0] + 2)
        XCTAssertEqual(counts[2], counts[1])
        XCTAssertEqual(counts[3], counts[0])
        XCTAssertEqual(counts[4], counts[0])
    }
}
