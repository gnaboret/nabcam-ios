import Foundation
import HaishinKit
import ImageIO
import NabcamCore
import CoreGraphics

typealias WatermarkConfiguration = SavedWatermark

extension SavedWatermark {

    /// Read only the selected file, with a hard byte bound even if metadata lies.
    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: maximumBytes + 1),
              !data.isEmpty, data.count <= maximumBytes else { throw WatermarkError.invalid }
        return data
    }
}

enum WatermarkError: Error { case invalid }

/// Images are decoded and rasterized once, never once per video frame.
@ScreenActor
final class StreamWatermarks {
    private var objects: [ImageScreenObject] = []
    private weak var screen: Screen?

    init(configurations: [WatermarkConfiguration], width: Int, height: Int) throws {
        guard configurations.count <= 3 else { throw WatermarkError.invalid }
        for config in configurations {
            guard config.data.count <= WatermarkConfiguration.maximumBytes,
                  let source = CGImageSourceCreateWithData(config.data as CFData, nil),
                  let type = CGImageSourceGetType(source) as String?,
                  ["public.png", "public.jpeg"].contains(type),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary),
                  let layout = WatermarkLayout(imageWidth: image.width, imageHeight: image.height,
                    videoWidth: width, videoHeight: height, percent: config.percent),
                  let context = CGContext(data: nil, width: layout.width, height: layout.height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WatermarkError.invalid }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
            guard let raster = context.makeImage() else { throw WatermarkError.invalid }
            let object = ImageScreenObject()
            object.cgImage = raster
            object.size = .init(width: layout.width, height: layout.height)
            object.layoutMargin = .init(top: 24, left: 24, bottom: 24, right: 24)
            object.horizontalAlignment = [.topLeft, .bottomLeft].contains(config.corner) ? .left : .right
            object.verticalAlignment = [.topLeft, .topRight].contains(config.corner) ? .top : .bottom
            objects.append(object)
        }
    }

    func install(on screen: Screen, width: Int, height: Int) throws {
        remove()
        self.screen = screen
        screen.size = .init(width: width, height: height)
        do {
            for object in objects { try screen.addChild(object) }
        } catch { remove(); throw error }
    }

    func remove() {
        for object in objects { screen?.removeChild(object) }
        screen = nil
    }
}
