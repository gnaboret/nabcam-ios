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
    private var animated: [ImageScreenObject] = []
    private weak var screen: Screen?
    private var motionTask: Task<Void, Never>?

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
            if config.dvd == true {
                object.horizontalAlignment = .left
                object.verticalAlignment = .top
                animated.append(object)
            }
        }
    }

    func install(on screen: Screen, width: Int, height: Int) throws {
        remove()
        self.screen = screen
        screen.size = .init(width: width, height: height)
        do {
            for object in objects { try screen.addChild(object) }
            if !animated.isEmpty {
                motionTask = Task { [weak self] in
                    let began = DispatchTime.now().uptimeNanoseconds
                    while !Task.isCancelled {
                        guard self?.screen != nil else { return }
                        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
                        self?.updateMotion(width: width, height: height, elapsedSeconds: elapsed)
                        do { try await Task.sleep(for: .milliseconds(33)) }
                        catch { return }
                    }
                }
            }
        } catch { remove(); throw error }
    }

    private func updateMotion(width: Int, height: Int, elapsedSeconds: Double) {
        for object in animated {
            let point = DVDBounce(width: Double(width), height: Double(height),
                                  objectWidth: Double(object.size.width), objectHeight: Double(object.size.height),
                                  elapsedSeconds: elapsedSeconds)
            object.layoutMargin = .init(top: CGFloat(point.y), left: CGFloat(point.x), bottom: 0, right: 0)
            object.invalidateLayout()
        }
    }

    func remove() {
        motionTask?.cancel()
        motionTask = nil
        for object in objects { screen?.removeChild(object) }
        screen = nil
    }
}
