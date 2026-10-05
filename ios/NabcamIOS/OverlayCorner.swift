enum ClockCorner: String, CaseIterable, Identifiable, Sendable {
    case topLeft = "Top left", topRight = "Top right"
    case bottomLeft = "Bottom left", bottomRight = "Bottom right"
    var id: String { rawValue }
}
