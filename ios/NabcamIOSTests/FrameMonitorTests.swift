import AVFoundation
import NabcamCore
import XCTest
@testable import NabcamStorageHost

final class FrameMonitorTests: XCTestCase {
    func testReportsObservedDimensionsAndFormatChangesWithoutEditingFrames() throws {
        let monitor = MixerFrameMonitor(track: 0)
        XCTAssertNil(monitor.dimensions())
        let first = try sample(width: 640, height: 360)
        monitor.record(first)
        XCTAssertEqual(monitor.dimensions(), VideoFrameSize(width: 640, height: 360))
        let second = try sample(width: 360, height: 640)
        monitor.record(second)
        XCTAssertEqual(monitor.dimensions(), VideoFrameSize(width: 360, height: 640))
        XCTAssertEqual(try XCTUnwrap(monitor.snapshot()).frames, 2)
        let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(first))
        XCTAssertEqual(CVPixelBufferGetWidth(image), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(image), 360)
    }

    func testResetDoesNotKeepDimensionsFromPreviousCamera() throws {
        let monitor = MixerFrameMonitor(track: UInt8.max)
        monitor.record(try sample(width: 640, height: 360))
        monitor.reset()
        XCTAssertNil(monitor.dimensions())
        XCTAssertEqual(try XCTUnwrap(monitor.snapshot()).frames, 0)
        monitor.record(try sample(width: 1280, height: 720))
        XCTAssertEqual(monitor.dimensions(), VideoFrameSize(width: 1280, height: 720))
        XCTAssertEqual(try XCTUnwrap(monitor.snapshot()).frames, 1)
    }

    private func sample(width: Int, height: Int) throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                          nil, &image), kCVReturnSuccess)
        let pixels = try XCTUnwrap(image)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixels, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                       presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixels, formatDescription: try XCTUnwrap(format),
            sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
