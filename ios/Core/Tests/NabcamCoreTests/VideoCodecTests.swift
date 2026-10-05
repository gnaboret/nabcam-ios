import XCTest
@testable import NabcamCore

final class VideoCodecTests: XCTestCase {
    func testH264WorksWithAllTransportsWithoutHEVCHardware() throws {
        for url in ["rtmp://example.com/live/key", "rtmps://example.com/live/key", "srt://example.com:9000", "srtla://example.com:9000"] {
            XCTAssertNoThrow(try VideoCodecChoice.h264.validate(destination: StreamDestination(url), hardwareHEVC: false))
        }
    }
    func testHEVCRequiresSRTTransportAndReportedHardware() throws {
        for url in ["srt://example.com:9000", "srtla://example.com:9000"] {
            let destination = try StreamDestination(url)
            XCTAssertNoThrow(try VideoCodecChoice.hevc.validate(destination: destination, hardwareHEVC: true))
            XCTAssertThrowsError(try VideoCodecChoice.hevc.validate(destination: destination, hardwareHEVC: false))
        }
        for url in ["rtmp://example.com/live/key", "rtmps://example.com/live/key"] {
            XCTAssertThrowsError(try VideoCodecChoice.hevc.validate(destination: StreamDestination(url), hardwareHEVC: true))
        }
    }
    func testSavedHEVCAndLegacyProfilesAreNotSilentlyRewritten() throws {
        let profile = try ConnectionProfile(name: "HEVC", destination: "srtla://example.com:9000", bitrateKbps: 1600, videoCodec: .hevc)
        let saved = try ProfileArchive.decode(ProfileArchive.encode([profile]))
        XCTAssertEqual(saved, [profile])
        XCTAssertEqual(saved.first?.videoCodec, .hevc)
        let legacy = try ConnectionProfile(name: "Legacy", destination: "rtmp://example.com/live/key", bitrateKbps: 1600, videoCodec: nil)
        let restored = try XCTUnwrap(ProfileArchive.decode(ProfileArchive.encode([legacy])).first)
        XCTAssertNil(restored.videoCodec)
        XCTAssertEqual(restored.videoCodec ?? .h264, .h264)
        XCTAssertThrowsError(try ConnectionProfile(name: "Wrong transport", destination: "rtmp://example.com/live/key", bitrateKbps: 1600, videoCodec: .hevc))
    }
}
