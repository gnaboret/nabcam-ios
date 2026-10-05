import Foundation

/// Reflected motion matching Android's watermark, independent of stream PTS/FPS.
public struct DVDBounce: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(width: Double, height: Double, objectWidth: Double, objectHeight: Double,
                padding: Double = 24, elapsedSeconds: Double) {
        guard [width, height, objectWidth, objectHeight, padding, elapsedSeconds].allSatisfy(\.isFinite),
              width >= 0, height >= 0, objectWidth >= 0, objectHeight >= 0 else {
            x = 0; y = 0; return
        }
        let shortEdge = min(width, height)
        func axis(_ edge: Double, _ size: Double, _ speed: Double) -> Double {
            let room = max(0, edge - size)
            let margin = min(max(0, padding), room / 2)
            let span = room - 2 * margin
            guard span > 0, speed > 0 else { return margin }
            // Reduce time before multiplication to keep very large uptimes finite.
            let period = 2 * span / speed
            guard period.isFinite, period > 0 else { return margin }
            let phase = max(0, elapsedSeconds).truncatingRemainder(dividingBy: period) * speed
            return margin + min(span, max(0, phase <= span ? phase : 2 * span - phase))
        }
        x = axis(width, objectWidth, shortEdge * 0.10)
        y = axis(height, objectHeight, shortEdge * 0.075)
    }
}
