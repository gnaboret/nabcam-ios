import NabcamCore
import VideoToolbox
import XCTest
@testable import NabcamStorageHost

final class VideoEncoderConfigurationTests: XCTestCase {
    func testHEVCCapabilityRequiresAnExplicitHardwareEntry() {
        let format = kVTVideoEncoderList_CodecType as String
        let hardware = kVTVideoEncoderList_IsHardwareAccelerated as String
        XCTAssertFalse(VideoEncoderConfiguration.hasHardwareHEVC(in: []))
        XCTAssertFalse(VideoEncoderConfiguration.hasHardwareHEVC(in: [[format: kCMVideoCodecType_H264, hardware: true]]))
        XCTAssertFalse(VideoEncoderConfiguration.hasHardwareHEVC(in: [[format: kCMVideoCodecType_HEVC, hardware: false]]))
        XCTAssertFalse(VideoEncoderConfiguration.hasHardwareHEVC(in: [[format: kCMVideoCodecType_HEVC]]))
        XCTAssertTrue(VideoEncoderConfiguration.hasHardwareHEVC(in: [[format: kCMVideoCodecType_HEVC, hardware: true]]))
    }
    func testRequestedProfilesKeepFrameReorderingOffAndOutputModeUnchanged() {
        for codec in VideoCodecChoice.allCases {
            for preset in VideoPreset.allCases {
                let settings = VideoEncoderConfiguration.settings(codec: codec, preset: preset, bitrateKbps: 1600)
                let profile = codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel
                XCTAssertEqual(settings.profileLevel, profile as String)
                XCTAssertEqual(settings.videoSize.width, Double(preset.width))
                XCTAssertEqual(settings.videoSize.height, Double(preset.height))
                XCTAssertEqual(settings.expectedFrameRate, preset.fps)
                XCTAssertEqual(settings.bitRate, 1_600_000)
                XCTAssertEqual(settings.allowFrameReordering, false)
                XCTAssertEqual(settings.maxKeyFrameIntervalDuration, 2)
            }
        }
    }
}
