import AVFoundation
import HaishinKit
import NabcamCore
import XCTest
@testable import NabcamStorageHost

final class PreviewVideoBridgeTests: XCTestCase {
    func testForwardsVideoAndStopsBeforeReturningFromTeardown() async throws {
        let destination = MediaMixer()
        let monitor = MixerFrameMonitor(track: 0)
        await destination.addOutput(monitor)
        await destination.startRunning()
        let bridge = PreviewVideoBridge(destination: destination)
        let audioTrack = await bridge.audioTrackId
        let videoTrack = await bridge.videoTrackId
        XCTAssertNil(audioTrack)
        XCTAssertEqual(videoTrack, 0)
        let frame = try sample()
        bridge.mixer(destination, didOutput: frame)
        for _ in 0..<50 {
            if monitor.dimensions() != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(monitor.dimensions(), VideoFrameSize(width: 64, height: 36))
        XCTAssertEqual(monitor.snapshot()?.frames, 1)
        await bridge.stop()
        // Keep the consumer live: any incorrectly forwarded post-stop frames
        // would still reach this observer and increment its count.
        for _ in 0..<100 { bridge.mixer(destination, didOutput: frame) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(monitor.snapshot()?.frames, 1)
        await bridge.stop()
        await destination.removeOutput(monitor)
        await destination.stopRunning()
    }

    private func sample() throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_32BGRA,
                                          nil, &buffer), kCVReturnSuccess)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: try XCTUnwrap(buffer), formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: 1, timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: try XCTUnwrap(buffer), formatDescription: try XCTUnwrap(format),
            sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
