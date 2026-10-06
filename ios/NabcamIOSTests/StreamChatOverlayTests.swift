import XCTest
import HaishinKit
@testable import NabcamStorageHost

final class StreamChatOverlayTests: XCTestCase {
    func testInstallReplaceClearAndRemoveWithoutAccumulatingObjects() async throws {
        try await Task { @ScreenActor in
            let screen = Screen()
            let count = screen.childCounts
            let chat = StreamChatOverlay()
            try chat.install(on: screen, width: 537, height: 252, videoWidth: 1280, videoHeight: 720)
            XCTAssertEqual(screen.childCounts, count + 1)
            chat.update(image: nil)
            try chat.install(on: screen, width: 806, height: 378, videoWidth: 1920, videoHeight: 1080)
            XCTAssertEqual(screen.childCounts, count + 1)
            chat.remove()
            chat.remove()
            chat.update(image: nil)
            XCTAssertEqual(screen.childCounts, count)
        }.value
    }
}
