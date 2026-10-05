public struct FrameRateSnapshot: Equatable, Sendable {
    public let frames: Int
    public let seconds: Double
    public let fps: Double
    public let maximumGapMilliseconds: Double
}

/// Constant-memory callback counter. The caller supplies monotonic seconds.
public struct FrameRateCounter: Sendable {
    private var start: Double?
    private var lastFrame: Double?
    private var count = 0
    private var maximumGap = 0.0
    public init() {}

    public mutating func reset(at time: Double) {
        start = time.isFinite ? time : nil
        lastFrame = nil; count = 0; maximumGap = 0
    }
    public mutating func record(at time: Double) {
        guard time.isFinite else { return }
        if start == nil || time < (lastFrame ?? start ?? time) { reset(at: time) }
        if let previous = lastFrame ?? start { maximumGap = max(maximumGap, time - previous) }
        lastFrame = time
        count += 1
    }
    public mutating func snapshot(at time: Double) -> FrameRateSnapshot? {
        guard time.isFinite, let start else { return nil }
        let seconds = time - start
        guard seconds > 0 else {
            if seconds < 0 { reset(at: time) }
            return nil
        }
        let gap = max(maximumGap, time - (lastFrame ?? start))
        let result = FrameRateSnapshot(frames: count, seconds: seconds, fps: Double(count) / seconds,
            maximumGapMilliseconds: max(0, gap) * 1000)
        self.start = time; count = 0; maximumGap = 0
        return result
    }
}
