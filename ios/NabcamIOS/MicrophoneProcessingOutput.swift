import AVFoundation
import HaishinKit

/// Synchronous wrapper around the existing encoder handoff: no added task,
/// queue, resampling or timestamp construction. Video passes through unchanged.
final class MicrophoneProcessingOutput: MediaMixerOutput, @unchecked Sendable {
    private let destination: any MediaMixerOutput
    private let gainDB: Double
    private let limiterEnabled: Bool
    private let ceilingDB: Double
    private let onFailure: @Sendable () -> Void
    private let lock = NSLock()
    private var processor = MicrophonePCMProcessor()
    private var failed = false

    init(destination: any MediaMixerOutput, gainDB: Double,
         limiterEnabled: Bool, ceilingDB: Double = -1,
         onFailure: @escaping @Sendable () -> Void) {
        self.destination = destination
        self.gainDB = gainDB
        self.limiterEnabled = limiterEnabled
        self.ceilingDB = ceilingDB
        self.onFailure = onFailure
    }

    var videoTrackId: UInt8? { get async { await destination.videoTrackId } }
    var audioTrackId: UInt8? { get async { await destination.audioTrackId } }
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {
        await destination.selectTrack(id, mediaType: mediaType)
    }
    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        destination.mixer(mixer, didOutput: sampleBuffer)
    }
    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard buffer.frameLength > 0 else { return }
        // Serializes processing state only; callbacks run outside the lock.
        lock.lock()
        guard !failed else { lock.unlock(); return }
        let output = processor.process(buffer, gainDB: gainDB,
                                       limiterEnabled: limiterEnabled, ceilingDB: ceilingDB)
        if output == nil { failed = true }
        lock.unlock()
        guard let output else { onFailure(); return }
        destination.mixer(mixer, didOutput: output, when: when)
    }
}
