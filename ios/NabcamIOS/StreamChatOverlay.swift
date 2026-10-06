import CoreGraphics
import HaishinKit

/// Owns one bounded chat raster; never queues messages or touches audio.
@ScreenActor
final class StreamChatOverlay {
    private let object = ImageScreenObject()
    private weak var screen: Screen?
    private var width = 0
    private var height = 0

    func install(on screen: Screen, width: Int, height: Int, videoWidth: Int, videoHeight: Int) throws {
        remove()
        self.width = width
        self.height = height
        screen.size = CGSize(width: videoWidth, height: videoHeight)
        object.size = CGSize(width: width, height: height)
        object.horizontalAlignment = .left
        object.verticalAlignment = .bottom
        object.layoutMargin = .init(top: 0, left: 24, bottom: 24, right: 0)
        try screen.addChild(object)
        self.screen = screen
        update(image: nil)
    }

    func update(image: CGImage?) {
        guard screen != nil else { return }
        if let image, image.width == width, image.height == height {
            object.cgImage = image
        } else {
            // A nil cgImage does not clear HaishinKit's cached pixels.
            object.cgImage = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    func remove() {
        screen?.removeChild(object)
        screen = nil
    }
}
