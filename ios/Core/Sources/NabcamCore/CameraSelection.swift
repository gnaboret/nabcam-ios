/// Selection policy only; actual device availability and formats come from AVFoundation.
public struct CameraSelection: Equatable, Sendable {
    public let id: String
    public let front: Bool
    public let wide: Bool
    public init(id: String, front: Bool, wide: Bool) {
        self.id = id; self.front = front; self.wide = wide
    }
    public static func initial(in cameras: [Self], keeping id: String?) -> String? {
        cameras.first { $0.id == id }?.id
            ?? cameras.first { !$0.front && $0.wide }?.id
            ?? cameras.first?.id
    }
    public static func opposite(in cameras: [Self], front: Bool) -> String? {
        cameras.first { $0.front != front && $0.wide }?.id
            ?? cameras.first { $0.front != front }?.id
    }
}
