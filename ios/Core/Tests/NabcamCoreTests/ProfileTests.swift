import XCTest
@testable import NabcamCore

final class ProfileTests: XCTestCase {
    func testVideoPresetsRoundTripAndLegacyProfileLoads() throws {
        for mode in VideoPreset.allCases {
            let p = try ConnectionProfile(name: "Test", destination: "rtmps://example.com/live/test",
                                          bitrateKbps: 1600, videoPreset: mode)
            XCTAssertEqual(try ProfileArchive.decode(ProfileArchive.encode([p])).first?.videoPreset, mode)
            XCTAssertEqual(mode.width * 9, mode.height * 16)
            XCTAssertTrue([30.0, 60.0].contains(mode.fps))
        }
        let legacy = Data(#"{"version":1,"profiles":[{"id":"C195C973-79F9-4EB8-B432-9DC467636AFF","name":"Legacy","destination":"rtmps://example.com/live/test","bitrateKbps":1600,"chatChannel":""}]}"#.utf8)
        let restored = try XCTUnwrap(ProfileArchive.decode(legacy).first)
        XCTAssertEqual(restored.videoPreset ?? .hd30, .hd30)
    }
    func testRoundTripPreservesCredentials() throws {
        let profile = try ConnectionProfile(name: " Receiver ", destination: "srt://example.com:9000?passphrase=example-test-only&latency=2500", bitrateKbps: 1600, chatChannel: "channel")
        XCTAssertEqual(profile.name, "Receiver")
        XCTAssertEqual(try ProfileArchive.decode(ProfileArchive.encode([profile])), [profile])
    }
    func testInvalidProfileRejected() {
        XCTAssertThrowsError(try ConnectionProfile(name: " ", destination: "rtmps://example.com/live/test", bitrateKbps: 1600))
        XCTAssertThrowsError(try ConnectionProfile(name: "A", destination: "rtmps://example.com/live/test", bitrateKbps: 1))
        XCTAssertThrowsError(try ConnectionProfile(name: "A", destination: "srtla://example.com:9000?mode=listener", bitrateKbps: 1600))
    }
    func testSrtlaProfileRoundTripPreservesRelayAndEscapedCredentials() throws {
        let destination = "srtla://example.com:9000?streamid=a%2Bb%26c&passphrase=example%2Btest%26only&latency=2500"
        let profile = try ConnectionProfile(name: "Relay", destination: destination, bitrateKbps: 1600)
        let restored = try XCTUnwrap(ProfileArchive.decode(ProfileArchive.encode([profile])).first)
        XCTAssertEqual(restored, profile)
        XCTAssertEqual(restored.destination, destination)
        XCTAssertTrue(try StreamDestination(restored.destination).requiresSrtlaRelay)
    }
    func testCorruptUnknownAndOversizedArchiveRejected() {
        for data in [Data("nope".utf8), Data(#"{"version":2,"profiles":[]}"#.utf8), Data(repeating: 0, count: 256 * 1024 + 1)] {
            XCTAssertThrowsError(try ProfileArchive.decode(data))
        }
    }
    func testDuplicateAndTooManyProfilesRejected() throws {
        let p = try ConnectionProfile(name: "A", destination: "rtmps://example.com/live/test", bitrateKbps: 1600)
        XCTAssertThrowsError(try ProfileArchive.encode([p, p]))
        let many = try (0..<21).map { try ConnectionProfile(name: "\($0)", destination: p.destination, bitrateKbps: 1600) }
        XCTAssertThrowsError(try ProfileArchive.encode(many))
    }
    func testDecodeRevalidatesFields() throws {
        let p = try ConnectionProfile(name: "A", destination: "rtmps://example.com/live/test", bitrateKbps: 1600)
        let encoded = String(decoding: try ProfileArchive.encode([p]), as: UTF8.self)
        XCTAssertThrowsError(try ProfileArchive.decode(Data(encoded.replacingOccurrences(of: "1600", with: "0").utf8)))
    }
}
