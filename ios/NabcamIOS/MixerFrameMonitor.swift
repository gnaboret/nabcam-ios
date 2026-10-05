import AVFoundation
import HaishinKit
import NabcamCore

/// MediaMixer may call on different executors. Mutable state is always under the
/// lock; no sample buffers are retained and no per-frame UI tasks are created.
final class MixerFrameMonitor: MediaMixerOutput, @unchecked Sendable {
    private let track: UInt8
    private let clockOrigin = ContinuousClock.now
    private let lock = NSLock()
    private var counter = FrameRateCounter()
    private var frameSize: VideoFrameSize?

    init(track: UInt8) { self.track = track }
    var videoTrackId: UInt8? { get async { track } }
    var audioTrackId: UInt8? { get async { nil } }
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async { /* Fixed diagnostic track. */ }
    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        record(sampleBuffer)
    }
    func record(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard let size = VideoFrameSize(width: Int(dimensions.width), height: Int(dimensions.height)) else { return }
        lock.lock(); defer { lock.unlock() }
        frameSize = size
        counter.record(at: seconds())
    }
    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) { }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        counter.reset(at: seconds())
        frameSize = nil
    }
    func snapshot() -> FrameRateSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return counter.snapshot(at: seconds())
    }
    func dimensions() -> VideoFrameSize? {
        lock.lock(); defer { lock.unlock() }
        return frameSize
    }
    private func seconds() -> Double {
        let elapsed = clockOrigin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}
