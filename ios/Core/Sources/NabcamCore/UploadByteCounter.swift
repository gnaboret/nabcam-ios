import Foundation

/// One broadcast's locally submitted bytes, not carrier-billed usage or delivery proof.
public struct UploadByteCounter: Sendable {
    public private(set) var bytes: UInt64 = 0
    public init() {}

    public mutating func add(_ count: Int) {
        guard count > 0 else { return }
        let result = bytes.addingReportingOverflow(UInt64(count))
        bytes = result.overflow ? .max : result.partialValue
    }

    /// Repeated or late snapshots from the same transport must not double-count.
    /// Create a new counter for a new broadcast/socket epoch.
    public mutating func observe(total: UInt64) { bytes = max(bytes, total) }

    public static func label(bytes: UInt64) -> String {
        let divisor: Double = bytes >= 1_000_000_000 ? 1_000_000_000 : 1_000_000
        let unit = bytes >= 1_000_000_000 ? "GB" : "MB"
        return String(format: "UP %.1f %@", locale: Locale(identifier: "en_US_POSIX"), Double(bytes) / divisor, unit)
    }
}
