import HaishinKit
import NabcamCore

/// HaishinKit exposes RTMP transport reports through this hook. Unlike an
/// adaptive strategy this observer NEVER reads or changes encoder settings.
/// One instance belongs to one publish attempt; do not reuse across sockets.
actor UploadTransportObserver: StreamBitRateStrategy {
    let mamimumVideoBitRate = 0
    let mamimumAudioBitRate = 0
    private var counter = UploadByteCounter()
    private(set) var hasSample = false
    var bytes: UInt64? { hasSample ? counter.bytes : nil }

    func record(totalBytesOut: Int) {
        guard totalBytesOut >= 0 else { return }
        counter.observe(total: UInt64(totalBytesOut))
        hasSample = true
    }

    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status(let report), .publishInsufficientBWOccured(let report):
            record(totalBytesOut: report.totalBytesOut)
        case .reset:
            // A stream reset notification is not an instruction to change bitrate.
            break
        }
    }
}
