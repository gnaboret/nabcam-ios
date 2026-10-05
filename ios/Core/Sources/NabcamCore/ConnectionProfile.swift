import Foundation

public struct ConnectionProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var destination: String
    public var bitrateKbps: Int
    public var chatChannel: String
    // Optional on disk so first-version profiles remain readable.
    public var videoPreset: VideoPreset?
    public var videoCodec: VideoCodecChoice?

    public init(id: UUID = UUID(), name: String, destination: String,
                bitrateKbps: Int, chatChannel: String = "", videoPreset: VideoPreset? = .hd30,
                videoCodec: VideoCodecChoice? = .h264) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, destination.utf8.count <= 8192,
              (444...12000).contains(bitrateKbps), chatChannel.count <= 50 else {
            throw ProfileError.invalid
        }
        let parsed = try StreamDestination(destination)
        // Hardware is checked when starting on the actual device, not when
        // reading a saved profile. Do not silently replace a saved codec.
        try (videoCodec ?? .h264).validate(destination: parsed, hardwareHEVC: true)
        self.id = id
        self.name = name
        self.destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bitrateKbps = bitrateKbps
        self.chatChannel = chatChannel
        self.videoPreset = videoPreset
        self.videoCodec = videoCodec
    }

    public func validated() throws -> Self {
        try Self(id: id, name: name, destination: destination,
                 bitrateKbps: bitrateKbps, chatChannel: chatChannel, videoPreset: videoPreset, videoCodec: videoCodec)
    }
}

public enum ProfileError: Error, LocalizedError {
    case invalid, full, corrupt
    public var errorDescription: String? {
        switch self {
        case .invalid: "Use a profile name of 1–60 characters and a valid bitrate and destination."
        case .full: "You can save up to 20 connection profiles."
        case .corrupt: "Saved profiles could not be read. They have not been overwritten."
        }
    }
}

public enum ProfileArchive {
    private struct Archive: Codable {
        let version: Int
        let profiles: [ConnectionProfile]
    }
    public static func encode(_ profiles: [ConnectionProfile]) throws -> Data {
        guard profiles.count <= 20 else { throw ProfileError.full }
        guard Set(profiles.map(\.id)).count == profiles.count else { throw ProfileError.corrupt }
        return try JSONEncoder().encode(Archive(version: 1, profiles: profiles.map { try $0.validated() }))
    }
    public static func decode(_ data: Data) throws -> [ConnectionProfile] {
        guard data.count <= 256 * 1024 else { throw ProfileError.corrupt }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1, archive.profiles.count <= 20,
                  Set(archive.profiles.map(\.id)).count == archive.profiles.count else { throw ProfileError.corrupt }
            return try archive.profiles.map { try $0.validated() }
        } catch { throw ProfileError.corrupt }
    }
}
