import Foundation

/// Deliberately accepts no arbitrary strings, URLs, errors, or chat payloads.
public enum StreamDiagnosticEvent: Sendable {
    case captureRequested(VideoPreset), captureReady, captureFailed, permissionsDenied
    case connecting(bitrateKbps: Int), connected, connectionFailed, disconnected, stopped
    case captureActive(Bool), cameraChanged(front: Bool), microphoneMuted(Bool)
    case mirrorFront(Bool), clockEnabled(Bool), videoPreset(VideoPreset)

    fileprivate var description: String {
        switch self {
        case .captureRequested(let mode): "Capture requested: \(mode.label)"
        case .captureReady: "Capture started (delivered FPS not measured)"
        case .captureFailed: "Capture configuration failed"
        case .permissionsDenied: "Camera or microphone permission denied"
        case .connecting(let rate): "Publish requested: encoder target \(rate) kbps"
        case .connected: "Transport connected (receiver playback not verified)"
        case .connectionFailed: "Transport connection failed"
        case .disconnected: "Transport disconnected"
        case .stopped: "Publish stopped"
        case .captureActive(let active): "Capture lifecycle requested: \(active ? "active" : "inactive")"
        case .cameraChanged(let front): "Camera attached: \(front ? "front" : "rear")"
        case .microphoneMuted(let muted): "Microphone muted: \(muted)"
        case .mirrorFront(let mirrored): "Front camera mirroring: \(mirrored)"
        case .clockEnabled(let enabled): "Encoded clock: \(enabled)"
        case .videoPreset(let mode): "Selected video mode: \(mode.label)"
        }
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
        This timeline does not measure actual FPS, RTT, packet loss, transmitted bitrate or receiver A/V sync.
        """
        return ([header] + entries.map {
            "#\($0.sequence) \(formatter.string(from: $0.date)) — \($0.event.description)"
        }).joined(separator: "\n")
    }
}
