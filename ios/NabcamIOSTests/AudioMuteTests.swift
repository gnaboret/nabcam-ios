import AVFoundation
import HaishinKit
import NabcamCore
import XCTest
@testable import NabcamStorageHost

@MainActor
final class AudioMuteTests: XCTestCase {
    func testOutputMuteSurvivesInputFormatChange() async throws {
        let mixer = MediaMixer(captureSessionMode: .manual)
        let monitor = MixerAudioMonitor()
        await mixer.setMonitoringEnabled(false)
        await mixer.addOutput(monitor)
        await mixer.startRunning()
        do {
            // First prove the real mixer emits our non-silent PCM.
            try await feed(mixer, rate: 48000)
            let initial = await waitForLevel(monitor)
            XCTAssertGreaterThan(try XCTUnwrap(initial).peakDBFS, -10)
            var settings = await mixer.audioMixerSettings
            settings.isMuted = true
            await mixer.setAudioMixerSettings(settings)
            // Let any already-enqueued unmuted data finish, then discard its meter window.
            try await Task.sleep(for: .milliseconds(250))
            monitor.reset()
            try await feed(mixer, rate: 44100)
            let muted = await waitForLevel(monitor)
            XCTAssertEqual(try XCTUnwrap(muted).peakDBFS, -90)
            settings.isMuted = false
            await mixer.setAudioMixerSettings(settings)
            try await Task.sleep(for: .milliseconds(250))
            monitor.reset()
            try await feed(mixer, rate: 48000)
            let resumed = await waitForLevel(monitor)
            XCTAssertGreaterThan(try XCTUnwrap(resumed).peakDBFS, -10)
        } catch {
            await mixer.removeOutput(monitor)
            await mixer.stopRunning()
            throw error
        }
        await mixer.removeOutput(monitor)
        await mixer.stopRunning()
    }

    private func feed(_ mixer: MediaMixer, rate: Double) async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        for chunk in 0..<8 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            buffer.frameLength = 1024
            try XCTUnwrap(buffer.floatChannelData)[0].update(repeating: 0.5, count: 1024)
            await mixer.append(buffer, when: AVAudioTime(sampleTime: AVAudioFramePosition(chunk * 1024), atRate: rate))
        }
    }

    private func waitForLevel(_ monitor: MixerAudioMonitor) async -> NabcamCore.AudioLevel? {
        for _ in 0..<40 {
            if let level = monitor.snapshot() { return level }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}
