import NabcamCore
import SwiftUI
import UIKit
import XCTest
@testable import NabcamStorageHost

@MainActor
final class PreviewGridTests: XCTestCase {
    func testRenderedGridKeepsTabletLetterboxBarsClear() throws {
        let size = try XCTUnwrap(VideoFrameSize(width: 1280, height: 720))
        let renderer = ImageRenderer(content: PreviewCompositionGrid(frameSize: size).frame(width: 1024, height: 768))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cgImage.width, 1024)
        XCTAssertEqual(cgImage.height, 768)
        var pixels = [UInt8](repeating: 0, count: 1024 * 768 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1024, height: 768,
                bitsPerComponent: 8, bytesPerRow: 1024 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1024, height: 768))
        }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * 1024 + x) * 4 + 3] }
        XCTAssertEqual(alpha(341, 50), 0, "No vertical grid line in the top black bar")
        XCTAssertEqual(alpha(341, 718), 0, "No vertical grid line in the bottom black bar")
        XCTAssertGreaterThan(alpha(341, 384), 0, "Vertical thirds line must be visible inside the picture")
        XCTAssertGreaterThan(alpha(100, 288), 0, "Horizontal thirds line must be visible inside the picture")
        XCTAssertEqual(alpha(100, 384), 0, "The guide must not fill or dim the camera image")
        let attachment = XCTAttachment(image: image)
        attachment.name = "preview-grid-1024x768"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
