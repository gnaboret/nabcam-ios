import AVFoundation
import XCTest
@testable import NabcamStorageHost

final class MicrophonePCMProcessorTests: XCTestCase {
    func testFloatStereoLayoutsPreserveInputFormatAndFrameLength() throws {
        for interleaved in [false, true] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000, channels: 2, interleaved: interleaved))
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
            input.frameLength = 4
            let data = try XCTUnwrap(input.floatChannelData)
            for frame in 0..<4 {
                data[0][frame * input.stride] = 0.1
                data[1][frame * input.stride] = -0.05
            }
            var processor = MicrophonePCMProcessor()
            let output = try XCTUnwrap(processor.process(input, gainDB: 6, limiterEnabled: true))
            XCTAssertFalse(output === input)
            XCTAssertEqual(output.format, input.format)
            XCTAssertEqual(output.frameLength, 4)
            let processed = try XCTUnwrap(output.floatChannelData)
            for frame in 0..<4 {
                XCTAssertEqual(data[0][frame * input.stride], 0.1)
                XCTAssertEqual(data[1][frame * input.stride], -0.05)
                XCTAssertEqual(processed[0][frame * output.stride], 0.199526, accuracy: 0.00001)
                XCTAssertEqual(processed[1][frame * output.stride], -0.099763, accuracy: 0.00001)
            }
        }
    }

    func testIntegerExtremesDoNotOverflow() throws {
        for common in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatInt32] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: common, sampleRate: 48_000,
                                                   channels: 1, interleaved: false))
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
            input.frameLength = 2
            input.int16ChannelData?[0][0] = Int16.max
            input.int16ChannelData?[0][1] = Int16.min
            input.int32ChannelData?[0][0] = Int32.max
            input.int32ChannelData?[0][1] = Int32.min
            var processor = MicrophonePCMProcessor()
            let output = try XCTUnwrap(processor.process(input, gainDB: 24, limiterEnabled: false))
            if common == .pcmFormatInt16 {
                XCTAssertEqual(output.int16ChannelData?[0][0], Int16.max)
                XCTAssertEqual(output.int16ChannelData?[0][1], Int16.min)
            } else {
                XCTAssertEqual(output.int32ChannelData?[0][0], Int32.max)
                XCTAssertEqual(output.int32ChannelData?[0][1], Int32.min)
            }
        }
    }

    func testEmptyBufferDoesNotCreateAudio() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        var processor = MicrophonePCMProcessor()
        XCTAssertNil(processor.process(input, gainDB: 0, limiterEnabled: true))
        XCTAssertEqual(input.frameLength, 0)
    }
}
