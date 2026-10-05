import HaishinKit
import NabcamCore
import VideoToolbox
import Foundation

enum VideoEncoderConfiguration {
    static var hardwareHEVC: Bool {
        var encoders: CFArray?
        guard VTCopyVideoEncoderList(nil, &encoders) == noErr,
              let entries = encoders as? [[String: Any]] else { return false }
        return hasHardwareHEVC(in: entries)
    }

    static func hasHardwareHEVC(in entries: [[String: Any]]) -> Bool {
        entries.contains {
            ($0[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == kCMVideoCodecType_HEVC
                && ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue == true
        }
    }

    static func settings(codec: VideoCodecChoice, preset: VideoPreset, bitrateKbps: Int) -> VideoCodecSettings {
        VideoCodecSettings(videoSize: .init(width: preset.width, height: preset.height), bitRate: bitrateKbps * 1000,
            profileLevel: (codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel) as String,
            bitRateMode: .average, maxKeyFrameIntervalDuration: 2,
            allowFrameReordering: false, expectedFrameRate: preset.fps)
    }
}
