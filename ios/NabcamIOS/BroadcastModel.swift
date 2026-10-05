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
    @Published private(set) var canLockFocus = false
    @Published private(set) var isFocusLocked = false
    @Published private(set) var canLockExposure = false
    @Published private(set) var isExposureLocked = false
    @Published private(set) var clockEnabled = false
    @Published private(set) var clockCorner: ClockCorner = .topRight
    @Published private(set) var watermarks: [WatermarkConfiguration] = []
    @Published private(set) var overlayStorageMessage: String?
    @Published private(set) var captureFPS: Double?
    @Published private(set) var mixedFPS: Double?
    @Published private(set) var audioLevel: AudioLevel?
    @Published private(set) var experimentalSrtlaEnabled = false
    @Published private(set) var relayPathStatus: String?
    @Published private(set) var relayTrafficStatus: String?
    @Published var errorMessage: String?
    @Published private var diagnostics = StreamDiagnostics()
    var diagnosticReport: String { diagnostics.report() }
    let hardwareHEVC = VideoEncoderConfiguration.hardwareHEVC
    func clearDiagnostics() { diagnostics.clear() }
    let mixer = MediaMixer()
    private var session: (any Session)?
    // Keep the SRT runtime/stream alive across Start and Stop. The session resets
    // its socket and credentials between attempts, without global runtime churn.
    private lazy var srtPublishingSession = SrtPublishSession()
    private var srtlaRelay: SrtlaControlSession?
    private var relayStatusTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var generation = 0
    private let cameraSwitch = CameraSwitchCoordinator()
    private var active = true
    private var audioInterrupted = false
    private var streamClock: StreamClock?
    private var clockTask: Task<Void, Never>?
    private var streamWatermarks: StreamWatermarks?
    private let overlayStore = OverlayPreferencesStore()
    private var overlayPreferencesLoaded = false
    private let captureMonitor = MixerFrameMonitor(track: 0)
    private let mixedMonitor = MixerFrameMonitor(track: UInt8.max)
    private var frameStatsTask: Task<Void, Never>?
    private let audioMonitor = MixerAudioMonitor()
    private var audioMeterTask: Task<Void, Never>?

    private func prepare() async {
        guard active, !audioInterrupted, !isReady, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await loadOverlayPreferencesIfNeeded()
        guard active, !audioInterrupted else { return }
        diagnostics.append(.captureRequested(videoPreset))
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard active, !audioInterrupted else { return }
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
            mixing.mode = (clockEnabled || !watermarks.isEmpty) ? .offscreen : .passthrough
            await mixer.setVideoMixerSettings(mixing)
            if !watermarks.isEmpty {
                let images = try await StreamWatermarks(configurations: watermarks,
                    width: videoPreset.width, height: videoPreset.height)
                streamWatermarks = images
                try await images.install(on: mixer.screen, width: videoPreset.width, height: videoPreset.height)
            }
            if clockEnabled {
                let clock = await StreamClock()
                try await clock.install(on: mixer.screen, corner: clockCorner,
                                        width: videoPreset.width, height: videoPreset.height)
                streamClock = clock
            }
            try await mixer.setFrameRate(videoPreset.fps)
            guard active, !audioInterrupted else { await releaseCapture(); return }
            captureMonitor.reset()
            mixedMonitor.reset()
            audioMonitor.reset()
            await mixer.addOutput(captureMonitor)
            await mixer.addOutput(mixedMonitor)
            await mixer.addOutput(audioMonitor)
            await mixer.startRunning()
            isReady = true
            diagnostics.append(.captureReady)
            startClockUpdates()
            startFrameStatistics()
            startAudioMeter()
            await refreshCameraControls()
            status = "Preview · requested \(videoPreset.label)"
        } catch {
            await releaseCapture()
            status = "Camera unavailable"
            diagnostics.append(.captureFailed)
            errorMessage = "Could not start \(videoPreset.label). This camera may not support that mode. Try 720p / 30 FPS, check permissions and close other camera apps."
        }
    }

    func start(destination: String, bitrateKbps: Int, codec: VideoCodecChoice = .h264,
               audioBitrate: AudioBitrate = .kbps96) {
        guard active, !audioInterrupted, isReady, !isBusy, session == nil else { return }
        let validated: StreamDestination
        do {
            validated = try StreamDestination(destination)
            try codec.validate(destination: validated, hardwareHEVC: hardwareHEVC)
        }
        catch { errorMessage = error.localizedDescription; return }
        guard !validated.requiresSrtlaRelay || experimentalSrtlaEnabled else {
            errorMessage = "Enable Experimental SRTLA in Connection settings to test this destination. iPhone failover has not been verified yet."
            return
        }
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
        diagnostics.append(.encoderRequested(codec))
        diagnostics.append(.audioEncoderRequested(audioBitrate))
        connectionTask = Task {
            var candidate: (any Session)?
            var candidateRelay: SrtlaControlSession?
            do {
                try Task.checkCancellation()
                var publishingURL = validated.url
                if validated.requiresSrtlaRelay {
                    let relay = try SrtlaControlSession(endpoint: SrtlaEndpoint(validated.url.absoluteString),
                        pacingKbps: SrtlaPacketPacer.rate(videoKbps: bitrateKbps, audioKbps: audioBitrate.rawValue, headroomPercent: 125))
                    candidateRelay = relay
                    srtlaRelay = relay
                    relay.start()
                    startRelayStatus(relay, owner: owner)
                    publishingURL = try await relay.waitUntilReady()
                }
                try Task.checkCancellation()
                let next: any Session
                if validated.protocolName == "SRT" || validated.requiresSrtlaRelay {
                    try await srtPublishingSession.configure(publishingURL)
                    next = srtPublishingSession
                } else {
                    await SessionBuilderFactory.shared.register(RTMPSessionFactory())
                    guard let standard = try await SessionBuilderFactory.shared.make(validated.url).setMode(.publish).build() else {
                        throw DestinationError.unsupported
                    }
                    next = standard
                }
                candidate = next
                try Task.checkCancellation()
                guard owner == generation else { candidateRelay?.close(); try? await next.close(); return }
                session = next
                await next.setMaxRetryCount(0)
                let stream = await next.stream
                try await stream.setVideoSettings(VideoEncoderConfiguration.settings(codec: codec, preset: videoPreset, bitrateKbps: bitrateKbps))
                try await stream.setAudioSettings(AudioCodecSettings(bitRate: audioBitrate.bitsPerSecond, sampleRate: 48_000))
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
                    candidateRelay?.close()
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
                candidateRelay?.close()
                if let candidate {
                    await mixer.removeOutput(candidate.stream)
                    try? await candidate.close()
                }
                guard owner == generation else { return }
                srtlaRelay = nil
                relayStatusTask?.cancel(); relayStatusTask = nil
                relayPathStatus = nil
                relayTrafficStatus = nil
                session = nil
                isBusy = false
                isConnecting = false
                isLive = false
                status = "Connection failed"
                diagnostics.append(.connectionFailed)
                // Never expose a stream URL/key through a transport error description.
                if let optionError = error as? SrtConnectionOptions.ValidationError {
                    errorMessage = optionError.localizedDescription
                } else if error is SrtlaControlSession.ConnectionWaitError {
                    errorMessage = "The SRTLA receiver did not register an available link. Check its address, port and network access."
                } else {
                    errorMessage = "Could not publish. Check the destination, stream key, receiver availability and protocol. SRTLA requires an SRTLA receiver, not a plain SRT port."
                }
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
        relayStatusTask?.cancel(); relayStatusTask = nil
        srtlaRelay?.close(); srtlaRelay = nil
        relayPathStatus = nil
        relayTrafficStatus = nil
        if let previous {
            await mixer.removeOutput(previous.stream)
            try? await previous.close()
        }
        let cameraOutcome = await cameraSwitch.cancelAndWait()
        await task?.value
        if cameraOutcome == .unavailable { await releaseCapture() }
        UIApplication.shared.isIdleTimerDisabled = false
        status = "Stopped"
        diagnostics.append(.stopped)
        isBusy = false
    }

    func setExperimentalSrtla(_ enabled: Bool) {
        guard !isLive, !isBusy else { return }
        experimentalSrtlaEnabled = enabled
    }

    private func startRelayStatus(_ relay: SrtlaControlSession, owner: Int) {
        relayStatusTask?.cancel()
        relayStatusTask = Task { [weak self] in
            var sample = 0
            while !Task.isCancelled {
                guard let self, self.generation == owner else { return }
                let snapshot = relay.snapshot()
                let paths = [SrtlaControlSession.Interface.wifi, .cellular, .automatic].flatMap { interface in
                    snapshot.filter { $0.interface == interface }
                }
                let summary = paths.map { path in
                    let name: String
                    switch path.interface { case .wifi: name = "Wi-Fi"; case .cellular: name = "Cellular"; case .automatic: name = "Network" }
                    let state: String
                    switch path.state {
                    case .connecting: state = "connecting"
                    case .ready: state = "registering"
                    case .waiting: state = "unavailable"
                    case .failed: state = "retrying"
                    case .registered: state = "ready"
                    case .cooldown: state = "receiver cooldown"
                    }
                    return "\(name) \(state)"
                }.joined(separator: " · ")
                self.relayTrafficStatus = paths.map { path in
                    let name: String
                    switch path.interface { case .wifi: name = "Wi-Fi"; case .cellular: name = "Cell"; case .automatic: name = "Net" }
                    let rate = path.traffic.windows.last?.kbps ?? 0
                    let rtt: String
                    if let value = path.relayRTTMilliseconds, let age = path.relayRTTAgeMilliseconds, age <= 5000 {
                        rtt = String(format: "%.0f ms", value)
                    } else { rtt = "—" }
                    return String(format: "%@ ↑ %.0f kbps · relay RTT %@", name, rate, rtt)
                }.joined(separator: "\n")
                if self.relayPathStatus != summary || sample % 5 == 0 {
                    let stats = relay.relaySnapshot()
                    self.diagnostics.append(.srtla(registeredPaths: paths.filter { $0.state == .registered }.count,
                        queuedPackets: stats.queuedPackets, queuedBytes: stats.queuedBytes,
                        oldestMediaMs: stats.oldestMilliseconds, overflows: stats.overflowPackets,
                        socketReplacements: stats.socketReplacements))
                    for path in paths {
                        let link: RelayLinkKind
                        switch path.interface { case .wifi: link = .wifi; case .cellular: link = .cellular; case .automatic: link = .automatic }
                        self.diagnostics.append(.srtlaPath(link: link, socketID: path.id, traffic: path.traffic,
                            relayRTTMs: path.relayRTTMilliseconds, rttAgeMs: path.relayRTTAgeMilliseconds))
                    }
                }
                self.relayPathStatus = summary.isEmpty ? "SRTLA relay stopped" : summary
                sample += 1
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func switchCamera() async {
        guard active, !audioInterrupted, isReady, !isBusy else { return }
        let previousFront = isFront
        let nextFront = !previousFront
        let preset = videoPreset
        let mirrored = mirrorFrontCamera
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: previousFront ? .front : .back) != nil,
              let next = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: nextFront ? .front : .back) else {
            errorMessage = "The other camera is unavailable. Your current camera was kept."
            return
        }
        guard next.formats.contains(where: { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width >= preset.width && size.height >= preset.height && format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= preset.fps && preset.fps <= $0.maxFrameRate
            }
        }) else {
            errorMessage = "The other camera does not advertise \(preset.label). Your current camera was kept. Choose a lower mode before broadcasting."
            return
        }
        let owner = generation
        isBusy = true
        defer { if owner == generation { isBusy = false } }
        await turnOffTorch()
        guard owner == generation, active, !audioInterrupted else { return }
        diagnostics.append(.cameraSwitchStarted(front: nextFront, live: isLive))
        let result = await cameraSwitch.run(apply: { [self] in
            try await attachCamera(front: nextFront, mirrored: nextFront && mirrored, fps: preset.fps)
            isFront = nextFront
        }, restore: { [self] in
            try await attachCamera(front: previousFront, mirrored: previousFront && mirrored, fps: preset.fps)
            isFront = previousFront
        })
        guard owner == generation, active, !audioInterrupted else { return }
        switch result {
        case .changed:
            diagnostics.append(.cameraChanged(front: isFront))
        case .restored:
            diagnostics.append(.cameraSwitchRestored)
            errorMessage = "The other camera could not use \(preset.label). The previous camera was restored."
        case .unavailable:
            diagnostics.append(.cameraSwitchFailed)
            await stop()
            await releaseCapture()
            status = "Camera unavailable · stream stopped"
            errorMessage = "Neither camera could be restored. The stream was stopped. Restart the preview or choose a lower video mode."
        case .cancelled, .busy: break
        }
        await refreshCameraControls()
    }

    private func attachCamera(front: Bool, mirrored: Bool, fps: Double) async throws {
        // Replace video only. Keep the audio input, mixer, stream, codec settings
        // and transport alive; never reset their clocks to hide a camera gap.
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back) else {
            throw CaptureError.unavailable
        }
        try await mixer.attachVideo(device)
        // The pinned dependency suppresses errors in attachVideo's configuration
        // callback, so apply throwing settings explicitly after attachment.
        try await mixer.configuration(video: 0) { unit in
            guard let connection = unit.connection else { throw CaptureError.unavailable }
            try unit.setFrameRate(fps)
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                unit.isVideoMirrored = mirrored
            } else if mirrored { throw CaptureError.unavailable }
        }
        try await mixer.setFrameRate(fps)
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

    func setFocusLocked(_ locked: Bool) async {
        guard active, isReady, !isBusy, canLockFocus else { return }
        isBusy = true
        let owner = generation
        defer { if owner == generation { isBusy = false } }
        do {
            try await mixer.configuration(video: 0) { unit in
                guard let device = unit.device,
                      device.isFocusModeSupported(.locked), device.isFocusModeSupported(.continuousAutoFocus) else {
                    throw CaptureError.unavailable
                }
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.focusMode = locked ? .locked : .continuousAutoFocus
            }
            guard owner == generation, active else { return }
            diagnostics.append(.focusLocked(locked))
            await refreshCameraControls()
        } catch {
            guard owner == generation, active else { return }
            errorMessage = "Focus control is temporarily unavailable on this camera."
        }
    }

    func setExposureLocked(_ locked: Bool) async {
        guard active, isReady, !isBusy, canLockExposure else { return }
        isBusy = true
        let owner = generation
        defer { if owner == generation { isBusy = false } }
        do {
            try await mixer.configuration(video: 0) { unit in
                guard let device = unit.device,
                      device.isExposureModeSupported(.locked), device.isExposureModeSupported(.continuousAutoExposure) else {
                    throw CaptureError.unavailable
                }
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.exposureMode = locked ? .locked : .continuousAutoExposure
            }
            guard owner == generation, active else { return }
            diagnostics.append(.exposureLocked(locked))
            await refreshCameraControls()
        } catch {
            guard owner == generation, active else { return }
            errorMessage = "Exposure control is temporarily unavailable on this camera."
        }
    }

    private struct CameraState: Sendable {
        let hasTorch: Bool
        let torchOn: Bool
        let minimum: Double
        let maximum: Double
        let zoom: Double
        let canLockFocus: Bool
        let focusLocked: Bool
        let canLockExposure: Bool
        let exposureLocked: Bool
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
                            zoom: Double(device.videoZoomFactor),
                            canLockFocus: device.isFocusModeSupported(.locked) && device.isFocusModeSupported(.continuousAutoFocus),
                            focusLocked: device.focusMode == .locked,
                            canLockExposure: device.isExposureModeSupported(.locked) && device.isExposureModeSupported(.continuousAutoExposure),
                            exposureLocked: device.exposureMode == .locked))
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
        guard isReady, let state else {
            hasTorch = false; isTorchOn = false; zoom = 1; minimumZoom = 1; maximumZoom = 1
            canLockFocus = false; isFocusLocked = false; canLockExposure = false; isExposureLocked = false
            return
        }
        hasTorch = state.hasTorch
        isTorchOn = state.torchOn
        minimumZoom = state.minimum
        maximumZoom = max(minimumZoom, state.maximum)
        zoom = state.zoom
        canLockFocus = state.canLockFocus
        isFocusLocked = state.focusLocked
        canLockExposure = state.canLockExposure
        isExposureLocked = state.exposureLocked
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
        isMuted.toggle()
        // Single-track input format changes rebuild HaishinKit's track with
        // default track settings. Final-output mute survives those rebuilds.
        settings.isMuted = isMuted
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

    /// Stop the entire publish session when iOS takes the microphone away. Never
    /// resume publishing automatically: an interruption may have been a phone call.
    func handleAudioInterruption(began: Bool) {
        guard audioInterrupted != began else { return }
        audioInterrupted = began
        diagnostics.append(.audioInterruption(began: began))
        if began {
            Task {
                await setActive(false)
                if audioInterrupted {
                    status = "Microphone interrupted by iOS · stream stopped"
                }
            }
        } else {
            Task {
                guard UIApplication.shared.applicationState == .active else { return }
                await setActive(true)
                if isReady, !isLive, !audioInterrupted {
                    status = "Preview restored · tap Start to broadcast again"
                }
            }
        }
    }

    func restartPreview() async {
        guard !isLive, !isBusy, UIApplication.shared.applicationState == .active else { return }
        // iOS does not guarantee an "ended" notification. An explicit user retry
        // can attempt activation again; a still-unavailable audio session will fail.
        audioInterrupted = false
        await setActive(false)
        guard UIApplication.shared.applicationState == .active else { return }
        await setActive(true)
    }

    func configureClock(enabled: Bool, corner: ClockCorner) async {
        guard active, !isLive, !isBusy else { return }
        let owner = generation
        isBusy = true
        let saved = await saveOverlayPreferences(OverlayPreferences(watermarks: watermarks, clockEnabled: enabled, clockCorner: corner))
        guard owner == generation, active else { return }
        isBusy = false
        guard saved else { return }
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

    func importWatermark(from url: URL) async {
        guard active, !isLive, !isBusy, watermarks.count < 3 else { return }
        let owner = generation
        isBusy = true
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try WatermarkConfiguration.read(url)
            }.value
            guard owner == generation, active else { return }
            isBusy = false
            var watermark = WatermarkConfiguration(data: data)
            watermark.corner = [.bottomRight, .bottomLeft, .topLeft][watermarks.count]
            await replaceWatermarks(watermarks + [watermark])
        } catch {
            guard owner == generation else { return }
            isBusy = false
            errorMessage = "Choose a PNG or JPEG image no larger than 4 MB. The file could not be opened."
        }
    }

    func configureWatermark(id: UUID, corner: ClockCorner? = nil, percent: Int? = nil, remove: Bool = false) async {
        var proposed = watermarks
        guard let index = proposed.firstIndex(where: { $0.id == id }) else { return }
        if remove { proposed.remove(at: index) }
        else {
            if let corner { proposed[index].corner = corner }
            if let percent { proposed[index].percent = percent }
        }
        await replaceWatermarks(proposed)
    }

    private func replaceWatermarks(_ proposed: [WatermarkConfiguration]) async {
        guard active, !isLive, !isBusy else { return }
        let owner = generation
        isBusy = true
        do {
            // Validate/rasterize before disturbing the working preview.
            _ = try await StreamWatermarks(configurations: proposed,
                width: videoPreset.width, height: videoPreset.height)
            guard owner == generation, active else { return }
            let saved = await saveOverlayPreferences(OverlayPreferences(watermarks: proposed, clockEnabled: clockEnabled, clockCorner: clockCorner))
            guard owner == generation, active else { return }
            guard saved else { isBusy = false; return }
            watermarks = proposed
            diagnostics.append(.watermarks(count: proposed.count))
            isBusy = false
            await setActive(false)
            guard UIApplication.shared.applicationState != .background else { return }
            await setActive(true)
        } catch {
            guard owner == generation else { return }
            isBusy = false
            errorMessage = "This watermark could not be decoded. Use a PNG or JPEG up to 4 MB. Existing overlays were kept."
        }
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

    private func startAudioMeter() {
        audioMeterTask?.cancel()
        audioMeterTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard let self, self.isReady, !Task.isCancelled else { return }
                self.audioLevel = self.audioMonitor.snapshot()
            }
        }
    }

    private func startFrameStatistics() {
        frameStatsTask?.cancel()
        frameStatsTask = Task { [weak self] in
            var samples = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard let self, self.isReady, !Task.isCancelled else { return }
                let capture = self.captureMonitor.snapshot()
                let mixed = self.mixedMonitor.snapshot()
                self.captureFPS = capture?.fps
                self.mixedFPS = mixed?.fps
                samples += 1
                if samples == 1 || samples % 10 == 0, let capture, let mixed {
                    self.diagnostics.append(.frameRates(camera: capture.fps, mixed: mixed.fps,
                        cameraGapMs: capture.maximumGapMilliseconds, mixedGapMs: mixed.maximumGapMilliseconds))
                }
            }
        }
    }

    private func loadOverlayPreferencesIfNeeded() async {
        guard !overlayPreferencesLoaded else { return }
        overlayPreferencesLoaded = true
        do {
            let saved = try await overlayStore.load()
            _ = try await StreamWatermarks(configurations: saved.watermarks,
                width: videoPreset.width, height: videoPreset.height)
            watermarks = saved.watermarks
            clockEnabled = saved.clockEnabled
            clockCorner = saved.clockCorner
            overlayStorageMessage = nil
        } catch {
            await overlayStore.lockWrites()
            overlayStorageMessage = "Saved overlays could not be read. They have not been overwritten. Unlock the phone and retry."
        }
    }

    private func saveOverlayPreferences(_ preferences: OverlayPreferences) async -> Bool {
        do {
            try await overlayStore.save(preferences)
            overlayStorageMessage = nil
            return true
        } catch {
            overlayStorageMessage = "Could not save this overlay change. Existing settings were kept. Unlock the phone, check free space, and retry loading."
            return false
        }
    }

    func retrySavedOverlays() async {
        guard active, !isLive, !isBusy else { return }
        overlayPreferencesLoaded = false
        await restartPreview()
    }

    private func releaseCapture() async {
        audioMeterTask?.cancel()
        audioMeterTask = nil
        await mixer.removeOutput(audioMonitor)
        audioMonitor.reset()
        audioLevel = nil
        frameStatsTask?.cancel()
        frameStatsTask = nil
        await mixer.removeOutput(captureMonitor)
        await mixer.removeOutput(mixedMonitor)
        captureFPS = nil
        mixedFPS = nil
        clockTask?.cancel()
        clockTask = nil
        if let clock = streamClock { await clock.remove() }
        streamClock = nil
        if let images = streamWatermarks { await images.remove() }
        streamWatermarks = nil
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
