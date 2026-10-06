import XCTest
import UIKit
import WebKit
import NabcamCore
@testable import NabcamStorageHost

@MainActor
final class BrowserOverlayPageTests: XCTestCase {
    func testWidgetIsIsolatedAndStoppedPageRejectsSnapshots() throws {
        let page = try BrowserOverlayPage(source: BrowserOverlayConfiguration(id: 1))
        XCTAssertFalse(page.view.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(page.view.configuration.mediaTypesRequiringUserActionForPlayback, .all)
        XCTAssertFalse(page.view.configuration.allowsAirPlayForMediaPlayback)
        XCTAssertFalse(page.view.configuration.allowsPictureInPictureMediaPlayback)
        XCTAssertFalse(page.view.isUserInteractionEnabled)
        XCTAssertFalse(page.requestSnapshot { _ in XCTFail("Idle page must not request a snapshot") })
        page.stop()
        page.load()
        XCTAssertEqual(page.state, .stopped)
        XCTAssertNil(page.view.navigationDelegate)
        XCTAssertFalse(page.requestSnapshot { _ in XCTFail("Stopped page must not request a snapshot") })
    }

    func testActualWebKitSnapshotPreservesViewportTransparencyAndBoundsWork() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        var source = BrowserOverlayConfiguration(id: 1)
        source.enabled = true
        source.url = "https://example.invalid/widget"
        source.contentWidth = 1280
        source.contentHeight = 720
        let page = try BrowserOverlayPage(source: source)
        defer { page.stop(); window.isHidden = true }
        controller.view.addSubview(page.view)
        let scale = min(controller.view.bounds.width / 1280, controller.view.bounds.height / 720)
        page.view.transform = CGAffineTransform(scaleX: scale, y: scale)
        page.view.center = CGPoint(x: controller.view.bounds.midX, y: controller.view.bounds.midY)
        page.view.loadHTMLString("""
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;background:transparent}#red{position:absolute;left:0;top:0;width:640px;height:360px;background:#ff0000}
        #green{position:absolute;right:0;bottom:0;width:100px;height:100px;background:#00ff00}</style>
        <div id="red"></div><div id="green"></div>
        """, baseURL: URL(string: source.url))
        for _ in 0..<100 {
            if page.state == .ready || page.state == .failed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(page.state, .ready)
        let completed = expectation(description: "WebKit snapshot")
        var result: CGImage?
        XCTAssertTrue(page.requestSnapshot { image in result = image; completed.fulfill() })
        XCTAssertFalse(page.requestSnapshot { _ in XCTFail("Must not queue a second snapshot") })
        await fulfillment(of: [completed], timeout: 10)
        let image = try XCTUnwrap(result)
        XCTAssertEqual(image.width, 640)
        XCTAssertEqual(image.height, 360)
        XCTAssertFalse(page.snapshotInFlight)
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "browser-widget-full-viewport"
        attachment.lifetime = .keepAlways
        add(attachment)
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360,
            bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.translateBy(x: 0, y: 360)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 640, height: 360))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int, _ channel: Int) -> UInt8 { bytes[(y * 640 + x) * 4 + channel] }
        XCTAssertGreaterThan(pixel(100, 100, 0), 240, "Top-left content should remain red")
        XCTAssertEqual(pixel(400, 200, 3), 0, "Empty widget area must remain transparent")
        XCTAssertGreaterThan(pixel(620, 340, 1), 240, "Full viewport must include bottom-right content")
    }
}
