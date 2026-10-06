import CoreGraphics
import HaishinKit
import NabcamCore

/// Browser snapshots enter the existing compositor without altering capture,
/// encoder settings, audio timing or transport pacing.
@ScreenActor
final class StreamBrowserOverlays {
    private struct Entry {
        let object: ImageScreenObject
        let source: BrowserOverlayConfiguration
        let rectangle: PreviewRectangle
    }
    private var entries: [Int: Entry] = [:]
    private weak var screen: Screen?

    func install(on screen: Screen, sources: [BrowserOverlayConfiguration], width: Int, height: Int) throws {
        // Validate the entire proposal before replacing existing objects.
        _ = try BrowserOverlayArchive.encode(sources)
        var proposed: [Int: Entry] = [:]
        for source in sources where source.enabled && source.destination != .previewOnly {
            guard let rect = source.rectangle(videoWidth: width, videoHeight: height) else {
                throw BrowserOverlayConfiguration.Failure.invalid
            }
            let object = ImageScreenObject()
            object.size = CGSize(width: rect.width, height: rect.height)
            object.horizontalAlignment = .left
            object.verticalAlignment = .top
            object.layoutMargin = .init(top: rect.y, left: rect.x, bottom: 0, right: 0)
            proposed[source.id] = Entry(object: object, source: source, rectangle: rect)
        }
        remove()
        self.screen = screen
        entries = proposed
        do {
            for id in entries.keys.sorted() {
                if let entry = entries[id] { try screen.addChild(entry.object) }
            }
        } catch { remove(); throw error }
    }

    /// Callers await this update before requesting the next snapshot, bounding
    /// work to one frame per source. A failed page clears its stale image.
    func update(id: Int, image: CGImage?) {
        guard let entry = entries[id] else { return }
        let width = max(1, Int(entry.rectangle.width.rounded()))
        let height = max(1, Int(entry.rectangle.height.rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            remove()
            return
        }
        // HaishinKit positions but does not scale ImageScreenObject pixels.
        // Rasterize to the destination size just as the watermark path does.
        if let image, image.width <= 640, image.height <= 640 {
            context.interpolationQuality = .high
            context.setAlpha(CGFloat(entry.source.opacityPercent) / 100)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Use an explicit transparent raster when clearing. A nil image leaves
        // the pinned renderer's cached image intact and can display stale data.
        entry.object.cgImage = context.makeImage()
    }

    func remove() {
        for entry in entries.values { screen?.removeChild(entry.object) }
        entries.removeAll()
        screen = nil
    }
}
