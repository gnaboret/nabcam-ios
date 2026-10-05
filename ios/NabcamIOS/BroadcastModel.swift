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
    @Published private(set) var mirrorFrontCamera = false
    @Published private(set) var videoPreset: VideoPreset = .hd30
    @Published private(set) var isConnecting = false
    @Published private(set) var zoom = 1.0
    @Published private(set) var maximumZoom = 1.0
    @Published private(set) var minimumZoom = 1.0
    @Published private(set) var hasTorch = false
    @Published private(set) var isTorchOn = false
    @Published private(set) var clockEnabled = false
    @Published private(set) var clockCorner: ClockCorner = .topRight
    @Published var errorMessage: String?
    private var diagnostics = StreamDiagnostics()
    var diagnosticReport: String { diagnostics.report() }
    func clearDiagnostics() { diagnostics.clear() }
    let mixer = MediaMixer()
    private var session: (any Session)?
    private var connectionTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var generation = 0
    private var active = true
    private var streamClock: StreamClock?
    private var clockTask: Task<Void, Never>?

    private func prepare() async {
        guard active, !isReady, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        diagnostics.append(.captureRequested(videoPreset))
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard active else { return }
        guard camera && microphone else {
            status = "Permissions needed"
            diagnostics.append(.permissionsDenied)
            errorMessage = "Allow Camera and Microphone in iOS Settings, then return to GNAB CAM IRL."
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
            try audio.setActive(true)
            await mixer.setMonitoringEnabled(false)
            await mixer.setSessionPreset(videoPreset.height == 720 ? .hd1280x720 : .hd1920x1080)
            await mixer.setVideoOrientation(.landscapeRight)
            guard let video = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: isFront ? .front : .back),
                  let microphone = AVCaptureDevice.default(for: .audio) else { throw CaptureError.unavailable }
            try await mixer.attachVideo(video)
            try await applyCameraMirroring()
            try await mixer.attachAudio(microphone)
            // Offscreen mode controls output cadence separately from camera capture.
            let captureFPS = videoPreset.fps
            try await mixer.configuration(video: 0) { try $0.setFrameRate(captureFPS) }
            var mixing = await mixer.videoMixerSettings
            mixing.mode = clockEnabled ? .offscreen : .passthrough
            await mixer.setVideoMixerSettings(mixing)
            if clockEnabled {
                let clock = await StreamClock()
                try await clock.install(on: mixer.screen, corner: clockCorner,
                                        width: videoPreset.width, height: videoPreset.height)
                streamClock = clock
            }
            try await mixer.setFrameRate(videoPreset.fps)
            guard active else { await releaseCapture(); return }
            await mixer.startRunning()
            isReady = true
            diagnostics.append(.captureReady)
            startClockUpdates()
            await refreshCameraControls()
            status = "Preview · requested \(videoPreset.label)"
        } catch {
            await releaseCapture()
            status = "Camera unavailable"
            diagnostics.append(.captureFailed)
            errorMessage = "Could not start \(videoPreset.label). This camera may not support that mode. Try 720p / 30 FPS, check permissions and close other camera apps."
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
        diagnostics.append(.connecting(bitrateKbps: bitrateKbps))
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
                    videoSize: .init(width: videoPreset.width, height: videoPreset.height), bitRate: bitrateKbps * 1000,
                    profileLevel: kVTProfileLevel_H264_Main_AutoLevel as String,
                    bitRateMode: .average, maxKeyFrameIntervalDuration: 2,
                    allowFrameReordering: false, expectedFrameRate: videoPreset.fps))
                try await stream.setAudioSettings(AudioCodecSettings(bitRate: 96_000, sampleRate: 48_000))
                await mixer.addOutput(stream)
                try Task.checkCancellation()
                try await next.connect { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == owner else { return }
                        await self.stop()
                        self.status = "Disconnected · tap Start to retry"
                        self.diagnostics.append(.disconnected)
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
                diagnostics.append(.connected)
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
                diagnostics.append(.connectionFailed)
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
        diagnostics.append(.stopped)
        isBusy = false
    }

    func switchCamera() async {
        guard isReady, !isBusy, !isLive else { return }
        isBusy = true
        defer { isBusy = false }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: isFront ? .back : .front) else { return }
        await turnOffTorch()
        do {
            try await mixer.attachVideo(device)
            isFront.toggle()
            diagnostics.append(.cameraChanged(front: isFront))
            try await applyCameraMirroring()
            let captureFPS = videoPreset.fps
            try await mixer.configuration(video: 0) { try $0.setFrameRate(captureFPS) }
            try await mixer.setFrameRate(videoPreset.fps)
            await refreshCameraControls()
        } catch {
            await releaseCapture()
            status = "Camera mode unavailable"
            errorMessage = "This camera could not use \(videoPreset.label). Choose a lower mode or restart the preview."
        }
    }

    func setFrontCameraMirrored(_ enabled: Bool) async {
        guard active, isReady, !isBusy, !isLive else { return }
        isBusy = true
        defer { isBusy = false }
        let previous = mirrorFrontCamera
        mirrorFrontCamera = enabled
        do {
            try await applyCameraMirroring()
            diagnostics.append(.mirrorFront(enabled))
        }
        catch {
            mirrorFrontCamera = previous
            errorMessage = "Mirroring is unavailable on this camera. Your previous setting was kept."
        }
    }

    private func applyCameraMirroring() async throws {
        let mirrored = isFront && mirrorFrontCamera
        try await mixer.configuration(video: 0) { unit in
            guard let connection = unit.connection else { throw CaptureError.unavailable }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                unit.isVideoMirrored = mirrored
            } else if mirrored {
                throw CaptureError.unavailable
            }
        }
    }

    func setZoom(_ value: Double) async {
        guard active, isReady, !isBusy, value.isFinite else { return }
        do {
            try await mixer.configuration(video: 0) { unit in
            guard let device = unit.device else { return }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let lower = max(1, device.minAvailableVideoZoomFactor)
            let upper = max(lower, min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor))
            device.videoZoomFactor = min(upper, max(lower, CGFloat(value)))
            }
            await refreshCameraControls()
        } catch { errorMessage = "Camera zoom is temporarily unavailable." }
    }

    func toggleTorch() async {
        guard active, isReady, !isBusy else { return }
        do {
            try await mixer.configuration(video: 0) { unit in
            guard let device = unit.device, device.hasTorch else { return }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.torchMode == .on, device.isTorchModeSupported(.off) {
                device.torchMode = .off
            } else {
                guard device.isTorchAvailable, device.isTorchModeSupported(.on) else {
                    throw CaptureError.unavailable
                }
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            }
            }
            await refreshCameraControls()
        } catch { errorMessage = "Could not change the flashlight. Try again when the camera is available." }
    }

    private struct CameraState: Sendable {
        let hasTorch: Bool
        let torchOn: Bool
        let minimum: Double
        let maximum: Double
        let zoom: Double
    }

    private func refreshCameraControls() async {
        let capture = mixer
        let state: CameraState? = try? await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    try await capture.configuration(video: 0) { unit in
                        guard let device = unit.device else { throw CaptureError.unavailable }
                        continuation.resume(returning: CameraState(
                            hasTorch: device.hasTorch && device.isTorchModeSupported(.on),
                            torchOn: device.torchMode == .on,
                            minimum: Double(max(1, device.minAvailableVideoZoomFactor)),
                            maximum: Double(min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor)),
                            zoom: Double(device.videoZoomFactor)))
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
        guard isReady, let state else {
            hasTorch = false; isTorchOn = false; zoom = 1; minimumZoom = 1; maximumZoom = 1
            return
        }
        hasTorch = state.hasTorch
        isTorchOn = state.torchOn
        minimumZoom = state.minimum
        maximumZoom = max(minimumZoom, state.maximum)
        zoom = state.zoom
    }

    private func turnOffTorch() async {
        do {
            try await mixer.configuration(video: 0) { unit in
            guard let device = unit.device, device.hasTorch, device.isTorchModeSupported(.off) else { return }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = .off
            }
            isTorchOn = false
        } catch { /* Capture shutdown still proceeds if the device is unavailable. */ }
    }

    func toggleMute() async {
        guard isReady, !isBusy else { return }
        var settings = await mixer.audioMixerSettings
        var track = settings.tracks[0] ?? .init()
        isMuted.toggle()
        track.isMuted = isMuted
        settings.tracks[0] = track
        await mixer.setAudioMixerSettings(settings)
        diagnostics.append(.microphoneMuted(isMuted))
    }

    func setActive(_ value: Bool) async {
        diagnostics.append(.captureActive(value))
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

    func configureClock(enabled: Bool, corner: ClockCorner) async {
        guard active, !isLive, !isBusy else { return }
        clockEnabled = enabled
        diagnostics.append(.clockEnabled(enabled))
        clockCorner = corner
        await setActive(false)
        // Do not restart capture if iOS sent the app to the background during teardown.
        guard UIApplication.shared.applicationState != .background else { return }
        await setActive(true)
    }

    func configureVideo(_ preset: VideoPreset) async {
        guard active, !isLive, !isBusy else { return }
        guard preset != videoPreset || !isReady else { return }
        videoPreset = preset
        diagnostics.append(.videoPreset(preset))
        await setActive(false)
        guard UIApplication.shared.applicationState != .background else { return }
        await setActive(true)
    }

    private func startClockUpdates() {
        clockTask?.cancel()
        guard let clock = streamClock else { clockTask = nil; return }
        clockTask = Task {
            while !Task.isCancelled {
                await clock.update()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { break }
            }
        }
    }

    private func releaseCapture() async {
        clockTask?.cancel()
        clockTask = nil
        if let clock = streamClock { await clock.remove() }
        streamClock = nil
        await turnOffTorch()
        await mixer.stopRunning()
        try? await mixer.attachVideo(nil)
        try? await mixer.attachAudio(nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isReady = false
        await refreshCameraControls()
    }

    private enum CaptureError: Error { case unavailable }
}
