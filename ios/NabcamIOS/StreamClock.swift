import Foundation
import HaishinKit
import UIKit

/// Lives entirely on the compositor actor, including its formatter and text raster.
@ScreenActor
final class StreamClock {
    private let text = TextScreenObject()
    private let formatter = DateFormatter()
    private weak var screen: Screen?

    init() {
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        text.attributes = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black,
            .strokeWidth: -3
        ]
        text.layoutMargin = .init(top: 24, left: 24, bottom: 24, right: 24)
    }

    func install(on screen: Screen, corner: ClockCorner, width: Int, height: Int) throws {
        self.screen?.removeChild(text)
        screen.size = .init(width: width, height: height)
        text.horizontalAlignment = (corner == .topLeft || corner == .bottomLeft) ? .left : .right
        text.verticalAlignment = (corner == .topLeft || corner == .topRight) ? .top : .bottom
        text.invalidateLayout()
        update()
        try screen.addChild(text)
        self.screen = screen
    }

    func update() {
        formatter.timeZone = .current
        text.string = formatter.string(from: Date())
    }

    func remove() {
        screen?.removeChild(text)
        screen = nil
    }
}
