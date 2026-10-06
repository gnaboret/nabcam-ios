import AVFoundation
import HaishinKit

/// Feeds a separate preview compositor from the existing camera track. It never
/// opens another camera or forwards audio, and retains at most one waiting frame.
final class PreviewVideoBridge: MediaMixerOutput, @unchecked Sendable {
    // CMSampleBuffer is treated as immutable after capture. The wrapper is only
    // handed to one serial consumer, and no buffer attachments are modified.
    private struct Frame: @unchecked Sendable { let sample: CMSampleBuffer }
    private let continuation: AsyncStream<Frame>.Continuation
    private let task: Task<Void, Never>

    init(destination: MediaMixer) {
        let stream = AsyncStream<Frame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = stream.continuation
        task = Task {
            for await frame in stream.stream {
                guard !Task.isCancelled else { return }
                await destination.append(frame.sample, track: 0)
            }
        }
    }

    var videoTrackId: UInt8? { get async { 0 } }
    var audioTrackId: UInt8? { get async { nil } }
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async { }
    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.formatDescription?.mediaType == .video else { return }
        continuation.yield(Frame(sample: sampleBuffer))
    }
    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) { }

    func stop() async {
        continuation.finish()
        task.cancel()
        await task.value
    }

    deinit {
        continuation.finish()
        task.cancel()
    }
}
