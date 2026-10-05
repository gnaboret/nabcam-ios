import Foundation

public struct WatermarkLayout: Equatable, Sendable {
    public let width: Int
    public let height: Int

    /// Fit inside both a requested width and 40% of video height, preserving aspect.
    public init?(imageWidth: Int, imageHeight: Int, videoWidth: Int, videoHeight: Int, percent: Int) {
        guard imageWidth > 0, imageHeight > 0, videoWidth >= 100, videoHeight >= 100,
              (5...40).contains(percent) else { return nil }
        let scale = min(Double(videoWidth) * Double(percent) / 100 / Double(imageWidth),
                        Double(videoHeight) * 0.4 / Double(imageHeight))
        width = max(1, Int((Double(imageWidth) * scale).rounded(.down)))
        height = max(1, Int((Double(imageHeight) * scale).rounded(.down)))
    }
}
