import AVFoundation
import Combine
import HaishinKit
import NabcamCore
import RTMPHaishinKit
import SRTHaishinKit
import UIKit
import VideoToolbox

/// iOS-only first slice. Does not change Android capture, timing, queues or bitrate control.
@MainActor
final class BroadcastModel: ObservableObject {
    @Published private(set) var status = "Camera stopped"
    @Published private(set) var isReady = false
    @Published private(set) var isLive = false
    @Published private(set) var isBusy = false
    @Published private(set) var isMuted = false
    @Published private(set) var isFront = false
    @Published private(set) var isConnecting = false
    @Published var errorMessage: String?
    let mixer = MediaMixer()
    private var session: (any Session)?
    private var connectionTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var generation = 0
    private var active = true

    private func prepare() async {
        guard active, !isReady, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard active else { return }
        guard camera && microphone else {
            status = "Permissions needed"
            errorMessage = "Allow Camera and Microphone in iOS Settings, then return to NABCAM IRL."
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
            try audio.setActive(true)
            await mixer.setMonitoringEnabled(false)
            await mixer.setSessionPreset(.hd1280x720)
            await mixer.setVideoOrientation(.landscapeRight)
            guard let video = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: isFront ? .front : .back),
                  let microphone = AVCaptureDevice.default(for: .audio) else { throw CaptureError.unavailable }
            try await mixer.attachVideo(video)
            try await mixer.attachAudio(microphone)
            try await mixer.setFrameRate(30)
            guard active else { await releaseCapture(); return }
            await mixer.startRunning()
            isReady = true
            status = "Preview · 720p · requested 30 FPS"
        } catch {
            await releaseCapture()
            status = "Camera unavailable"
            errorMessage = "Could not start camera/audio capture. Check permissions and close other camera apps."
        }
    }

    func start(destination: String, bitrateKbps: Int) {
        guard active, isReady, !isBusy, session == nil else { return }
        let validated: StreamDestination
        do { validated = try StreamDestination(destination) }
        catch { errorMessage = error.localizedDescription; return }
        guard (444...12000).contains(bitrateKbps) else {
            errorMessage = "Choose a bitrate from 444 to 12000 kbps."
            return
        }
        generation += 1
        let owner = generation
        isBusy = true
        isConnecting = true
        status = "Connecting · \(validated.protocolName)"
        connectionTask = Task {
            var candidate: (any Session)?
            do {
                await SessionBuilderFactory.shared.register(RTMPSessionFactory())
                await SessionBuilderFactory.shared.register(SRTSessionFactory())
                guard let next = try await SessionBuilderFactory.shared.make(validated.url).setMode(.publish).build() else {
                    throw DestinationError.unsupported
                }
                candidate = next
                try Task.checkCancellation()
                guard owner == generation else { try? await next.close(); return }
                session = next
                await next.setMaxRetryCount(0)
                let stream = await next.stream
                try await stream.setVideoSettings(VideoCodecSettings(
                    videoSize: .init(width: 1280, height: 720), bitRate: bitrateKbps * 1000,
                    profileLevel: kVTProfileLevel_H264_Main_AutoLevel as String,
                    bitRateMode: .average, maxKeyFrameIntervalDuration: 2,
                    allowFrameReordering: false, expectedFrameRate: 30))
                try await stream.setAudioSettings(AudioCodecSettings(bitRate: 96_000, sampleRate: 48_000))
                await mixer.addOutput(stream)
                try Task.checkCancellation()
                try await next.connect { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == owner else { return }
                        await self.stop()
                        self.status = "Disconnected · tap Start to retry"
                    }
                }
                guard owner == generation, !Task.isCancelled else {
                    await mixer.removeOutput(stream)
                    try? await next.close()
                    return
                }
                isBusy = false
                isConnecting = false
                isLive = true
                status = "LIVE · \(validated.protocolName) · target \(bitrateKbps) kbps"
                UIApplication.shared.isIdleTimerDisabled = true
            } catch {
                if let candidate {
                    await mixer.removeOutput(candidate.stream)
                    try? await candidate.close()
                }
                guard owner == generation else { return }
                session = nil
                isBusy = false
                isConnecting = false
                isLive = false
                status = "Connection failed"
                // Never expose a stream URL/key through a transport error description.
                errorMessage = "Could not publish. Check the destination, stream key, receiver availability and protocol. SRTLA is not supported in this first iOS build."
            }
        }
    }

    func stop() async {
        generation += 1
        connectionTask?.cancel()
        let task = connectionTask
        connectionTask = nil
        isBusy = true
        isConnecting = false
        isLive = false
        let previous = session
        session = nil
        if let previous {
            await mixer.removeOutput(previous.stream)
            try? await previous.close()
        }
        await task?.value
        UIApplication.shared.isIdleTimerDisabled = false
        status = "Stopped"
        isBusy = false
    }

    func switchCamera() async {
        guard isReady, !isBusy, !isLive else { return }
        isBusy = true
        defer { isBusy = false }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: isFront ? .back : .front) else { return }
        do {
            try await mixer.attachVideo(device)
            try await mixer.setFrameRate(30)
            isFront.toggle()
        } catch { errorMessage = "Unable to switch cameras. Stop and restart the preview to retry." }
    }

    func toggleMute() async {
        guard isReady, !isBusy else { return }
        var settings = await mixer.audioMixerSettings
        var track = settings.tracks[0] ?? .init()
        isMuted.toggle()
        track.isMuted = isMuted
        settings.tracks[0] = track
        await mixer.setAudioMixerSettings(settings)
    }

    func setActive(_ value: Bool) async {
        active = value
        // Serialize rapid background/foreground transitions, including permission dialogs.
        let previous = lifecycleTask
        let next = Task {
            await previous?.value
            if value {
                await prepare()
            } else {
                await stop()
                await releaseCapture()
                status = "Stopped while app is in background"
            }
        }
        lifecycleTask = next
        await next.value
    }

    private func releaseCapture() async {
        await mixer.stopRunning()
        try? await mixer.attachVideo(nil)
        try? await mixer.attachAudio(nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isReady = false
    }

    private enum CaptureError: Error { case unavailable }
}
