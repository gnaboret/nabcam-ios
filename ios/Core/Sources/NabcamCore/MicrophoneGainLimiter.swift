import Foundation

/// Single-owner PCM processing state. No buffering, clock changes or resampling.
/// One gain is applied to the entire block so stereo balance is preserved.
public struct MicrophoneGainLimiter: Sendable {
    public struct Result: Sendable {
        public let requestedGain: Double
        public let appliedGain: Double
        public let limited: Bool
    }

    private var currentGain = 1.0
    private var initialized = false

    public init() {}

    public mutating func reset() {
        currentGain = 1
        initialized = false
    }

    /// Normalized PCM, including interleaved channels. Invalid samples become
    /// silence. The default neutral setting leaves ordinary samples unchanged.
    public mutating func process(_ samples: inout [Float], gainDB: Double,
                                 limiterEnabled: Bool = true, ceilingDB: Double = -1) -> Result {
        let gainDB = gainDB.isFinite ? min(24, max(-12, gainDB)) : 0
        let ceilingDB = ceilingDB.isFinite ? min(-1, max(-6, ceilingDB)) : -1
        let requested = pow(10, gainDB / 20)
        let ceiling = limiterEnabled ? pow(10, ceilingDB / 20) : 1
        guard !samples.isEmpty else {
            return Result(requestedGain: requested, appliedGain: currentGain, limited: false)
        }
        var peak = 0.0
        for sample in samples where sample.isFinite { peak = max(peak, abs(Double(sample))) }
        let safe = limiterEnabled && peak > 0 ? min(requested, ceiling / peak) : requested
        // Match Android's immediate attack and gradual per-block recovery.
        if !initialized || safe < currentGain { currentGain = safe }
        else { currentGain += (safe - currentGain) * 0.12 }
        initialized = true
        for index in samples.indices {
            let value = samples[index].isFinite ? Double(samples[index]) * currentGain : 0
            samples[index] = Float(min(ceiling, max(-ceiling, value)))
        }
        return Result(requestedGain: requested, appliedGain: currentGain,
                      limited: currentGain + 0.0001 < requested)
    }
}
