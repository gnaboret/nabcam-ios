import AVFoundation
import NabcamCore

/// Owned by the serial audio delivery stage, never by the UI or meter observer.
/// Copies input PCM: the mixer and its other observers retain their original data.
struct MicrophonePCMProcessor {
    private var limiter = MicrophoneGainLimiter()

    mutating func reset() { limiter.reset() }

    mutating func process(_ input: AVAudioPCMBuffer, gainDB: Double,
                          limiterEnabled: Bool, ceilingDB: Double = -1) -> AVAudioPCMBuffer? {
        let frames = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        guard frames > 0, channels > 0, channels <= 8,
              frames <= 65_536 / channels,
              let output = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return nil }
        var samples = [Float](repeating: 0, count: frames * channels)
        let stride = input.stride
        if let data = input.floatChannelData {
            for frame in 0..<frames { for channel in 0..<channels {
                samples[frame * channels + channel] = data[channel][frame * stride]
            } }
        } else if let data = input.int16ChannelData {
            for frame in 0..<frames { for channel in 0..<channels {
                samples[frame * channels + channel] = Float(data[channel][frame * stride]) / 32768
            } }
        } else if let data = input.int32ChannelData {
            for frame in 0..<frames { for channel in 0..<channels {
                samples[frame * channels + channel] = Float(Double(data[channel][frame * stride]) / 2147483648)
            } }
        } else { return nil }
        _ = limiter.process(&samples, gainDB: gainDB, limiterEnabled: limiterEnabled, ceilingDB: ceilingDB)
        output.frameLength = input.frameLength
        let outputStride = output.stride
        for frame in 0..<frames { for channel in 0..<channels {
            let sample = samples[frame * channels + channel]
            let offset = frame * outputStride
            if let data = output.floatChannelData { data[channel][offset] = sample }
            else if let data = output.int16ChannelData {
                data[channel][offset] = Int16(min(32767, max(-32768, (Double(sample) * 32768).rounded())))
            } else if let data = output.int32ChannelData {
                data[channel][offset] = Int32(min(2147483647, max(-2147483648, (Double(sample) * 2147483648).rounded())))
            }
        } }
        return output
    }
}
