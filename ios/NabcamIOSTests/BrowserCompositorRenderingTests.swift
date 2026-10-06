import AVFoundation
import CoreImage
import HaishinKit
import NabcamCore
import UIKit
import XCTest
@testable import NabcamStorageHost

@MainActor
final class BrowserCompositorRenderingTests: XCTestCase {
    func testActualMixedPixelsRespectRoutingSizeAndClear() async throws {
        let mixer = MediaMixer()
        let probe = BrowserMixedFrameProbe()
        let overlays = await StreamBrowserOverlays()
        let source = BrowserOverlayConfiguration(id: 1, enabled: true, url: "https://example.invalid/widget",
            destination: .streamOnly, position: .topLeft, sizePercent: 25, paddingPercent: 0)
        try await overlays.install(on: mixer.screen, sources: [source], width: 640, height: 360)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let red = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }.cgImage)
        await overlays.update(id: 1, image: red)
        var settings = await mixer.videoMixerSettings
        settings.mode = .offscreen
        await mixer.setVideoMixerSettings(settings)
        try await mixer.setFrameRate(30)
        await mixer.addOutput(probe)
        await mixer.startRunning()
        let drawn = await waitForPixel(probe, x: 40, y: 40, red: true)
        XCTAssertTrue(drawn, "Actual mixed output must include the stream-only widget")
        XCTAssertFalse(probe.isRed(x: 240, y: 40), "25% widget must be rasterized to 160px, not its source width")
        if let image = probe.image() {
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "browser-stream-composited-size"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        await overlays.update(id: 1, image: nil)
        let cleared = await waitForPixel(probe, x: 40, y: 40, red: false)
        XCTAssertTrue(cleared, "Clearing must remove cached widget pixels")
        var previewOnly = source
        previewOnly.destination = .previewOnly
        try await overlays.install(on: mixer.screen, sources: [previewOnly], width: 640, height: 360)
        await overlays.update(id: 1, image: red)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(probe.isRed(x: 40, y: 40), "Preview-only widgets must not enter the outgoing compositor")
        await mixer.removeOutput(probe)
        await mixer.stopRunning()
        await overlays.remove()
    }

    private func waitForPixel(_ probe: BrowserMixedFrameProbe, x: Int, y: Int, red: Bool) async -> Bool {
        for _ in 0..<100 {
            if probe.image() != nil, probe.isRed(x: x, y: y) == red { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

private final class BrowserMixedFrameProbe: MediaMixerOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var sample: CMSampleBuffer?
    var videoTrackId: UInt8? { get async { UInt8.max } }
    var audioTrackId: UInt8? { get async { nil } }
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async { }
    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        lock.lock(); sample = sampleBuffer; lock.unlock()
    }
    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) { }
    func image() -> CGImage? {
        lock.lock(); let latest = sample; lock.unlock()
        guard let pixels = latest?.imageBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: pixels)
        return CIContext().createCGImage(image, from: image.extent)
    }
    func isRed(x: Int, y: Int) -> Bool {
        guard let image = image(), x < image.width, y < image.height,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        let offset = (y * image.width + x) * 4
        return data[offset] > 200 && data[offset + 1] < 30 && data[offset + 2] < 30
    }
}
