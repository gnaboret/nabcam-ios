import Foundation
import XCTest
@testable import NabcamCore

final class AudioBitrateTests: XCTestCase {
    func testRatesRoundTripInSavedProfiles() throws {
        for rate in AudioBitrate.allCases {
            XCTAssertEqual(rate.bitsPerSecond, rate.rawValue * 1000)
            let profile = try ConnectionProfile(name: "Audio", destination: "srt://example.com:9000",
                                                bitrateKbps: 1600, audioBitrate: rate)
            XCTAssertEqual(try ProfileArchive.decode(ProfileArchive.encode([profile])), [profile])
        }
    }

    func testOldProfileWithoutAudioFieldRetainsDefaultBehavior() throws {
        let profile = try ConnectionProfile(name: "Legacy", destination: "rtmp://example.com/live/key",
                                            bitrateKbps: 1600, audioBitrate: nil)
        let bytes = try ProfileArchive.encode([profile])
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("audioBitrate"))
        let restored = try XCTUnwrap(ProfileArchive.decode(bytes).first)
        XCTAssertNil(restored.audioBitrate)
        XCTAssertEqual(restored.audioBitrate ?? .kbps96, .kbps96)
    }

    func testUnknownAudioRateIsRejectedWithoutSilentlySubstituting() throws {
        let profile = try ConnectionProfile(name: "Invalid", destination: "srt://example.com:9000", bitrateKbps: 1600)
        let saved = String(decoding: try ProfileArchive.encode([profile]), as: UTF8.self)
        let corrupt = saved.replacingOccurrences(of: "\"audioBitrate\":96", with: "\"audioBitrate\":-1")
        XCTAssertNotEqual(corrupt, saved)
        XCTAssertThrowsError(try ProfileArchive.decode(Data(corrupt.utf8)))
    }

    func testAudioRateContributesToRelayBudgetAndDiagnostics() {
        let low = SrtlaPacketPacer.rate(videoKbps: 1600, audioKbps: AudioBitrate.kbps64.rawValue, headroomPercent: 125)
        let high = SrtlaPacketPacer.rate(videoKbps: 1600, audioKbps: AudioBitrate.kbps192.rawValue, headroomPercent: 125)
        XCTAssertEqual(high - low, 160)
        var diagnostics = StreamDiagnostics()
        diagnostics.append(.audioEncoderRequested(.kbps128))
        XCTAssertTrue(diagnostics.report().contains("AAC 128 kbps, 48000 Hz"))
    }
}
