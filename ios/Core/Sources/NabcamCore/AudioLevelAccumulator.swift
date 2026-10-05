import Foundation

public struct AudioLevel: Equatable, Sendable {
    public let rmsDBFS: Double
    public let peakDBFS: Double
    public let clipped: Bool
    public var fraction: Double { min(1, max(0, (rmsDBFS + 60) / 60)) }
}

/// Measures normalized PCM without retaining audio. No samples is distinct from silence.
public struct AudioLevelAccumulator: Sendable {
    private var squares = 0.0
    private var peak = 0.0
    private var count = 0
    public init() {}

    public mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        // Bound malformed float samples before squaring; preserve clipping evidence.
        let magnitude = min(abs(value), 16)
        squares += magnitude * magnitude
        peak = max(peak, magnitude)
        count += 1
    }

    public mutating func take() -> AudioLevel? {
        defer { self = AudioLevelAccumulator() }
        guard count > 0 else { return nil }
        func db(_ amplitude: Double) -> Double {
            min(0, max(-90, 20 * log10(max(amplitude, 0.000_000_001))))
        }
        return AudioLevel(rmsDBFS: db(sqrt(squares / Double(count))), peakDBFS: db(peak), clipped: peak >= 1)
    }
}
