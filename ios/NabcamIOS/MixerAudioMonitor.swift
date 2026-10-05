import AVFoundation
import HaishinKit
import NabcamCore

/// Read-only observer of mixed PCM before AAC encoding. Mutable state is locked;
/// callbacks never retain buffers, dispatch UI work, or alter outgoing samples.
final class MixerAudioMonitor: MediaMixerOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var levels = AudioLevelAccumulator()
    var videoTrackId: UInt8? { get async { nil } }
    var audioTrackId: UInt8? { get async { UInt8.max } }
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async { }
    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) { }
    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) { record(buffer) }

    func record(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.stride
        // AVAudioPCMBuffer channel pointers plus stride support both planar and
        // interleaved layouts. FrameLength excludes unused capacity.
        if let samples = buffer.floatChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames { levels.add(Double(samples[channel][frame * stride])) }
            }
        } else if let samples = buffer.int16ChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames { levels.add(Double(samples[channel][frame * stride]) / 32768) }
            }
        } else if let samples = buffer.int32ChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames { levels.add(Double(samples[channel][frame * stride]) / 2147483648) }
            }
        }
    }
    func snapshot() -> AudioLevel? {
        lock.lock(); defer { lock.unlock() }
        return levels.take()
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        levels = AudioLevelAccumulator()
    }
}
