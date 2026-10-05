import Foundation

/// Per-interface history survives socket replacement. Mirrors Android's two
/// early silent-start retries, then slows down; explicit receiver delays win.
public struct SrtlaSocketRecovery: Sendable {
    private var readyAt: Int64?
    private var firstRegistrationAt: Int64?
    private var failedAt: Int64?
    private var receivedAny = false
    private var failureCount = 0
    private var lastTime: Int64 = 0
    public private(set) var previouslyRegistered = false
    public private(set) var fastReopens = 0

    public init() {}

    public mutating func opened(at time: Int64) {
        guard accept(time) else { return }
        readyAt = nil; firstRegistrationAt = nil; failedAt = nil; receivedAny = false
    }
    public mutating func ready(at time: Int64) {
        guard accept(time) else { return }
        readyAt = time
        firstRegistrationAt = nil
    }
    /// Start silence detection only after REG1/REG2 is admitted to the socket.
    /// A ready standby path can wait for another path's group negotiation; that
    /// wait is not evidence that its own socket is unresponsive.
    public mutating func registrationSent(at time: Int64) {
        guard accept(time), readyAt != nil, firstRegistrationAt == nil else { return }
        firstRegistrationAt = time
    }
    public mutating func received(at time: Int64, registered: Bool) {
        guard accept(time) else { return }
        receivedAny = true
        if registered { previouslyRegistered = true; failureCount = 0 }
    }
    public mutating func failed(at time: Int64) {
        guard accept(time), failedAt == nil else { return }
        failedAt = time
        failureCount = min(5, failureCount + 1)
    }
    public func shouldReplace(at time: Int64, registered: Bool, socketReady: Bool,
                              serverRetryAfter: Int64) -> Bool {
        guard time >= lastTime, time >= serverRetryAfter, !registered else { return false }
        if let failedAt {
            let delay = min(Int64(30_000), Int64(2000) << max(0, failureCount - 1))
            return time - failedAt >= delay
        }
        guard socketReady, let readyAt else { return false }
        let responseStart: Int64
        if !receivedAny && !previouslyRegistered {
            guard let firstRegistrationAt else { return false }
            responseStart = max(readyAt, firstRegistrationAt)
        } else { responseStart = readyAt }
        let wait: Int64 = !receivedAny && fastReopens < 2 && !previouslyRegistered ? 4000 : 12_000
        return time - responseStart >= wait
    }
    public mutating func replacing(at time: Int64) {
        guard accept(time) else { return }
        if !receivedAny && !previouslyRegistered { fastReopens = min(2, fastReopens + 1) }
    }
    private mutating func accept(_ time: Int64) -> Bool {
        guard time >= lastTime else { return false }
        lastTime = time
        return true
    }
}
