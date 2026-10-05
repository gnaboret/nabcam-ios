/// Dimensions observed in a video frame, not inferred from a requested preset.
public struct VideoFrameSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }

    public var label: String { "\(width)×\(height)" }
}

public struct PreviewRectangle: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

/// Matches the preview's centered resizeAspect layout. Coordinates are local
/// to the preview surface, including any letterboxing, not its safe-area HUD.
public enum PreviewGeometry {
    public static func fittedRectangle(frame: VideoFrameSize, width: Double, height: Double) -> PreviewRectangle? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let scale = min(width / Double(frame.width), height / Double(frame.height))
        let fittedWidth = Double(frame.width) * scale
        let fittedHeight = Double(frame.height) * scale
        guard fittedWidth.isFinite, fittedHeight.isFinite, fittedWidth > 0, fittedHeight > 0 else { return nil }
        return PreviewRectangle(x: max(0, (width - fittedWidth) / 2),
                                y: max(0, (height - fittedHeight) / 2),
                                width: min(width, fittedWidth), height: min(height, fittedHeight))
    }
}
