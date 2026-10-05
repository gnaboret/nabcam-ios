import AVFoundation
import XCTest
@testable import NabcamStorageHost

final class AudioMonitorTests: XCTestCase {
    func testFloatPlanarAndInterleavedUseAllChannelsAndOnlyValidFrames() throws {
        for interleaved in [false, true] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: 48000, channels: 2, interleaved: interleaved))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
            buffer.frameLength = 8
            let samples = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<2 {
                for frame in 0..<8 { samples[channel][frame * buffer.stride] = frame < 4 ? (channel == 0 ? 0 : 0.5) : 1 }
            }
            buffer.frameLength = 4
            let monitor = MixerAudioMonitor()
            monitor.record(buffer)
            let level = try XCTUnwrap(monitor.snapshot())
            XCTAssertEqual(level.peakDBFS, -6.0206, accuracy: 0.001)
            XCTAssertEqual(level.rmsDBFS, -9.0309, accuracy: 0.001)
            XCTAssertFalse(level.clipped)
            XCTAssertNil(monitor.snapshot())
            // The observer must not change outgoing PCM.
            XCTAssertEqual(samples[1][0], 0.5)
        }
    }

    func testIntegerPCMAndReset() throws {
        for common in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatInt32] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: common,
                sampleRate: 48000, channels: 1, interleaved: false))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
            buffer.frameLength = 2
            if let data = buffer.int16ChannelData { data[0][0] = .min; data[0][1] = 0 }
            if let data = buffer.int32ChannelData { data[0][0] = .min; data[0][1] = 0 }
            let monitor = MixerAudioMonitor()
            monitor.record(buffer)
            XCTAssertTrue(try XCTUnwrap(monitor.snapshot()).clipped)
            monitor.record(buffer)
            monitor.reset()
            XCTAssertNil(monitor.snapshot())
        }
    }
}
