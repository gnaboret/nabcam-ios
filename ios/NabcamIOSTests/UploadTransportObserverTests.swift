import HaishinKit
import SRTHaishinKit
import XCTest
@testable import NabcamStorageHost

final class UploadTransportObserverTests: XCTestCase {
    func testMissingAndRepeatedTransportSamples() async {
        let observer = UploadTransportObserver()
        let missing = await observer.bytes
        XCTAssertNil(missing)
        await observer.record(totalBytesOut: -1)
        let invalid = await observer.bytes
        XCTAssertNil(invalid)
        await observer.record(totalBytesOut: 2_000)
        await observer.record(totalBytesOut: 2_000)
        await observer.record(totalBytesOut: 500)
        let observed = await observer.bytes
        XCTAssertEqual(observed, 2_000)
        let fresh = UploadTransportObserver()
        let newBroadcast = await fresh.bytes
        XCTAssertNil(newBroadcast)
    }

    func testResetDoesNotChangeEncoderOrForgetBytes() async throws {
        let connection = SRTConnection()
        let stream = SRTStream(connection: connection)
        let observer = UploadTransportObserver()
        try await stream.setVideoSettings(VideoCodecSettings(bitRate: 1_600_000))
        try await stream.setAudioSettings(AudioCodecSettings(bitRate: 96_000))
        await observer.record(totalBytesOut: 8_600_000)
        await observer.adjustBitrate(.reset, stream: stream)
        let video = await stream.videoSettings
        let audio = await stream.audioSettings
        let bytes = await observer.bytes
        XCTAssertEqual(video.bitRate, 1_600_000)
        XCTAssertEqual(audio.bitRate, 96_000)
        XCTAssertEqual(bytes, 8_600_000)
    }
}
