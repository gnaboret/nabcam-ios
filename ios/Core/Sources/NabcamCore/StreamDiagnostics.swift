import Foundation

public enum RelayLinkKind: String, Sendable { case wifi = "Wi-Fi", cellular = "Cellular", automatic = "Network" }
public enum CameraLensKind: String, Sendable { case wide, ultraWide, telephoto, trueDepth }

/// Deliberately accepts no arbitrary strings, URLs, errors, or chat payloads.
public enum StreamDiagnosticEvent: Sendable {
    case captureRequested(VideoPreset), captureReady, captureFailed, permissionsDenied
    case connecting(bitrateKbps: Int), connected, connectionFailed, disconnected, stopped
    case encoderRequested(VideoCodecChoice)
    case audioEncoderRequested(AudioBitrate)
    case captureActive(Bool), cameraChanged(front: Bool), microphoneMuted(Bool)
    case cameraSwitchStarted(front: Bool, live: Bool), cameraSwitchRestored, cameraSwitchFailed
    case cameraAvailable(front: Bool, lens: CameraLensKind, advertised: [VideoPreset])
    case cameraLensAttached(front: Bool, lens: CameraLensKind)
    case cameraModeRejected(front: Bool, lens: CameraLensKind, requested: VideoPreset)
    case mirrorFront(Bool), clockEnabled(Bool), videoPreset(VideoPreset)
    case focusLocked(Bool), exposureLocked(Bool)
    case audioInterruption(began: Bool)
    case watermarks(count: Int)
    case frameRates(camera: Double, mixed: Double, cameraGapMs: Double, mixedGapMs: Double)
    case srtla(registeredPaths: Int, queuedPackets: Int, queuedBytes: Int, oldestMediaMs: Int64, overflows: UInt64, socketReplacements: UInt64)
    case srtlaPath(link: RelayLinkKind, socketID: UInt64, traffic: DatagramRateMeter.Snapshot, relayRTTMs: Double?, rttAgeMs: Int64?)

    fileprivate var description: String {
        switch self {
        case .captureRequested(let mode): "Capture requested: \(mode.label)"
        case .captureReady: "Capture started (waiting for measured frame rates)"
        case .captureFailed: "Capture configuration failed"
        case .permissionsDenied: "Camera or microphone permission denied"
        case .connecting(let rate): "Publish requested: encoder target \(rate) kbps"
        case .encoderRequested(let codec): "Encoder requested: \(codec.label) Main, 8-bit input, AAC; actual encoder output not verified"
        case .audioEncoderRequested(let rate): "Audio encoder requested: AAC \(rate.label), 48000 Hz; not a microphone gain or measured output rate"
        case .connected: "Transport connected (receiver playback not verified)"
        case .connectionFailed: "Transport connection failed"
        case .disconnected: "Transport disconnected"
        case .stopped: "Publish stopped"
        case .captureActive(let active): "Capture lifecycle requested: \(active ? "active" : "inactive")"
        case .cameraChanged(let front): "Camera attached: \(front ? "front" : "rear")"
        case .cameraAvailable(let front, let lens, let modes):
            "Camera discovered: \(front ? "front" : "rear") \(lens.rawValue); advertised modes: \(modes.map(\.label).joined(separator: ", ")); not measured delivery"
        case .cameraLensAttached(let front, let lens):
            "Camera lens attached: \(front ? "front" : "rear") \(lens.rawValue); waiting for measured FPS"
        case .cameraModeRejected(let front, let lens, let mode):
            "Camera change rejected before attachment: \(front ? "front" : "rear") \(lens.rawValue) does not advertise \(mode.label); current camera kept"
        case .cameraSwitchStarted(let front, let live): "Camera change requested: \(front ? "front" : "rear"); live \(live)"
        case .cameraSwitchRestored: "Camera change failed; previous camera restored without restarting transport"
        case .cameraSwitchFailed: "Camera change and rollback failed; stopping capture and publish"
        case .microphoneMuted(let muted): "Microphone muted: \(muted)"
        case .mirrorFront(let mirrored): "Front camera mirroring: \(mirrored)"
        case .focusLocked(let locked): "Camera focus lock applied: \(locked)"
        case .exposureLocked(let locked): "Camera exposure lock applied: \(locked)"
        case .clockEnabled(let enabled): "Encoded clock: \(enabled)"
        case .videoPreset(let mode): "Selected video mode: \(mode.label)"
        case .audioInterruption(let began): "iOS microphone interruption: \(began ? "began" : "ended")"
        case .watermarks(let count): "Encoded image overlays configured: \(count)"
        case .frameRates(let camera, let mixed, let cameraGap, let mixedGap):
            String(format: "Camera %.1f FPS / mixed output %.1f FPS; maximum callback gaps %.1f / %.1f ms (latest sample window)", camera, mixed, cameraGap, mixedGap)
        case .srtla(let paths, let packets, let bytes, let age, let overflows, let replacements):
            "Experimental SRTLA: \(paths) registered paths; queue \(packets) packets / \(bytes) bytes; oldest media \(age) ms; overflow \(overflows); socket replacements \(replacements)"
        case .srtlaPath(let link, let id, let traffic, let rtt, let age):
            Self.pathDescription(link: link, id: id, traffic: traffic, rtt: rtt, age: age)
        }
    }

    private static func pathDescription(link: RelayLinkKind, id: UInt64, traffic: DatagramRateMeter.Snapshot,
                                        rtt: Double?, age: Int64?) -> String {
        let timing: String
        if let rtt, rtt.isFinite, let age {
            timing = String(format: "relay ACK RTT smoothed/clamped %.1f ms (sample age %lld ms)", rtt, age)
        } else { timing = "relay ACK RTT unavailable" }
        let windows = traffic.windows.map {
            String(format: "%lldms: %.1f kbps / %llu bytes / %llu packets / retry %llu bytes / %llu packets",
                   $0.milliseconds, $0.kbps, $0.bytes, $0.packets, $0.retransmittedBytes, $0.retransmittedPackets)
        }.joined(separator: "; ")
        return "SRTLA \(link.rawValue) socket \(id): local UDP submissions total \(traffic.totalBytes) bytes / \(traffic.totalPackets) packets; retry total \(traffic.totalRetransmittedBytes) bytes / \(traffic.totalRetransmittedPackets) packets; \(timing); \(windows)"
    }
}

public struct StreamDiagnostics: Sendable {
    private struct Entry: Sendable {
        let sequence: Int
        let date: Date
        let event: StreamDiagnosticEvent
    }
    private var entries: [Entry] = []
    private var sequence = 0
    public init() {}
    public var count: Int { entries.count }

    public mutating func append(_ event: StreamDiagnosticEvent, at date: Date = Date()) {
        sequence += 1
        entries.append(Entry(sequence: sequence, date: date, event: event))
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
    }

    public mutating func clear() { entries.removeAll(); sequence = 0 }

    public func report() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let header = """
        GNAB CAM IRL — iOS diagnostic timeline
        Most recent \(entries.count) events; kept in memory, shared only when requested.
        UTC wall-clock timestamps; sequence numbers preserve order if system time changes.
        No stream URLs, keys, channel names, chat text, or raw transport errors are recorded.
        FPS counts camera/compositor callbacks over monotonic elapsed time, not encoded or received frames.
        SRTLA rates count successful local UDP send completions, including protocol/retry bytes but excluding IP/UDP headers; not receiver throughput.
        SRTLA 50/100/250/1000ms windows use monotonic milliseconds, sampled periodically; bursts between samples may be missed. Totals are per socket and reset on replacement.
        SRTLA ACK RTT is a smoothed/clamped relay-hop estimate with sample age, not end-to-end SRT RTT. Retry counts use the SRT retransmission flag, not a packet-loss estimate.
        Non-SRTLA network rates, packet loss and receiver A/V sync are not measured.
        """
        return ([header] + entries.map {
            "#\($0.sequence) \(formatter.string(from: $0.date)) — \($0.event.description)"
        }).joined(separator: "\n")
    }
}
