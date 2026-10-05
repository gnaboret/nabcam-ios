import copy
import unittest
from verify_av_fixture import validate


class AVFixtureValidationTests(unittest.TestCase):
    def setUp(self):
        self.report = {
            "streams": [{"codec_type": "video", "codec_name": "h264"},
                        {"codec_type": "audio", "codec_name": "aac", "sample_rate": "48000"}],
            "frames": [{"media_type": "video", "pts_time": str(i * 2048 / 48000),
                        "width": 1280, "height": 720, "key_frame": int(i in (0, 23))}
                       for i in range(44)] +
                      [{"media_type": "audio", "pts_time": str(i * 1024 / 48000)}
                       for i in range(88)]}

    def test_accepts_complete_synthetic_timeline(self):
        self.assertEqual(validate(self.report), {"video": 44, "audio": 88})

    def test_rejects_missing_audio_or_duplicate_stream(self):
        for streams in [self.report["streams"][:1], self.report["streams"] * 2]:
            bad = copy.deepcopy(self.report)
            bad["streams"] = streams
            with self.assertRaises(AssertionError):
                validate(bad)

    def test_rejects_reset_gap_or_nonfinite_timestamp(self):
        for timestamp in ["0", "10", "nan", "inf"]:
            bad = copy.deepcopy(self.report)
            bad["frames"][25]["pts_time"] = timestamp
            with self.assertRaises(AssertionError):
                validate(bad)

    def test_rejects_wrong_resolution_and_missing_recovery_keyframe(self):
        for field, value in [("width", 640), ("key_frame", 0)]:
            bad = copy.deepcopy(self.report)
            bad["frames"][23][field] = value
            with self.assertRaises(AssertionError):
                validate(bad)

    def test_rejects_video_that_stops_early(self):
        bad = copy.deepcopy(self.report)
        bad["frames"] = [f for f in bad["frames"] if f["media_type"] == "audio" or float(f["pts_time"]) < 1.1]
        with self.assertRaises(AssertionError):
            validate(bad)


if __name__ == "__main__":
    unittest.main()
