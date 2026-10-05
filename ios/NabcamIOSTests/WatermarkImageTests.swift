import XCTest
import UIKit
import HaishinKit
@testable import NabcamStorageHost

@MainActor
final class WatermarkImageTests: XCTestCase {
    func testAnimatedWatermarkCanBeRemovedWithoutRetainingItsRenderer() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let png = try XCTUnwrap(image.pngData())
        let released = try await Task { @ScreenActor in
            let screen = Screen()
            let baseline = screen.childCounts
            var renderer: StreamWatermarks? = try StreamWatermarks(configurations: [
                WatermarkConfiguration(data: png, dvd: true)
            ], width: 1280, height: 720)
            weak var weakRenderer = renderer
            try renderer?.install(on: screen, width: 1280, height: 720)
            try await Task.sleep(for: .milliseconds(100))
            let installed = screen.childCounts == baseline + 1
            renderer?.remove()
            renderer = nil
            try await Task.sleep(for: .milliseconds(100))
            return installed && screen.childCounts == baseline && weakRenderer == nil
        }.value
        XCTAssertTrue(released)
    }

    func testPNGAndJPEGInstallReplaceAndRemove() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let png = try XCTUnwrap(image.pngData())
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let counts = try await Task { @ScreenActor in
            let screen = Screen()
            let baseline = screen.childCounts
            let overlays = try StreamWatermarks(configurations: [
                WatermarkConfiguration(data: png), WatermarkConfiguration(data: jpeg)
            ], width: 1280, height: 720)
            try overlays.install(on: screen, width: 1280, height: 720)
            let installed = screen.childCounts
            try overlays.install(on: screen, width: 1920, height: 1080)
            let reinstalled = screen.childCounts
            overlays.remove()
            overlays.remove() // Idempotent teardown must not remove the camera child.
            return [baseline, installed, reinstalled, screen.childCounts]
        }.value
        XCTAssertEqual(counts[1], counts[0] + 2)
        XCTAssertEqual(counts[2], counts[0] + 2)
        XCTAssertEqual(counts[3], counts[0])
    }

    func testRejectsInvalidAndOversizedInput() async {
        for data in [Data(), Data("not an image".utf8), Data(repeating: 0, count: WatermarkConfiguration.maximumBytes + 1)] {
            do {
                _ = try await StreamWatermarks(configurations: [WatermarkConfiguration(data: data)], width: 1280, height: 720)
                XCTFail("Invalid image was accepted")
            } catch { XCTAssertTrue(error is WatermarkError) }
        }
    }
}
