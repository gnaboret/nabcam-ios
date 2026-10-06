import AVFoundation
import HaishinKit
import XCTest
@testable import NabcamStorageHost

final class MicrophoneProcessingOutputTests: XCTestCase {
    func testSynchronousHandoffPreservesExactAudioTimeAndInput() throws {
        let sink = ProcessingProbe()
        let wrapper = MicrophoneProcessingOutput(destination: sink, gainDB: 6,
            limiterEnabled: true, onFailure: { sink.failure() })
        let mixer = MediaMixer()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        input.frameLength = 4
        for index in 0..<4 { input.floatChannelData?[0][index] = 0.1 }
        let time = AVAudioTime(sampleTime: 123_456, atRate: 48_000)
        wrapper.mixer(mixer, didOutput: input, when: time)
        // No waiting: the wrapper must not introduce asynchronous delivery.
        let observed = sink.snapshot()
        XCTAssertEqual(observed.count, 1)
        XCTAssertTrue(observed.time === time)
        XCTAssertEqual(observed.buffer?.frameLength, input.frameLength)
        XCTAssertEqual(observed.buffer?.format, input.format)
        XCTAssertEqual(input.floatChannelData?[0][0], 0.1)
        XCTAssertEqual(try XCTUnwrap(observed.buffer?.floatChannelData?[0][0]), 0.199526, accuracy: 0.00001)
        XCTAssertEqual(observed.failures, 0)
    }

    func testEmptyIsIgnoredAndInvalidBlockReportsFailureOnce() throws {
        let sink = ProcessingProbe()
        let wrapper = MicrophoneProcessingOutput(destination: sink, gainDB: 0,
            limiterEnabled: true, onFailure: { sink.failure() })
        let mixer = MediaMixer()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_537))
        let time = AVAudioTime(sampleTime: 0, atRate: 48_000)
        wrapper.mixer(mixer, didOutput: input, when: time)
        XCTAssertEqual(sink.snapshot().failures, 0)
        input.frameLength = 65_537
        wrapper.mixer(mixer, didOutput: input, when: time)
        wrapper.mixer(mixer, didOutput: input, when: time)
        XCTAssertEqual(sink.snapshot().failures, 1)
        XCTAssertEqual(sink.snapshot().count, 0)
    }
}

private final class ProcessingProbe: MediaMixerOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    private var time: AVAudioTime?
    private var count = 0
    private var failures = 0
    var videoTrackId: UInt8? { get async { UInt8.max } }
    var audioTrackId: UInt8? { get async { UInt8.max } }
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}
    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {}
    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        self.buffer = buffer; time = when; count += 1
    }
    func failure() { lock.lock(); failures += 1; lock.unlock() }
    func snapshot() -> (buffer: AVAudioPCMBuffer?, time: AVAudioTime?, count: Int, failures: Int) {
        lock.lock(); defer { lock.unlock() }
        return (buffer, time, count, failures)
    }
}
