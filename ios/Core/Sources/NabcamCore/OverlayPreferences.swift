import Foundation

public enum OverlayCorner: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft = "Top left", topRight = "Top right"
    case bottomLeft = "Bottom left", bottomRight = "Bottom right"
    public var id: String { rawValue }
}

public struct SavedWatermark: Codable, Identifiable, Equatable, Sendable {
    public static let maximumBytes = 4 * 1024 * 1024
    public let id: UUID
    public let data: Data
    public var corner: OverlayCorner
    public var percent: Int
    // Optional to preserve archives written before animated watermarks existed.
    public var dvd: Bool?
    public init(id: UUID = UUID(), data: Data, corner: OverlayCorner = .bottomRight, percent: Int = 20, dvd: Bool? = nil) {
        self.id = id; self.data = data; self.corner = corner; self.percent = percent
        self.dvd = dvd
    }
}

public struct OverlayPreferences: Codable, Equatable, Sendable {
    public var watermarks: [SavedWatermark]
    public var clockEnabled: Bool
    public var clockCorner: OverlayCorner
    public init(watermarks: [SavedWatermark] = [], clockEnabled: Bool = false, clockCorner: OverlayCorner = .topRight) {
        self.watermarks = watermarks; self.clockEnabled = clockEnabled; self.clockCorner = clockCorner
    }
}

public enum OverlayArchive {
    // Base64 expands the three 4 MiB images to 16 MiB, plus bounded JSON metadata.
    public static let maximumBytes = 17 * 1024 * 1024
    private struct Archive: Codable { let version: Int; let preferences: OverlayPreferences }
    public enum Failure: Error { case invalid }

    private static func validate(_ preferences: OverlayPreferences) throws {
        let marks = preferences.watermarks
        guard marks.count <= 3, Set(marks.map(\.id)).count == marks.count,
              marks.allSatisfy({ !$0.data.isEmpty && $0.data.count <= SavedWatermark.maximumBytes && (5...40).contains($0.percent) }) else {
            throw Failure.invalid
        }
    }
    public static func encode(_ preferences: OverlayPreferences) throws -> Data {
        try validate(preferences)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(Archive(version: 1, preferences: preferences))
        guard data.count <= maximumBytes else { throw Failure.invalid }
        return data
    }
    public static func decode(_ data: Data) throws -> OverlayPreferences {
        guard data.count <= maximumBytes else { throw Failure.invalid }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1 else { throw Failure.invalid }
        try validate(archive.preferences)
        return archive.preferences
    }
}
