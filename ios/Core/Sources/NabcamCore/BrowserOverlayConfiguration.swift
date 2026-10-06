import Foundation

public enum BrowserOverlayDestination: String, Codable, CaseIterable, Sendable {
    case previewOnly = "Preview only", streamOnly = "Stream only", both = "Preview and stream"
}

public enum BrowserOverlayPosition: String, Codable, CaseIterable, Sendable {
    case topLeft = "Top left", topCenter = "Top center", topRight = "Top right"
    case centerLeft = "Center left", center = "Center", centerRight = "Center right"
    case bottomLeft = "Bottom left", bottomCenter = "Bottom center", bottomRight = "Bottom right"
}

/// URLs can contain private widget tokens. Persist this archive in Keychain, not
/// UserDefaults, diagnostics or exports. A disabled blank source is valid.
public struct BrowserOverlayConfiguration: Codable, Equatable, Identifiable, Sendable {
    public static let maximumSources = 3
    public let id: Int
    public var enabled: Bool
    public var url: String
    public var destination: BrowserOverlayDestination
    public var position: BrowserOverlayPosition
    public var sizePercent: Int
    public var paddingPercent: Int
    public var opacityPercent: Int
    public var contentWidth: Int
    public var contentHeight: Int

    public init(id: Int, enabled: Bool = false, url: String = "",
                destination: BrowserOverlayDestination = .previewOnly,
                position: BrowserOverlayPosition = .topLeft, sizePercent: Int = 50,
                paddingPercent: Int = 2, opacityPercent: Int = 100,
                contentWidth: Int = 1920, contentHeight: Int = 1080) {
        self.id = id; self.enabled = enabled; self.url = url
        self.destination = destination; self.position = position
        self.sizePercent = sizePercent; self.paddingPercent = paddingPercent
        self.opacityPercent = opacityPercent
        self.contentWidth = contentWidth; self.contentHeight = contentHeight
    }

    public enum Failure: Error { case invalid }

    public static func allowedURL(_ value: String) -> URL? {
        guard !value.isEmpty, value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) != false else { return nil }
        return parts.url
    }

    public func validated() throws -> Self {
        guard (1...Self.maximumSources).contains(id), (10...100).contains(sizePercent),
              (0...10).contains(paddingPercent), (0...100).contains(opacityPercent),
              (1...4096).contains(contentWidth), (1...4096).contains(contentHeight),
              (url.isEmpty && !enabled) || Self.allowedURL(url) != nil else { throw Failure.invalid }
        return self
    }

    /// Layout viewport and raster size are separate, matching Android. Changing
    /// overlay size does not reflow the webpage; snapshots stay <=640px per side.
    public var snapshotSize: VideoFrameSize? {
        guard (try? validated()) != nil else { return nil }
        let scale = 640.0 / Double(max(contentWidth, contentHeight))
        return VideoFrameSize(width: max(1, Int(Double(contentWidth) * scale)),
                              height: max(1, Int(Double(contentHeight) * scale)))
    }

    public func rectangle(videoWidth: Int, videoHeight: Int) -> PreviewRectangle? {
        guard let raster = snapshotSize, (1...8192).contains(videoWidth), (1...8192).contains(videoHeight) else { return nil }
        let margin = Double(min(videoWidth, videoHeight)) * Double(paddingPercent) / 100
        let availableWidth = max(1, Double(videoWidth) - 2 * margin)
        let availableHeight = max(1, Double(videoHeight) - 2 * margin)
        let scale = min(availableWidth * Double(sizePercent) / 100 / Double(raster.width),
                        availableHeight / Double(raster.height))
        let width = Double(raster.width) * scale
        let height = Double(raster.height) * scale
        let x: Double
        switch position {
        case .topLeft, .centerLeft, .bottomLeft: x = margin
        case .topCenter, .center, .bottomCenter: x = (Double(videoWidth) - width) / 2
        case .topRight, .centerRight, .bottomRight: x = Double(videoWidth) - margin - width
        }
        let y: Double
        switch position {
        case .topLeft, .topCenter, .topRight: y = margin
        case .centerLeft, .center, .centerRight: y = (Double(videoHeight) - height) / 2
        case .bottomLeft, .bottomCenter, .bottomRight: y = Double(videoHeight) - margin - height
        }
        return PreviewRectangle(x: x, y: y, width: width, height: height)
    }
}

public enum BrowserOverlayArchive {
    public static let maximumBytes = 64 * 1024
    private struct Archive: Codable { let version: Int; let sources: [BrowserOverlayConfiguration] }

    private static func validate(_ sources: [BrowserOverlayConfiguration]) throws {
        guard sources.count <= BrowserOverlayConfiguration.maximumSources,
              Set(sources.map(\.id)).count == sources.count else { throw BrowserOverlayConfiguration.Failure.invalid }
        for source in sources { _ = try source.validated() }
    }
    public static func encode(_ sources: [BrowserOverlayConfiguration]) throws -> Data {
        try validate(sources)
        let data = try JSONEncoder().encode(Archive(version: 1, sources: sources))
        guard data.count <= maximumBytes else { throw BrowserOverlayConfiguration.Failure.invalid }
        return data
    }
    public static func decode(_ data: Data) throws -> [BrowserOverlayConfiguration] {
        do {
            guard data.count <= maximumBytes else { throw BrowserOverlayConfiguration.Failure.invalid }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1 else { throw BrowserOverlayConfiguration.Failure.invalid }
            try validate(archive.sources)
            return archive.sources
        } catch { throw BrowserOverlayConfiguration.Failure.invalid }
    }
}
