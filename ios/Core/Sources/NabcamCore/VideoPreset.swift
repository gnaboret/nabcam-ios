public enum VideoPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case hd30, hd60, fullHD30, fullHD60
    public var id: String { rawValue }
    public var width: Int { self == .hd30 || self == .hd60 ? 1280 : 1920 }
    public var height: Int { width == 1280 ? 720 : 1080 }
    public var fps: Double { self == .hd60 || self == .fullHD60 ? 60 : 30 }
    public var label: String { "\(height)p · \(Int(fps)) FPS" }
}
